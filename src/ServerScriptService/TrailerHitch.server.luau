-- PROTOTYPE: articulated vehicles. The server is the only thing that may
-- couple or uncouple a trailer.
--
-- Two jobs, kept in two clearly separated sections below:
--
--   SETUP    - the trailer equivalent of Raycast.server.luau's AddCar. A
--              trailer cannot go through that one: AddCar requires a
--              DriverSeat and would reject every trailer with a warning, which
--              is why trailers live in workspace.Trailers instead of
--              workspace.Vehicles.
--   COUPLING - validating an approach, snapping the trailer onto the pin,
--              building the gimbal, and moving network ownership and the
--              anchored flag around as the rig is driven, parked and left.
--
-- WHY THE SERVER DECIDES, when the client is the one simulating the physics:
-- the same reason DeliveryManager re-checks a contract the client has already
-- decided it qualifies for. The client owns the tractor's motion, so it can
-- place the truck anywhere it likes; if it also decided what that position
-- entitled it to, "hitch to a trailer" would mean "hitch to any trailer, from
-- anywhere". The client gets to ASK, and its identical copy of the geometry
-- test (TrailerHitch.CheckAlignment) means a legitimate ask is never refused.

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)
local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local wheelsFolder = ReplicatedStorage.Wheels

local trailersFolder = workspace:FindFirstChild(TrailerHitch.WorkspaceFolderName)
if not trailersFolder then
	trailersFolder = Instance.new("Folder")
	trailersFolder.Name = TrailerHitch.WorkspaceFolderName
	trailersFolder.Parent = workspace
end

-- The one channel the client may ask down. `action` is "hitch" or "unhitch";
-- the client never names a trailer instance, because letting it do so would
-- mean validating an arbitrary instance reference and there is nothing to gain
-- from it - the server can resolve "the trailer behind me" itself, from
-- positions it already trusts.
local hitchRequest = Instance.new("RemoteEvent")
hitchRequest.Name = "TrailerHitchRequest"
hitchRequest.Parent = ReplicatedStorage

--=============================================================================
-- SETUP
--=============================================================================

-- Collision grouping, deliberately a cut-down local copy of
-- VehicleCollisionSetup.server.luau's setUpCar rather than a call into it.
--
-- That script is a .server script with no exported function, and refactoring a
-- working file that every car depends on is not something a prototype should
-- be doing. The duplication is the honest cost of that choice and should be
-- collapsed - by lifting setUpCar into a shared module both call - as soon as
-- trailers stop being an experiment.
--
-- One real difference from a car, and it was got WRONG first and measured
-- back. The trailer's shape originally went in Groups.Vehicle, on the theory
-- that the trailer's nose fouling the cab at full articulation is what a real
-- jackknife is and ought to happen physically.
--
-- It does not survive contact with the geometry. A trailer's nose overlaps the
-- tractor towing it BY DESIGN - the pin is under the trailer's front and the
-- trailer's body reaches forward over it - so the two hulls interpenetrate
-- from the instant of coupling, not just at full lock. The solver did what it
-- is supposed to do with two interpenetrating solids and shoved them apart:
-- the measured result was the truck lifted 4.8 studs into the air, the trailer
-- pitched 17 degrees nose-up with both bogie struts driven through the ground,
-- and the pitch hinge forced 8 degrees past its own limit. A gap between the
-- two would not fix it, because the overlap is intrinsic rather than a
-- modelling slip.
--
-- So a trailer's shape gets its own group: collides with the WORLD, never with
-- any vehicle. The jackknife stop is the yaw hinge's angle limit alone, which
-- is what that limit was there to back up.
--
-- KNOWN LIMITATION, and it is a real one: this also means a towed trailer
-- cannot hit ANOTHER PLAYER'S truck, because Roblox collision groups exclude
-- by group and not by pair. Excluding only the tractor actually towing it
-- would need a group per active coupling, against a 32-group engine limit.
-- Losing trailer-vs-other-car is a much smaller loss than the rig detonating,
-- but it is a loss, and it is the thing to revisit first if trailers ever stop
-- being a prototype.
local function setUpTrailerCollision(trailerModel)
	local hulls = trailerModel:FindFirstChild("Collision")
	local body = trailerModel:FindFirstChild("Body")
	local chassis = trailerModel.PrimaryPart

	for _, part in trailerModel:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end
		local isHull = hulls ~= nil and part:IsDescendantOf(hulls)
		local isBody = body ~= nil and part:IsDescendantOf(body)

		if part == chassis then
			-- The chassis is real collision geometry too, and it runs the full
			-- length of the trailer - so it is part of the shape that must not
			-- resolve against the tractor, not an exception to it.
			part.CollisionGroup = VehicleCollision.Groups.Trailer
		elseif isHull then
			part.CollisionGroup = VehicleCollision.Groups.Trailer
			part.CanCollide = true
			part.Massless = true -- mass stays in the Chassis, same as a car's hulls
		elseif isBody then
			part.CollisionGroup = VehicleCollision.Groups.Cosmetic
			part.CanCollide = false
			part.CanQuery = false
		else
			part.CollisionGroup = VehicleCollision.Groups.Attached
		end

		local current = part.CurrentPhysicalProperties
		part.CustomPhysicalProperties =
			PhysicalProperties.new(current.Density, current.Friction, 0, current.FrictionWeight, 100)
	end
end

local function attachWheels(trailerModel, chassis, attachments, config)
	local wheelFolder = Instance.new("Folder")
	wheelFolder.Name = "Wheels"
	wheelFolder.Parent = trailerModel

	for _, wheelName in VehiclePhysics.WheelNames do
		local attachment = attachments[wheelName]
		local wheelModelName = VehiclePhysics.GetWheelModelName(config, wheelName)
		local wheelModel = wheelModelName and wheelsFolder:FindFirstChild(wheelModelName)
		if not wheelModel then
			warn("TrailerHitch: no wheel model '" .. tostring(wheelModelName) .. "' for " .. trailerModel:GetFullName())
			return
		end

		local cloned = wheelModel:Clone()
		cloned.Name = wheelName
		cloned.Parent = wheelFolder

		local parts = cloned:IsA("Model") and cloned:GetDescendants() or { cloned }
		for _, part in parts do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Anchored = false
				part.CollisionGroup = VehicleCollision.Groups.Attached
			end
		end

		local primary = VehiclePhysics.GetWheelPrimaryPart(cloned)
		local weld = Instance.new("Weld")
		weld.Part0 = chassis
		weld.Part1 = primary
		weld.C0 = CFrame.new(attachment.Position)
		-- Wheels on the right are the same mesh flipped, exactly as
		-- Raycast.server.luau does it - otherwise one side's tread runs
		-- backwards and the hub dishes the wrong way.
		if attachment.Position.X > 0 then
			weld.C0 = weld.C0 * CFrame.Angles(0, math.rad(180), 0)
		end
		weld.Parent = primary
	end
end

-- Put the trailer on the ground, level, WITHOUT simulating it - and this is
-- the one place a trailer must not copy what Raycast.server.luau does for a
-- car.
--
-- A car's settle works because a car is supported at four corners. This
-- trailer's four ray points are both axles of a REAR BOGIE (see
-- Configs/TestTrailer.luau): the front is carried by the kingpin, so an
-- UNCOUPLED trailer has nothing whatsoever holding its nose up. Running the
-- car settle on it does exactly what the geometry says it should - the nose
-- pitches down, hits the ground, and the rear springs pole-vault the whole
-- trailer onto its back. That is not an instability, it is a 28-stud lever
-- with a spring on one end and nothing on the other.
--
-- So an uncoupled trailer is never simulated at all. It is placed by raycast,
-- levelled, and Anchored - which is what a trailer standing on its landing
-- gear in a yard actually is, and is the same "parked means Anchored, with no
-- physics that can jitter or drift" rule every parked car here follows.
--
-- Its yaw is kept: how a trailer is angled in the yard is the builder's
-- decision and the thing the player has to read when judging an approach.
local function placeOnGround(trailerModel, chassis, attachments, config)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { trailerModel }
	rayParams.RespectCanCollide = true

	-- Highest ground under any bogie wheel, so a trailer parked with one axle
	-- over a kerb rests ON the kerb rather than sunk through it.
	local highest = nil
	for _, wheelName in VehiclePhysics.WheelNames do
		local attachment = attachments[wheelName]
		local hit = workspace:Raycast(attachment.WorldPosition, Vector3.new(0, -50, 0), rayParams)
		if hit and (highest == nil or hit.Position.Y > highest) then
			highest = hit.Position.Y
		end
	end
	if not highest then
		warn("TrailerHitch: no ground under " .. trailerModel:GetFullName() .. " - leaving it where it was placed")
		chassis.Anchored = true
		return
	end

	-- Sat at the same spring compression it will have once coupled, so
	-- hitching up does not make the trailer visibly jump to a new ride height.
	local wheelRadius = VehiclePhysics.GetWheelRadius(config, VehiclePhysics.WheelNames[1])
	local restSpring = math.max(config.SuspensionMaxLength - TrailerHitch.RestSag, 0)
	-- The wheel attachments all share one local Y, so any of them gives the
	-- chassis-to-strut offset.
	local strutLocalY = attachments[VehiclePhysics.WheelNames[1]].Position.Y
	local chassisY = highest + wheelRadius + restSpring - strutLocalY

	local position = chassis.Position
	local yaw = select(2, chassis.CFrame:ToOrientation())
	trailerModel:PivotTo(CFrame.new(position.X, chassisY, position.Z) * CFrame.Angles(0, yaw, 0))
	chassis.Anchored = true
end

-- The constant every config in this game derives sag with:
--     sag studs = SAG_CONSTANT * supported mass / Stiffness
-- See the derivation blocks in Configs/BoxTruck.luau and StraightTruck.luau.
local SAG_CONSTANT = 0.8175
-- BoxTruck's damping ratio, which every vehicle here keeps: Damper = Stiffness * this.
local DAMPING_RATIO = 7.5 / 120
-- Set to false on a trailer's Chassis to hand-tune Stiffness/Damper instead.
local AUTO_TUNE_ATTRIBUTE = "AutoTuneSuspension"

-- Pick the bogie's spring rate from what the trailer ACTUALLY weighs and where
-- its wheels ACTUALLY are, instead of from numbers hand-derived against one
-- frozen version of the model.
--
-- This exists because hand-derived numbers are a trap on a trailer
-- specifically. A trailer stands on two supports - the kingpin and the bogie -
-- and the kingpin's height is not its own to choose: it is pinned to the
-- truck. So the bogie's ride height alone decides the trailer's PITCH. Get the
-- spring rate wrong and the trailer does not just sit low or high like a car
-- would, it tilts:
--
--     bogie too soft -> rear sags  -> trailer noses UP
--     bogie too stiff -> rear rides high -> trailer noses DOWN
--
-- That second case is the "red trailer leans forward" symptom, and it is what
-- you get by making the chassis lighter (or moving the wheels) while leaving
-- Stiffness at a value derived for the old mass: the springs are now too stiff
-- for what they carry. Deriving the rate here means changing the trailer's
-- mass or shifting its axles in Studio is self-correcting, which is the whole
-- point - those are exactly the things a builder tries first.
local function tuneSuspension(trailerModel, chassis, attachments)
	if chassis:GetAttribute(AUTO_TUNE_ATTRIBUTE) == false then
		return -- hand-tuned on purpose; leave whatever is set alone
	end

	-- Summed by hand rather than read off AssemblyMass, because an anchored
	-- assembly reports inf - and a parked trailer is always anchored.
	local total, weighted = 0, Vector3.zero
	for _, part in trailerModel:GetDescendants() do
		if part:IsA("BasePart") and not part.Massless then
			local mass = part:GetMass()
			total += mass
			weighted += part.Position * mass
		end
	end
	if total <= 0 then
		warn("TrailerHitch: " .. trailerModel:GetFullName() .. " has no mass - cannot tune its suspension")
		return
	end

	-- Everything below is along the trailer's own Z, in chassis space.
	local comZ = chassis.CFrame:PointToObjectSpace(weighted / total).Z
	local kingpinZ = TrailerHitch.GetKingpinAttachment(trailerModel).Position.Z
	local bogieZ = 0
	for _, wheelName in VehiclePhysics.WheelNames do
		bogieZ += attachments[wheelName].Position.Z
	end
	bogieZ /= #VehiclePhysics.WheelNames

	-- Lever rule about the centre of mass. The bogie carries the share of the
	-- trailer proportional to how far the KINGPIN is from the CoM, and vice
	-- versa - the support further away carries less.
	local kingpinLever = comZ - kingpinZ
	local bogieLever = bogieZ - comZ
	local supportedFraction = 1
	if kingpinLever > 0 and bogieLever > 0 then
		supportedFraction = kingpinLever / (kingpinLever + bogieLever)
	else
		-- The CoM is not between the two supports, so there is no sane split -
		-- most likely the axles or the kingpin are on the wrong end. Assume the
		-- bogie carries everything, which is the conservative (stiffer) guess.
		warn(
			"TrailerHitch: "
				.. trailerModel:GetFullName()
				.. " has its centre of mass outside the kingpin/bogie span (kingpin z="
				.. string.format("%.2f, com z=%.2f, bogie z=%.2f", kingpinZ, comZ, bogieZ)
				.. ") - check the wheel attachments, tuning as if the bogie carries it all"
		)
	end

	local supported = total * supportedFraction
	local stiffness = SAG_CONSTANT * supported / TrailerHitch.RestSag

	-- The stability budget every config here respects:
	--     Stiffness + 120 * Damper <= 30 * mass / 4
	-- With Damper tied to Stiffness by DAMPING_RATIO that reduces to
	-- Stiffness * 8.5 <= 7.5 * mass. Past it the explicit integration in
	-- VehiclePhysics.Step gets fragile on a bad frame rate - and the trailer is
	-- the body with no driver to notice it misbehaving.
	local ceiling = (30 * total / 4) / (1 + 120 * DAMPING_RATIO)
	if stiffness > ceiling then
		warn(
			string.format(
				"TrailerHitch: %s wants Stiffness %.1f for %.2f studs of sag but the stability ceiling is %.1f - clamping. It will ride higher (and nose down) than intended; give it more SuspensionMaxLength or less mass.",
				trailerModel:GetFullName(), stiffness, TrailerHitch.RestSag, ceiling
			)
		)
		stiffness = ceiling
	end

	-- Attributes rather than the config file: GetConfig reads attributes last
	-- and so they win, and they are per-instance - two trailers of different
	-- weights can share Configs/TestTrailer.luau and still each get their own
	-- rate. Configs/TestTrailer.luau's own numbers stay as the fallback for
	-- anything that opts out via AUTO_TUNE_ATTRIBUTE.
	chassis:SetAttribute("Stiffness", stiffness)
	chassis:SetAttribute("Damper", stiffness * DAMPING_RATIO)

	print(string.format(
		"TrailerHitch: tuned %s - mass %.1f, CoM z %.2f, kingpin carries %.0f%% / bogie %.0f%%, Stiffness %.1f Damper %.2f",
		trailerModel.Name, total, comZ, (1 - supportedFraction) * 100, supportedFraction * 100,
		stiffness, stiffness * DAMPING_RATIO
	))
end

local function addTrailer(trailerModel)
	local chassis = trailerModel.PrimaryPart
	if not chassis then
		warn("TrailerHitch: " .. trailerModel:GetFullName() .. " has no PrimaryPart - skipping")
		return
	end
	if not TrailerHitch.GetKingpinAttachment(trailerModel) then
		warn(
			"TrailerHitch: "
				.. trailerModel:GetFullName()
				.. " has no '"
				.. TrailerHitch.TrailerAttachmentName
				.. "' Attachment on its Chassis - it can never be coupled to anything"
		)
		return
	end
	local attachments = VehiclePhysics.GetWheelAttachments(chassis)

	for _, folderName in { "Body", "Collision" } do
		local folder = trailerModel:FindFirstChild(folderName)
		if folder then
			VehiclePhysics.WeldFolderToChassis(folder, chassis)
		end
	end

	setUpTrailerCollision(trailerModel)

	local config = VehiclePhysics.GetConfig(chassis)
	attachWheels(trailerModel, chassis, attachments, config)

	-- AFTER the wheels are on, because they are a real share of the trailer's
	-- mass and they sit at the bogie - so leaving them out would both
	-- under-read the weight and put the centre of mass too far forward.
	tuneSuspension(trailerModel, chassis, attachments)
	-- Re-read so the placement below uses the rate that was just chosen.
	config = VehiclePhysics.GetConfig(chassis)

	-- Both links exist from the start, empty. A client reading an ObjectValue
	-- that might not be there yet has to handle two different "not hitched"
	-- answers; one that is always present and sometimes nil has one.
	local link = Instance.new("ObjectValue")
	link.Name = TrailerHitch.Links.TractorOnTrailer
	link.Parent = trailerModel

	trailerModel:SetAttribute(TrailerHitch.Attributes.Hitched, false)

	chassis.Anchored = true
	placeOnGround(trailerModel, chassis, attachments, config)
end

local function tryAddTrailer(trailerModel)
	-- One misconfigured trailer must not take down the setup of every other
	-- one, same guard and same reasoning as Raycast.server.luau's TryAddCar.
	local ok, err = pcall(addTrailer, trailerModel)
	if not ok then
		warn("TrailerHitch: failed to set up " .. trailerModel:GetFullName() .. ": " .. tostring(err))
	end
end

--=============================================================================
-- COUPLING
--=============================================================================

-- Tracks the seat connection per coupling so it can be disconnected on
-- uncoupling. Without this a trailer that had been coupled and dropped would
-- still be listening to its old tractor's seat and anchoring itself whenever
-- that unrelated truck was parked.
local couplings = {} -- [trailerModel] = { Tractor = Model, SeatConnection = RBXScriptConnection }

-- Density of the gimbal pin. A 1x1x1 part, so this IS its mass in studs.
-- See the block where the pin is created for the history behind the number.
local PIN_DENSITY = 2

local function buildGimbal(tractorModel, trailerModel)
	local tractorChassis = tractorModel.PrimaryPart
	local trailerChassis = trailerModel.PrimaryPart
	local hitch = TrailerHitch.GetHitchAttachment(tractorModel)
	local kingpinAttachment = TrailerHitch.GetKingpinAttachment(trailerModel)

	-- Everything created here goes under one folder so uncoupling is a single
	-- Destroy - see TrailerHitch.JointFolderName.
	local joint = Instance.new("Folder")
	joint.Name = TrailerHitch.JointFolderName

	-- The intermediate body. Its mass has been wrong in BOTH directions now,
	-- so the history matters:
	--
	-- It started at a default-density 1x1x1 (0.7 mass). The first coupled test
	-- measured the pin sitting a FULL STUD from the hitch it is supposed to be
	-- coincident with, which looked like the classic near-zero-mass body
	-- between two heavy ones, so it went to 50.
	--
	-- That diagnosis was probably WRONG. The tractor and trailer hulls were
	-- still interpenetrating at that point (see setUpTrailerCollision), and
	-- fixing THAT is what actually closed the gap - 0.565 -> 0.003 studs -
	-- with the pin mass unchanged. The pin was never really the problem; it
	-- just got changed in the same window.
	--
	-- And 50 is not free. It is 50 mass units parked exactly on the hitch,
	-- pressing straight down on the truck's rear springs - comparable to the
	-- trailer's own nose weight, on a rig where the rear bottoming out is the
	-- open problem. So it is now 2: enough not to be a singular speck, small
	-- enough not to be a second trailer nose.
	--
	-- WHY NOT Massless = true, which is the obvious thing to reach for: it
	-- would do nothing at all. Massless only takes effect on a part that is a
	-- NON-ROOT member of an assembly, and this pin is its own assembly - the
	-- HingeConstraints either side of it are constraints, not rigid joints, so
	-- they do not merge assemblies the way a WeldConstraint would. A standalone
	-- Massless part still has mass. Lowering the density, as here, is the only
	-- thing that actually reduces what the hitch carries.
	--
	-- If the joint ever visibly gaps again, raise this before suspecting the
	-- hinges - but check for hull interpenetration first, because that is what
	-- it was last time.
	local pin = Instance.new("Part")
	pin.Name = "KingpinPin"
	pin.Size = Vector3.one
	pin.CustomPhysicalProperties = PhysicalProperties.new(PIN_DENSITY, 0.3, 0, 1, 100)
	pin.Transparency = 1
	pin.CanCollide = false
	pin.CanQuery = false
	pin.CanTouch = false
	pin.CollisionGroup = VehicleCollision.Groups.Attached
	pin.CFrame = tractorChassis.CFrame.Rotation + hitch.WorldPosition
	pin.Parent = joint

	-- PITCH: tractor <-> pin, about the tractor's LATERAL axis.
	--
	-- A HingeConstraint's axis is its attachments' own X axis, so both of
	-- these are left with identity rotation: an attachment with no rotation
	-- relative to its part has its X along that part's RightVector, which is
	-- the lateral axis we want. The Studio-authored Hitch attachment is not
	-- reused directly for this, only its position - so that someone rotating
	-- it in Studio for any reason cannot silently turn the pitch hinge into a
	-- roll hinge.
	local pitchOnTractor = Instance.new("Attachment")
	pitchOnTractor.Name = "HitchPitch"
	pitchOnTractor.CFrame = CFrame.new(hitch.Position)
	pitchOnTractor.Parent = tractorChassis

	local pitchOnPin = Instance.new("Attachment")
	pitchOnPin.Name = "PinPitch"
	pitchOnPin.Parent = pin

	local pitchHinge = Instance.new("HingeConstraint")
	pitchHinge.Name = "PitchHinge"
	pitchHinge.Attachment0 = pitchOnTractor
	pitchHinge.Attachment1 = pitchOnPin
	pitchHinge.LimitsEnabled = true
	pitchHinge.UpperAngle = TrailerHitch.PitchLimitDegrees
	pitchHinge.LowerAngle = -TrailerHitch.PitchLimitDegrees
	pitchHinge.Parent = joint

	-- YAW: pin <-> trailer, about the VERTICAL axis. This is the articulation
	-- the driver actually feels.
	--
	-- Rotating an attachment 90 degrees about Z maps its X axis onto +Y, which
	-- is how a hinge whose axis is "up" is spelled.
	local upAxis = CFrame.Angles(0, 0, math.rad(90))

	local yawOnPin = Instance.new("Attachment")
	yawOnPin.Name = "PinYaw"
	yawOnPin.CFrame = upAxis
	yawOnPin.Parent = pin

	local yawOnTrailer = Instance.new("Attachment")
	yawOnTrailer.Name = "KingpinYaw"
	yawOnTrailer.CFrame = CFrame.new(kingpinAttachment.Position) * upAxis
	yawOnTrailer.Parent = trailerChassis

	local yawHinge = Instance.new("HingeConstraint")
	yawHinge.Name = "YawHinge"
	yawHinge.Attachment0 = yawOnPin
	yawHinge.Attachment1 = yawOnTrailer
	-- The jackknife stop. The trailer's own nose usually fouls the cab before
	-- this, which is realistic; this is what stops it folding THROUGH.
	yawHinge.LimitsEnabled = true
	yawHinge.UpperAngle = TrailerHitch.YawLimitDegrees
	yawHinge.LowerAngle = -TrailerHitch.YawLimitDegrees
	-- Fifth-wheel friction. A free hinge has no damping term whatsoever, so
	-- without this the trailer weaves behind the truck at speed with nothing
	-- to bleed the oscillation off. A Motor targeting zero relative velocity
	-- resists the RATE of articulation and not its ANGLE, which is the
	-- difference between a stiff pin and a pin that refuses to turn.
	if TrailerHitch.YawFrictionTorque > 0 then
		yawHinge.ActuatorType = Enum.ActuatorType.Motor
		yawHinge.AngularVelocity = 0
		yawHinge.MotorMaxTorque = TrailerHitch.YawFrictionTorque
	end
	yawHinge.Parent = joint

	joint.Parent = trailerChassis
	return joint
end

-- Anchored/ownership state follows the TRACTOR's: a coupled trailer is a part
-- of whatever the truck currently is. Driven means both unanchored and both
-- owned by the driver; parked means both anchored and owned by the server.
--
-- Getting this wrong in the obvious direction - leaving the trailer unanchored
-- while the truck is parked - leaves a heavy unowned body joined to an
-- anchored one, which the solver resolves by dragging on a truck that cannot
-- move. The truck wins and the trailer vibrates against it indefinitely.
local function followTractorState(trailerModel, tractorModel, player)
	local trailerChassis = trailerModel.PrimaryPart
	local tractorChassis = tractorModel.PrimaryPart
	if not (trailerChassis and tractorChassis) then
		return
	end

	if tractorChassis.Anchored then
		trailerChassis.Anchored = true
		return
	end

	trailerChassis.Anchored = false
	-- pcall because SetNetworkOwner throws on an assembly that is not
	-- simulated, and losing the race against an Anchored = true that has
	-- already landed is a normal outcome here, not an error worth spamming.
	pcall(function()
		trailerChassis:SetNetworkOwner(player)
	end)
end

local function uncouple(trailerModel)
	local coupling = couplings[trailerModel]
	if not coupling then
		return
	end
	couplings[trailerModel] = nil

	if coupling.SeatConnection then
		coupling.SeatConnection:Disconnect()
	end

	local tractorModel = coupling.Tractor
	local trailerChassis = trailerModel.PrimaryPart

	-- The joint folder first: while it exists the two bodies are one
	-- mechanism, and anchoring or re-owning either of them with the hinges
	-- still live means doing it to both, half of which is wrong.
	local joint = trailerChassis and trailerChassis:FindFirstChild(TrailerHitch.JointFolderName)
	if joint then
		joint:Destroy()
	end
	-- Built on the TRACTOR, so it does not go away with the joint folder.
	local pitchOnTractor = tractorModel
		and tractorModel.PrimaryPart
		and tractorModel.PrimaryPart:FindFirstChild("HitchPitch")
	if pitchOnTractor then
		pitchOnTractor:Destroy()
	end

	if trailerChassis then
		pcall(function()
			trailerChassis:SetNetworkOwner(nil)
		end)
		trailerChassis.Anchored = true
	end

	-- Both directions of the ray filter, or the tractor spends the rest of the
	-- session ignoring ground that happens to be where its trailer used to be.
	VehiclePhysics.ClearExtraRayIgnore(trailerModel)
	if tractorModel then
		VehiclePhysics.ClearExtraRayIgnore(tractorModel)
		local link = tractorModel:FindFirstChild(TrailerHitch.Links.TrailerOnTractor)
		if link then
			link.Value = nil
		end
	end

	local backLink = trailerModel:FindFirstChild(TrailerHitch.Links.TractorOnTrailer)
	if backLink then
		backLink.Value = nil
	end
	trailerModel:SetAttribute(TrailerHitch.Attributes.Hitched, false)
	trailerModel:SetAttribute(TrailerHitch.Attributes.ClaimedBy, nil)
end

-- Everything that must be true for `player` to couple `tractorModel` to
-- `trailerModel`, checked here and nowhere else. Returns (ok, reason).
local function canCouple(player, tractorModel, trailerModel)
	if not (tractorModel and tractorModel.PrimaryPart) then
		return false, "No vehicle"
	end
	if not (trailerModel and trailerModel.PrimaryPart) then
		return false, "No trailer"
	end
	if TrailerHitch.GetHitchedTrailer(tractorModel) then
		return false, "Already towing a trailer"
	end
	if trailerModel:GetAttribute(TrailerHitch.Attributes.Hitched) then
		return false, "That trailer is already taken"
	end

	local claimedBy = trailerModel:GetAttribute(TrailerHitch.Attributes.ClaimedBy)
	if claimedBy ~= nil and claimedBy ~= player.UserId then
		return false, "That trailer is reserved"
	end

	-- Their own truck, and one they are actually sitting in. Ownership alone
	-- is not enough: it would let a player hitch a trailer onto a truck parked
	-- across the map while standing next to the trailer.
	if not VehicleOwnership.CanEnter(player, tractorModel) then
		return false, "Not your vehicle"
	end
	local driverSeat = VehicleSeats.GetDriverSeat(tractorModel)
	local occupant = driverSeat and driverSeat.Occupant
	if not (occupant and Players:GetPlayerFromCharacter(occupant.Parent) == player) then
		return false, "Get in the driver's seat first"
	end

	-- Stopped, for the same reason DeliveryManager requires it at a dock: a
	-- moving, client-owned chassis is a lagging echo on the server, and
	-- snapping a trailer onto a position that is already stale would couple
	-- the rig into a pose neither side agrees on.
	if not ParkGrade.IsStopped(tractorModel.PrimaryPart) then
		return false, "Stop completely first"
	end

	return TrailerHitch.CheckAlignment(tractorModel, trailerModel)
end

local function couple(player, tractorModel, trailerModel)
	local ok, reason = canCouple(player, tractorModel, trailerModel)
	if not ok then
		return false, reason
	end

	local target = TrailerHitch.CoupleCFrame(tractorModel, trailerModel)
	if not target then
		return false, "Hitch geometry missing"
	end

	local trailerChassis = trailerModel.PrimaryPart

	-- Claimed before the snap, not after: the snap yields, and two players
	-- backing onto the same trailer in the same second is an ordinary thing to
	-- happen in a shared yard rather than an edge case.
	trailerModel:SetAttribute(TrailerHitch.Attributes.ClaimedBy, player.UserId)

	-- THE SNAP. Anchored throughout, so this is a kinematic move of a body
	-- nothing is simulating - and by the time the hinges below are created the
	-- pose already satisfies them exactly. Building a constraint across a gap
	-- instead hands the solver a violated constraint on frame one, which is
	-- the single most reliable way to make two coupled bodies explode.
	trailerChassis.Anchored = true
	local start = trailerModel:GetPivot()
	local elapsed = 0
	while elapsed < TrailerHitch.SnapSeconds do
		local delta = RunService.Heartbeat:Wait()
		elapsed += delta
		if not (trailerChassis.Parent and tractorModel.Parent) then
			trailerModel:SetAttribute(TrailerHitch.Attributes.ClaimedBy, nil)
			return false, "Trailer went away"
		end
		local alpha = math.clamp(elapsed / TrailerHitch.SnapSeconds, 0, 1)
		trailerModel:PivotTo(start:Lerp(target, alpha))
	end
	-- Re-read rather than reusing `target`: the truck may have been nudged
	-- during the snap, and landing on where it WAS would leave exactly the
	-- constraint violation the snap exists to avoid.
	trailerModel:PivotTo(TrailerHitch.CoupleCFrame(tractorModel, trailerModel) or target)
	trailerChassis.AssemblyLinearVelocity = Vector3.zero
	trailerChassis.AssemblyAngularVelocity = Vector3.zero

	buildGimbal(tractorModel, trailerModel)

	-- Each body's suspension must ignore the other's geometry, or the
	-- tractor's rear struts read the trailer's nose as road and the rig climbs
	-- itself. Set on the server for its own settle loop; the driving client
	-- sets its own copy, because the registry is per-context.
	VehiclePhysics.SetExtraRayIgnore(tractorModel, { trailerModel })
	VehiclePhysics.SetExtraRayIgnore(trailerModel, { tractorModel })

	local link = tractorModel:FindFirstChild(TrailerHitch.Links.TrailerOnTractor)
	if not link then
		link = Instance.new("ObjectValue")
		link.Name = TrailerHitch.Links.TrailerOnTractor
		link.Parent = tractorModel
	end
	link.Value = trailerModel

	local backLink = trailerModel:FindFirstChild(TrailerHitch.Links.TractorOnTrailer)
	if backLink then
		backLink.Value = tractorModel
	end
	trailerModel:SetAttribute(TrailerHitch.Attributes.Hitched, true)

	local driverSeat = VehicleSeats.GetDriverSeat(tractorModel)
	couplings[trailerModel] = {
		Tractor = tractorModel,
		-- The trailer's anchored/owned state has to track the truck's for as
		-- long as they are joined - see followTractorState.
		SeatConnection = driverSeat and driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local coupling = couplings[trailerModel]
			if not coupling then
				return
			end
			local occupant = driverSeat.Occupant
			local driver = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
			-- Deferred a frame: Raycast.server.luau's own Occupant handler
			-- anchors and re-owns the TRACTOR on this same signal, and which
			-- of the two runs first is not defined. Following a state that has
			-- not been written yet would copy the previous one.
			task.defer(function()
				if couplings[trailerModel] then
					followTractorState(trailerModel, tractorModel, driver)
				end
			end)
		end),
	}

	followTractorState(trailerModel, tractorModel, player)
	return true, nil
end

--=============================================================================
-- Requests
--=============================================================================

local function tractorFor(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not (seat and seat.Name == "DriverSeat") then
		return nil
	end
	local model = seat.Parent
	return (model and model:IsA("Model") and model.PrimaryPart) and model or nil
end

hitchRequest.OnServerEvent:Connect(function(player, action)
	if action ~= "hitch" and action ~= "unhitch" then
		return
	end

	local tractorModel = tractorFor(player)
	if not tractorModel then
		return
	end

	if action == "unhitch" then
		local trailerModel = TrailerHitch.GetHitchedTrailer(tractorModel)
		if trailerModel and couplings[trailerModel] then
			uncouple(trailerModel)
		end
		return
	end

	local trailerModel = TrailerHitch.FindCandidate(tractorModel, trailersFolder)
	if not trailerModel then
		return
	end
	local ok, reason = couple(player, tractorModel, trailerModel)
	if not ok then
		-- Only ever a warn: the client runs the identical geometry test before
		-- offering the prompt, so a refusal here means either a race (two
		-- players, one trailer) or a bug, and both are worth seeing in the log
		-- while this is a prototype.
		warn("TrailerHitch: refused " .. player.Name .. "'s hitch request: " .. tostring(reason))
	end
end)

-- A trailer whose tractor is destroyed mid-coupling (despawned from the plot
-- terminal, say) would otherwise be left joined to nothing, unanchored and
-- unowned - a heavy body loose in the world with no way to get it back.
local function watchTractorRemoval()
	while true do
		RunService.Heartbeat:Wait()
		for trailerModel, coupling in couplings do
			if not (trailerModel.Parent and coupling.Tractor.Parent and coupling.Tractor.PrimaryPart) then
				uncouple(trailerModel)
			end
		end
	end
end
task.spawn(watchTractorRemoval)

Players.PlayerRemoving:Connect(function(player)
	-- Drop anything this player was towing rather than leaving it claimed and
	-- coupled to a truck that is about to be cleaned up.
	for trailerModel in couplings do
		if trailerModel:GetAttribute(TrailerHitch.Attributes.ClaimedBy) == player.UserId then
			uncouple(trailerModel)
		end
	end
end)

--=============================================================================

-- Groups are registered by VehicleCollisionSetup.server.luau, which may not
-- have run yet - RegisterCollisionGroup is idempotent behind a pcall (see that
-- script's ensureGroup), so doing it here too costs nothing and removes the
-- ordering dependency between two scripts that otherwise have none.
local Groups = VehicleCollision.Groups

-- EVERY group named in the rules below, not just the ones this script owns.
-- CollisionGroupSetCollidable throws "Both collision groups must be
-- registered" if either side is unknown, and a throw here aborts the rest of
-- the main chunk - which is the trailer setup loop at the bottom. Missing
-- Debris off this list cost exactly that: no welds, no wheels, no groups, and
-- a trailer sitting inert in the yard with nothing obviously wrong with it.
--
-- VehicleCollisionSetup.server.luau registers most of these too, but neither
-- script is ordered against the other, so each has to assume it ran first.
-- RegisterCollisionGroup is idempotent behind a pcall (see that script's
-- ensureGroup), so doing it twice costs nothing.
for _, group in { Groups.Vehicle, Groups.Cosmetic, Groups.Attached, Groups.Debris, Groups.Trailer } do
	pcall(function()
		PhysicsService:RegisterCollisionGroup(group)
	end)
end

-- A trailer's shape hits the world and nothing else that is a vehicle. See the
-- block above setUpTrailerCollision for the measurements behind each of these.
local trailerRules = {
	{ "Default", true },
	-- THE important one: the tractor towing it, and (see the known limitation)
	-- every other vehicle too.
	{ Groups.Vehicle, false },
	{ Groups.Cosmetic, false },
	{ Groups.Attached, false },
	{ Groups.Debris, false },
	-- Two trailers still stack up against each other in a yard, which is what
	-- stops a player parking one inside another.
	{ Groups.Trailer, true },
}
for _, rule in trailerRules do
	local ok, err = pcall(function()
		PhysicsService:CollisionGroupSetCollidable(Groups.Trailer, rule[1], rule[2])
	end)
	if not ok then
		-- Warn and carry on rather than taking trailer setup down with it: a
		-- trailer that collides too much is a bad trailer, one that never got
		-- welded or wheeled is not a trailer at all.
		warn("TrailerHitch: could not set collision rule vs " .. tostring(rule[1]) .. ": " .. tostring(err))
	end
end

for _, trailerModel in trailersFolder:GetChildren() do
	tryAddTrailer(trailerModel)
end
trailersFolder.ChildAdded:Connect(tryAddTrailer)

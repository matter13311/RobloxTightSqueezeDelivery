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

local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
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
-- UPDATE - the limitation above is gone, and so is the blanket rule that
-- caused it. A trailer's shape now collides with vehicles like any other
-- solid thing (see trailerRules at the bottom), and the ONE pairing that must
-- not resolve - a trailer against the tractor that tows it - is switched off
-- part by part with NoCollisionConstraints instead (exemptFromEachOther).
-- Those are per pair, cost no collision group, and are exactly as strong as
-- the group rule was for the two bodies they name. So another player's truck
-- hits a trailer, parked or towed, and a trailer swinging wide hits them.
local NO_COLLIDE_FOLDER = "TractorNoCollide"

-- The parts of a vehicle or trailer that are its collision shape: the chassis
-- and the hull boxes. Read structurally rather than by collision group,
-- because VehicleCollisionSetup may not have grouped a just-spawned truck yet.
local function solidParts(model)
	local parts = {}
	if model.PrimaryPart then
		table.insert(parts, model.PrimaryPart)
	end
	local hulls = VehicleCollision.GetHullFolder(model)
	if hulls then
		for _, part in hulls:GetDescendants() do
			if part:IsA("BasePart") then
				table.insert(parts, part)
			end
		end
	end
	return parts
end

-- Stops `trailerModel` and `tractorModel` colliding with EACH OTHER, and with
-- nothing else. One tractor at a time: linking a trailer to a new truck drops
-- its exemption from the old one.
--
-- Made for a trailer's owner's truck as soon as both exist, not only while
-- coupled. Backing up to hitch puts the tractor's tail under the trailer's
-- nose before the pin is close enough to take, and a solid nose there would
-- stop the truck a couple of studs short of ever being able to couple.
local function exemptFromEachOther(tractorModel, trailerModel)
	local trailerChassis = trailerModel.PrimaryPart
	if not (trailerChassis and tractorModel.PrimaryPart) then
		return
	end
	local existing = trailerChassis:FindFirstChild(NO_COLLIDE_FOLDER)
	if existing then
		if existing:GetAttribute("Tractor") == tractorModel:GetFullName() and existing:FindFirstChildOfClass("NoCollisionConstraint") then
			local first = existing:FindFirstChildOfClass("NoCollisionConstraint")
			if first.Part1 and first.Part1:IsDescendantOf(tractorModel) then
				return -- already exempt from this very truck
			end
		end
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = NO_COLLIDE_FOLDER
	folder:SetAttribute("Tractor", tractorModel:GetFullName())
	for _, trailerPart in solidParts(trailerModel) do
		for _, tractorPart in solidParts(tractorModel) do
			local constraint = Instance.new("NoCollisionConstraint")
			constraint.Part0 = trailerPart
			constraint.Part1 = tractorPart
			constraint.Parent = folder
		end
	end
	folder.Parent = trailerChassis
end

-- Longest edge, in studs, a trailer body part may have and still be knocked
-- off in a crash. See the Body branch below.
local MAX_DETACHABLE_PANEL_SIZE = 20

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
			-- Bodywork can be knocked off in a crash, like a truck's
			-- (VehicleDamage) - but not the shell. The box sides, roof and
			-- floor are single meshes the length of the trailer, and losing one
			-- would leave a see-through trailer and a fifty-stud panel bouncing
			-- down the street. The small stuff - doors, bumper, mudguards,
			-- landing gear - is what comes off. A builder's own NoDetach
			-- (either way) is left alone.
			if
				part:GetAttribute(VehicleCollision.NO_DETACH_ATTRIBUTE) == nil
				and math.max(part.Size.X, part.Size.Y, part.Size.Z) > MAX_DETACHABLE_PANEL_SIZE
			then
				part:SetAttribute(VehicleCollision.NO_DETACH_ATTRIBUTE, true)
			end
		else
			part.CollisionGroup = VehicleCollision.Groups.Attached
		end

		local current = part.CurrentPhysicalProperties
		part.CustomPhysicalProperties =
			PhysicalProperties.new(current.Density, current.Friction, 0, current.FrictionWeight, 100)
	end
end

-- Wheels are drawn for every entry in attachments.VisualWheels: the four real
-- ray points, then any CosmeticWheel* attachments (a tandem/tri-axle group's
-- extra axles - see VehiclePhysics.GetWheelAttachments). The cosmetic ones are
-- Massless for the same reason Raycast.server.luau makes them so: the mass
-- tuneSuspension measures, and the centre of mass it derives the bogie's share
-- from, must stay that of the four wheels that actually carry load. The client
-- poses all of them (TrailerWheels.client.luau -> UpdateWheelVisuals walks the
-- same list), keyed by the instance name used here.
local function attachWheels(trailerModel, chassis, attachments, config)
	local wheelFolder = Instance.new("Folder")
	wheelFolder.Name = "Wheels"
	wheelFolder.Parent = trailerModel

	for _, wheel in attachments.VisualWheels do
		local attachment = wheel.Attachment
		local wheelModelName = VehiclePhysics.GetVisualWheelModelName(config, wheel)
		local wheelModel = wheelModelName and wheelsFolder:FindFirstChild(wheelModelName)
		if not wheelModel then
			warn("TrailerHitch: no wheel model '" .. tostring(wheelModelName) .. "' for " .. trailerModel:GetFullName())
			return
		end

		local cloned = wheelModel:Clone()
		VehiclePhysics.RepairWheelWelds(cloned)
		cloned.Name = wheel.Name
		cloned.Parent = wheelFolder

		local parts = cloned:IsA("Model") and cloned:GetDescendants() or { cloned }
		for _, part in parts do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Anchored = false
				part.CollisionGroup = VehicleCollision.Groups.Attached
				if wheel.IsCosmetic then
					part.Massless = true
				end
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

	-- A dropped trailer has no tractor to mirror anymore - without this an
	-- unhitch mid-brake (or mid-turn-signal) would leave the trailer's lights
	-- stuck on forever, since nothing else ever writes these again once
	-- VehicleNetworkState/VehicleLightSwitches have no coupling to find.
	trailerModel:SetAttribute("NetBraking", false)
	trailerModel:SetAttribute("NetReversing", false)
	trailerModel:SetAttribute("TurnSignal", "None")
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
	-- A spawned trailer is its owner's for life (see the PLAYER TRAILERS
	-- section). FindCandidate already skips other drivers' trailers on both
	-- sides, so this only ever refuses a forged or raced request.
	if not TrailerHitch.CanUse(player.UserId, trailerModel) then
		return false, "That trailer belongs to another driver"
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

	-- Before the trailer is unanchored below, while the two hulls are sitting
	-- inside each other and nothing is simulating either: from the first
	-- simulated frame they must already not be a contact.
	exemptFromEachOther(tractorModel, trailerModel)

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
-- PLAYER TRAILERS
--=============================================================================

-- Every player with a tractor has at most ONE trailer in the world, and it is
-- theirs: stood in a stall at the freight yard when they first drive the
-- tractor in, kept once it is on the truck, and re-used for every job.
--
-- WHY ONE KEPT TRAILER, rather than a fresh one per mission. A trailer per job
-- sounds tidier - the trailer IS the load, so it could appear when a contract
-- is taken and vanish when it is delivered - but it makes the hitch-up, the
-- hardest manoeuvre in the game, a toll on every single job instead of a thing
-- you do once and then own the result of. It also strands the player bobtail
-- at every drop-off. Kept, the rig is the player's rig: back into the freight
-- bay, load, deliver, come back with the same trailer still on.
--
-- WHY THERE IS A RECALL. A kept trailer can be lost - dropped in a street,
-- jackknifed into an alley, left behind when the truck was respawned at the
-- plot. Anything a player can lose needs a way back that is not "leave the
-- game", so a bobtail tractor in the yard can have the trailer brought back to
-- a stall. It is a NEW trailer: whatever the old one was carrying is gone with
-- it, the same rule respawning a loaded truck has always had.

local ServerStorage = game:GetService("ServerStorage")

local playerTrailers = {} -- [userId] = trailer Model

-- Footprint a standing trailer needs, in the stall's own frame: half its
-- length either way along the stall, and most of the stall pitch across it.
-- Deliberately generous along the length - a trailer dropped half out of a
-- stall still blocks it.
local STALL_HALF_LENGTH = 40
local STALL_HALF_WIDTH = 9

-- THE STALLS ARE A HANDFUL AND THE SERVER IS TWELVE PLAYERS, so a stall is
-- never somewhere a trailer LIVES - it is somewhere one waits to be picked up.
-- Three rules keep them turning over, and together they mean any number of
-- players can share any number of stalls:
--
--   1. A trailer is only stood in a stall when its owner drives a bobtail
--      tractor INTO THE YARD (see the arrival loop below), not when the truck
--      spawns at a plot on the far side of the terminal. Stalls hold the
--      trailers of the players who are actually there.
--   2. A parked, empty trailer whose owner has left the yard is cleared away
--      after STALL_IDLE_SECONDS. It comes back by itself the next time they
--      drive in.
--   3. If every stall is still taken when somebody needs one, the trailer
--      that has stood longest goes - but only once it has had
--      STALL_MAX_DWELL_SECONDS, which is plenty of time to back onto it. Its
--      owner is told, and gets it back with T.
--
-- More stalls is still the better answer to a busy yard: add TrailerStall
-- parts to workspace.Delivery.Depot.TrailerStalls and they are used.
local STALL_IDLE_SECONDS = 20
local STALL_MAX_DWELL_SECONDS = 90
-- How far past the recall radius an owner has to be before rule 2 applies, so
-- circling the yard to line up does not count as leaving it.
local STALL_IDLE_MARGIN = 40

-- [trailer Model] = os.clock() when it was first seen standing in a stall.
-- Weak keys: a destroyed trailer must not be kept alive by its stopwatch.
local stalledSince = setmetatable({}, { __mode = "k" })

-- [userId] = true for a player whose trailer was cleared under rule 3. They
-- are not given another automatically - or two players waiting on one stall
-- would take turns evicting each other once a second - only when they ask.
local awaitingManualRecall = {}

local function stallParts()
	local stalls = TrailerHitch.FindStalls()
	local parts = {}
	if stalls then
		for _, child in stalls:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(parts, child)
			end
		end
	end
	-- By name, so everybody fills stall 1 first and the order is the same on
	-- every server rather than whatever GetChildren happens to return.
	table.sort(parts, function(a, b)
		return a.Name < b.Name
	end)
	return parts
end

-- The trailer standing in this stall, or nil.
local function trailerInStall(stall, ignore)
	for _, trailer in trailersFolder:GetChildren() do
		if trailer ~= ignore and trailer:IsA("Model") and trailer.PrimaryPart then
			local offset = trailer.PrimaryPart.Position - stall.Position
			local along = math.abs(offset:Dot(stall.CFrame.LookVector))
			local across = math.abs(offset:Dot(stall.CFrame.RightVector))
			if along < STALL_HALF_LENGTH and across < STALL_HALF_WIDTH then
				return trailer
			end
		end
	end
	return nil
end

local function isLoaded(trailer)
	local units = trailer:GetAttribute(CargoLoad.Attributes.Units)
	return type(units) == "number" and units > 0
end

-- Something other than a trailer standing in the stall: a parked truck, a prop
-- somebody left there. A trailer stood on top of it would be anchored and so
-- look fine, right up until it was hitched and the two were pushed apart.
local obstacleParams = OverlapParams.new()
obstacleParams.FilterType = Enum.RaycastFilterType.Exclude
obstacleParams.RespectCanCollide = true

local function stallObstructed(stall)
	obstacleParams.FilterDescendantsInstances = { trailersFolder }
	-- A trailer-sized box, lifted clear of the ground so the yard surface and
	-- its painted lines never count.
	local box = CFrame.lookAt(stall.Position, stall.Position + stall.CFrame.LookVector) * CFrame.new(0, 6, 0)
	local parts = workspace:GetPartBoundsInBox(box, Vector3.new(8.5, 8, 46), obstacleParams)
	return #parts > 0
end

local destroyPlayerTrailer -- forward declaration; freeStall evicts with it

-- A stall with nothing standing in it, or - rule 3 above - the one whose
-- trailer has been waiting longest, cleared. A stall is never cleared from
-- under a loaded trailer (that would cancel somebody's job to make room for
-- somebody else's) nor from under one that has not yet had its dwell.
local function freeStall(ignore)
	local now = os.clock()
	local evict, evictStall, evictDwell = nil, nil, STALL_MAX_DWELL_SECONDS
	for _, stall in stallParts() do
		local occupant = trailerInStall(stall, ignore)
		if not occupant then
			if not stallObstructed(stall) then
				return stall
			end
			continue
		end
		if
			not occupant:GetAttribute(TrailerHitch.Attributes.Hitched)
			and not isLoaded(occupant)
			and TrailerHitch.GetOwnerUserId(occupant) ~= nil
		then
			local dwell = now - (stalledSince[occupant] or now)
			if dwell >= evictDwell then
				evict, evictStall, evictDwell = occupant, stall, dwell
			end
		end
	end
	if evict then
		local ownerId = TrailerHitch.GetOwnerUserId(evict)
		destroyPlayerTrailer(ownerId)
		awaitingManualRecall[ownerId] = true
		local owner = Players:GetPlayerByUserId(ownerId)
		if owner then
			hitchRequest:FireClient(owner, "notice", "Your trailer was moved to make room - press T in the yard to bring it back")
		end
		return evictStall
	end
	return nil
end

destroyPlayerTrailer = function(userId)
	local trailer = playerTrailers[userId]
	playerTrailers[userId] = nil
	if not trailer then
		return
	end
	-- Uncoupled first, so the tractor's link, its ray filter and the pitch
	-- attachment built on its chassis are all cleaned up by the one function
	-- that knows about them, rather than left pointing at a destroyed model.
	if couplings[trailer] then
		uncouple(trailer)
	end
	trailer:Destroy()
end

-- Stands a fresh trailer for `player` in a stall, replacing any they already
-- have. Returns (ok, reason).
local function spawnPlayerTrailer(player)
	local templates = ServerStorage:FindFirstChild(TrailerHitch.TemplateFolderName)
	local template = templates and templates:FindFirstChild(TrailerHitch.PlayerTemplateName)
	if not template then
		warn(
			"TrailerHitch: no ServerStorage."
				.. TrailerHitch.TemplateFolderName
				.. "."
				.. TrailerHitch.PlayerTemplateName
				.. " - nobody can be given a trailer. Put the trailer model there."
		)
		return false, "No trailer available"
	end

	local stall = freeStall(playerTrailers[player.UserId])
	if not stall then
		return false, "The trailer stalls are full - try again in a moment"
	end

	destroyPlayerTrailer(player.UserId)

	local trailer = template:Clone()
	trailer:SetAttribute(TrailerHitch.Attributes.Owner, player.UserId)
	-- Atomic for the same reason PlotManager spawns cars that way: the whole
	-- model streams in and out as one, so no client ever holds a trailer with
	-- no PrimaryPart.
	trailer.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	-- Centred on the stall by its BOUNDING BOX, not its pivot: the pivot is the
	-- chassis, which sits well back from the middle of a trailer whose body
	-- overhangs the kingpin. Height is only roughly right here - addTrailer's
	-- placeOnGround sets it properly the moment the model is parented.
	local facing = CFrame.lookAt(stall.Position, stall.Position + stall.CFrame.LookVector)
	local boxCFrame = trailer:GetBoundingBox()
	local boxOffset = trailer:GetPivot():ToObjectSpace(boxCFrame).Position
	trailer:PivotTo(facing * CFrame.new(-boxOffset.X, 5, -boxOffset.Z))

	playerTrailers[player.UserId] = trailer
	trailer.Parent = trailersFolder

	-- Their truck may drive through their own trailer's shape - see
	-- exemptFromEachOther for why that has to be true before coupling.
	for _, carModel in workspace.Vehicles:GetChildren() do
		if
			carModel:IsA("Model")
			and TrailerHitch.CanTow(carModel)
			and VehicleOwnership.GetOwnerUserId(carModel) == player.UserId
		then
			exemptFromEachOther(carModel, trailer)
		end
	end
	return true, nil
end

local vehicleFolder = workspace:WaitForChild("Vehicles")

-- A player who respawns their tractor at the plot has a NEW truck and,
-- possibly, the same trailer still standing somewhere: point its exemption at
-- the new one.
vehicleFolder.ChildAdded:Connect(function(carModel)
	if not (carModel:IsA("Model") and TrailerHitch.CanTow(carModel)) then
		return
	end
	local trailer = playerTrailers[VehicleOwnership.GetOwnerUserId(carModel) or 0]
	if trailer and trailer.Parent then
		-- Deferred so the truck's Collision folder has replicated its welds
		-- and PrimaryPart before its parts are enumerated.
		task.defer(exemptFromEachOther, carModel, trailer)
	end
end)

-- The tractor this player is driving, if it is theirs to tow with and has
-- nothing on the back.
local function bobtailTractorOf(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	local carModel = seat and seat.Name == "DriverSeat" and seat.Parent
	if
		carModel
		and carModel:IsA("Model")
		and carModel.PrimaryPart
		and carModel.Parent == vehicleFolder
		and TrailerHitch.CanTow(carModel)
		and VehicleOwnership.CanEnter(player, carModel)
		and not TrailerHitch.GetHitchedTrailer(carModel)
	then
		return carModel
	end
	return nil
end

-- [Player] = true once they have been told the stalls are full, so the
-- message is one line when they arrive rather than one a second while they
-- wait. Cleared the moment they get a trailer or leave the yard.
local toldStallsFull = {}

-- The arrival loop: rules 1 and 2 above. Once a second is plenty - it decides
-- things that happen over tens of seconds, on at most a dozen players.
local function tendStalls()
	local stalls = TrailerHitch.FindStalls()
	if not stalls then
		return
	end
	local yard = stalls:GetPivot().Position
	local now = os.clock()

	-- Rule 1: a bobtail tractor in the yard whose owner has no trailer
	-- anywhere gets one. A player who HAS one somewhere else is left alone -
	-- fetching it replaces it, which can cancel a job, so that is their key
	-- press to make (the recall request, below).
	for _, player in Players:GetPlayers() do
		local tractor = bobtailTractorOf(player)
		local inYard = tractor ~= nil
			and (tractor.PrimaryPart.Position - yard).Magnitude <= TrailerHitch.RecallRadius
		if not inYard then
			toldStallsFull[player] = nil
			continue
		end
		local existing = playerTrailers[player.UserId]
		if existing and not existing.Parent then
			playerTrailers[player.UserId] = nil
			existing = nil
		end
		if existing or awaitingManualRecall[player.UserId] then
			continue
		end
		local ok, reason = spawnPlayerTrailer(player)
		if ok then
			toldStallsFull[player] = nil
		elseif not toldStallsFull[player] then
			toldStallsFull[player] = true
			hitchRequest:FireClient(player, "notice", reason)
		end
	end

	-- Rule 2, and the stopwatch rule 3 reads.
	for userId, trailer in playerTrailers do
		if not (trailer.Parent and trailer.PrimaryPart) then
			playerTrailers[userId] = nil
			continue
		end
		local standing = false
		if not trailer:GetAttribute(TrailerHitch.Attributes.Hitched) then
			for _, stall in stallParts() do
				if trailerInStall(stall) == trailer then
					standing = true
					break
				end
			end
		end
		if not standing then
			stalledSince[trailer] = nil
			continue
		end
		stalledSince[trailer] = stalledSince[trailer] or now

		local owner = Players:GetPlayerByUserId(userId)
		local root = owner and owner.Character and owner.Character.PrimaryPart
		local ownerAway = not root
			or (root.Position - yard).Magnitude > TrailerHitch.RecallRadius + STALL_IDLE_MARGIN
		if ownerAway and not isLoaded(trailer) and now - stalledSince[trailer] >= STALL_IDLE_SECONDS then
			destroyPlayerTrailer(userId)
		end
	end
end

task.spawn(function()
	while true do
		task.wait(1)
		local ok, err = pcall(tendStalls)
		if not ok then
			warn("TrailerHitch: stall upkeep failed: " .. tostring(err))
		end
	end
end)

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

-- [Player] = os.clock() of their last recall. A recall destroys and rebuilds a
-- whole model, so it is the one request here worth rate-limiting.
local lastRecall = {}
local RECALL_COOLDOWN_SECONDS = 3

local function recall(player, tractorModel)
	if not VehicleOwnership.CanEnter(player, tractorModel) or not TrailerHitch.CanTow(tractorModel) then
		return
	end
	if TrailerHitch.GetHitchedTrailer(tractorModel) then
		return -- it is on the back of the truck; there is nothing to fetch
	end
	if not TrailerHitch.CanRecall(tractorModel.PrimaryPart.Position, trailersFolder, player.UserId) then
		return
	end
	local now = os.clock()
	if lastRecall[player] and now - lastRecall[player] < RECALL_COOLDOWN_SECONDS then
		return
	end
	lastRecall[player] = now
	awaitingManualRecall[player.UserId] = nil

	local ok, reason = spawnPlayerTrailer(player)
	hitchRequest:FireClient(player, "notice", if ok then "Your trailer is waiting in the stalls" else reason)
end

hitchRequest.OnServerEvent:Connect(function(player, action)
	if action ~= "hitch" and action ~= "unhitch" and action ~= "recall" then
		return
	end

	local tractorModel = tractorFor(player)
	if not tractorModel then
		return
	end

	if action == "recall" then
		recall(player, tractorModel)
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
		-- The client runs the identical geometry test before offering the
		-- prompt, so a refusal here means either a race or a bug - worth a line
		-- in the log, and worth telling the player rather than leaving them
		-- pressing a key that does nothing.
		warn("TrailerHitch: refused " .. player.Name .. "'s hitch request: " .. tostring(reason))
		hitchRequest:FireClient(player, "notice", tostring(reason))
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
	-- Their own trailer leaves with them, wherever it was standing - nobody
	-- else can couple to it, so left behind it would only ever be an obstacle.
	destroyPlayerTrailer(player.UserId)
	lastRecall[player] = nil
	toldStallsFull[player] = nil
	awaitingManualRecall[player.UserId] = nil
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
	-- Solid against every vehicle. The tractor towing it is the one exception,
	-- and that is made per pair by exemptFromEachOther, not here.
	{ Groups.Vehicle, true },
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

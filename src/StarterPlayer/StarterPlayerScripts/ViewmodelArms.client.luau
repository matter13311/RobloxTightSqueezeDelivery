-- First-person driving arms, built from the PLAYER'S OWN avatar.
--
-- The rig is cloned off the local character every time they sit down: the
-- actual arm parts (mesh, skin colour, textures), their classic shirt, and any
-- rigid accessory worn on an arm - slimmed down (by the player's "Arm size"
-- setting) so they do not fill the windscreen, or hidden outright if the
-- player has turned "Show arms" off.
--
-- Avatars come in every arm length there is, so the pose is solved rather
-- than authored: each hand is placed ON the steering wheel's rim (read off the
-- real wheel prop in the cab, so it is right for every car) and a two-bone IK
-- works the elbow and shoulder back from there. Steering carries the grip
-- points round the rim with the wheel, hand over hand, and the arms follow.
--
-- Everything is solved in the DriverSeat's own space and applied through
-- Motor6Ds hanging off one root part welded to the seat - so physics carries
-- the arms with the car and nothing here has to chase a moving vehicle from a
-- render callback (which is always a frame late).
--
-- Client-only: nobody else needs to see your own driving hands, same as an
-- FPS game never replicates its viewmodel to other players.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local GameSettings = require(script.Parent.GameSettings)
local VehicleEyePoint = require(script.Parent.VehicleEyePoint)
local VehicleViewMode = require(script.Parent.VehicleViewMode)

local player = Players.LocalPlayer

-- How much of the avatar's real arm size the driving arms keep. Full-size
-- avatar arms this close to the camera are a pair of slabs across the bottom
-- of the view, so they are thinned and shortened a little; the shoulders slide
-- to make up any lost reach.
--
-- THICKNESS is the player's own choice - the "Arm size" setting, a percentage -
-- because no one value suits every avatar: what slims a blocky bundle nicely
-- leaves a slender one with twigs. Length barely changes what is on screen, so
-- it stays fixed.
local ARM_SIZE_SETTING = "ArmSize"
local ARMS_VISIBLE_SETTING = "ArmsVisible"
local ARM_LENGTH_SCALE = 0.85

-- Per axis of each arm part: Y runs along the arm, X and Z are its thickness.
local function getArmScale()
	local thickness = (GameSettings.Get(ARM_SIZE_SETTING) or 40) / 100
	return Vector3.new(thickness, ARM_LENGTH_SCALE, thickness)
end

-- Where each shoulder sits relative to the pinned EYE (seat space: +X right,
-- +Y up, +Z towards the back of the car). Hung off the eye rather than off the
-- avatar's real shoulders for the same reason the eye itself is pinned - what
-- the driver sees is a property of the car, not of what they are wearing. X is
-- mirrored for the left arm.
local SHOULDER_FROM_EYE = Vector3.new(0.95, -1.05, 0.3)

-- An arm is never allowed to lock out dead straight: past this fraction of its
-- full reach the shoulder is slid towards the hand instead. That is also what
-- lets a short-armed avatar hold a wheel its arms could not otherwise reach -
-- the shoulder is off screen, so nobody sees it move.
local MAX_REACH_FRACTION = 0.92

-- Which way the elbow points (seat space, mirrored for the left arm): down and
-- out, the way a relaxed driver's elbows hang.
local ELBOW_POLE = Vector3.new(0.7, -1, 0.25)

-- Resting grip, as an angle up from the wheel's horizontal - a bit above
-- "quarter to three".
local GRIP_REST_ANGLE = math.rad(12)

-- HAND OVER HAND, and the whole of it is a pure function of the steering.
--
-- There is no clock in the steering pose: where each hand is depends ONLY on
-- how far the wheel is turned right now. That is what keeps the arms and the
-- wheel in step - the hands move exactly while the wheel moves, are at lock on
-- the frame it is at lock, are back on their resting grip the frame it is
-- back at centre, and can never be caught finishing something off after the
-- wheel has stopped. Steer half way and hold, and the hands hold half way.
--
-- The choreography, turning right (left is its mirror image): both hands ride
-- round with the wheel. The left hand keeps hold the whole way, pushing up
-- and over the top. The right hand is carried down its side of the wheel, and
-- between CROSS_START and CROSS_END of turn it lets go, comes up off the rim,
-- crosses over the left arm and re-grabs HAND_SPACING behind the left hand -
-- then rides on from there to lock. Unwinding plays the same thing backwards.

-- How far round the ARMS go by the time the wheel is at full lock. Less than
-- the wheel itself turns, on purpose. A keyboard driver's wheel prop spins a
-- full revolution to lock in well under half a second; hands that really
-- followed the rim that far would be a blur of crossings. So the arms are
-- GEARED DOWN: they move for exactly as long as the wheel does but cover less
-- ground - one hand-over on the way to lock - with the rim slipping through
-- the grip to make up the difference.
--
-- This is the "length of the animation": lower it and the hands do less (and
-- so move slower) for the same turn of the wheel. It has to stay above
-- CROSS_END or the crossing hand would be left in mid-air at full lock.
local ARM_SWEEP_AT_LOCK = math.rad(180)

-- The stretch of the arms' turn over which the crossing happens. Wider is a
-- slower, more deliberate hand-over; narrower is a quick snatch.
local CROSS_START = math.rad(25)
local CROSS_END = math.rad(105)

-- How far behind the gripping hand the crossing hand takes its new grip.
local HAND_SPACING = math.rad(90)

-- How far the crossing hand comes off the rim at the top of its arc: towards
-- the driver (enough to clear the other forearm), and out.
local REGRAB_LIFT = Vector3.new(0.1, 0.4, 0) -- (radially outward, along the column)

-- For a wheel with too little travel to fit a hand-over into: the hands just
-- ride the rim, and no further round than this.
local NO_CROSS_SWEEP = math.rad(35)

-- How far inside the prop's bounding radius the middle of the rim tube is.
local RIM_INSET = 0.08

-- Used only if a car has no SteeringWheel prop at all: an invisible wheel
-- where the cabs in this game typically have one (seat space).
local FALLBACK_WHEEL = {
	Centre = Vector3.new(0, 2.05, -1.2),
	Axis = Vector3.new(0, 0.45, 0.89).Unit,
	Radius = 0.85,
}

local currentArms = nil
local currentSteerConnection = nil
local currentVisibilityConnection = nil
local armsHidden = false

-- These are a VIEWMODEL: a prop that only makes sense from inside the driver's
-- head. From any third person view they are a second pair of hands floating at
-- the wheel next to the real avatar's, so in third person there is no rig in
-- the world at all - the avatar just sits on the seat as it normally would.
--
-- Un-parented rather than made transparent: nothing about a model that is not
-- in the DataModel can be drawn, whatever a texture, shirt or accessory does
-- with transparency. The rig is kept (not destroyed) because the player can
-- zoom back in at any moment, and rebuilding it on every flick of the scroll
-- wheel would be far more work than a re-parent.
--
-- Client-only by construction: this is a LocalScript parenting into
-- workspace, so the rig never replicates - other players only ever see the
-- avatar itself.
local function setArmsHidden(hidden)
	if not currentArms then
		return
	end
	currentArms.Parent = if hidden then nil else workspace
	armsHidden = hidden
end

-- First person only (see above), and only if the player wants them at all.
local function shouldShowArms()
	return VehicleViewMode.IsFirstPerson() and GameSettings.Get(ARMS_VISIBLE_SETTING) ~= false
end

local function removeArms()
	if currentSteerConnection then
		currentSteerConnection:Disconnect()
		currentSteerConnection = nil
	end
	if currentVisibilityConnection then
		currentVisibilityConnection:Disconnect()
		currentVisibilityConnection = nil
	end
	if currentArms then
		currentArms:Destroy()
		currentArms = nil
	end
	armsHidden = false
end

-- A rotation-only CFrame whose Y axis is `axis` and whose X axis is `hinge`
-- (squared up against it). Building one of these for a bone in the part's own
-- space and another for where that bone has to end up in the car gives the
-- rotation between them without ever touching Euler angles.
local function boneFrame(axis, hinge)
	local x = hinge - axis * hinge:Dot(axis)
	if x.Magnitude < 1e-4 then
		-- hinge ran along the bone; any perpendicular will do
		x = axis:Cross(Vector3.zAxis)
		if x.Magnitude < 1e-4 then
			x = axis:Cross(Vector3.xAxis)
		end
	end
	x = x.Unit
	return CFrame.fromMatrix(Vector3.zero, x, axis, x:Cross(axis))
end

-- Makes a cloned avatar part into an inert visual prop. The joints HAVE to go:
-- cloning a single limb keeps its Motor6D's reference to the real character's
-- torso, which would bolt the viewmodel to the avatar sitting in the seat.
local function prepareClone(part)
	for _, descendant in part:GetDescendants() do
		if
			descendant:IsA("JointInstance")
			or descendant:IsA("WeldConstraint")
			or descendant:IsA("LuaSourceContainer")
			or descendant:IsA("Sound")
			or descendant:IsA("TouchTransmitter")
		then
			descendant:Destroy()
		end
	end
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	-- Massless: this rig is a visual prop, not part of the car's weight -
	-- without this it would quietly change the chassis' mass and throw off
	-- handling every time someone gets in.
	part.Massless = true
	part.CastShadow = false
end

-- Resizes a cloned part about its own centre, taking everything measured in
-- its space along with it - the rig attachments the solver reads the joints
-- off, and the mesh of an old-style accessory.
local function scaleClone(part, scale)
	part.Size *= scale
	for _, descendant in part:GetDescendants() do
		if descendant:IsA("Attachment") then
			descendant.Position *= scale
		elseif descendant:IsA("SpecialMesh") and descendant.MeshType == Enum.MeshType.FileMesh then
			descendant.Scale *= scale
		end
	end
end

local function attachmentPosition(part, name, fallback)
	local attachment = part:FindFirstChild(name)
	if attachment and attachment:IsA("Attachment") then
		return attachment.Position
	end
	return fallback
end

local function newMotor(root, part)
	local motor = Instance.new("Motor6D")
	motor.Name = part.Name
	motor.Part0 = root
	motor.Part1 = part
	motor.Parent = root
	return motor
end

-- One arm's worth of cloned parts plus the measurements the solver needs, or
-- nil if the character has no such arm (still loading, or an avatar that
-- genuinely has not got one). `side` is "Left" or "Right".
--
-- R15 gives three parts and rig attachments marking every joint, which is all
-- a two-bone IK needs. R6 is a single block per arm with no elbow, so it gets
-- a simpler pose: the block is aimed from the shoulder at the rim.
local function buildArm(character, model, root, side, armScale)
	local sign = if side == "Left" then -1 else 1
	local upper = character:FindFirstChild(side .. "UpperArm")
	local lower = character:FindFirstChild(side .. "LowerArm")
	local hand = character:FindFirstChild(side .. "Hand")

	local arm = { Sign = sign, Sources = {} }

	if upper and lower and hand then
		local upperClone, lowerClone, handClone = upper:Clone(), lower:Clone(), hand:Clone()
		if not (upperClone and lowerClone and handClone) then
			return nil
		end
		for source, clone in { [upper] = upperClone, [lower] = lowerClone, [hand] = handClone } do
			prepareClone(clone)
			scaleClone(clone, armScale)
			clone.Parent = model
			arm.Sources[source] = clone
		end

		local shoulder = attachmentPosition(upperClone, side .. "ShoulderRigAttachment", Vector3.new(0, upperClone.Size.Y / 2, 0))
		local upperElbow = attachmentPosition(upperClone, side .. "ElbowRigAttachment", Vector3.new(0, -upperClone.Size.Y / 2, 0))
		local lowerElbow = attachmentPosition(lowerClone, side .. "ElbowRigAttachment", Vector3.new(0, lowerClone.Size.Y / 2, 0))
		local lowerWrist = attachmentPosition(lowerClone, side .. "WristRigAttachment", Vector3.new(0, -lowerClone.Size.Y / 2, 0))

		arm.Jointed = true
		arm.UpperShoulder = shoulder
		arm.UpperLength = (upperElbow - shoulder).Magnitude
		arm.UpperRest = boneFrame((upperElbow - shoulder).Unit, Vector3.xAxis):Inverse()
		arm.LowerElbow = lowerElbow
		arm.LowerLength = (lowerWrist - lowerElbow).Magnitude
		arm.LowerRest = boneFrame((lowerWrist - lowerElbow).Unit, Vector3.xAxis):Inverse()
		arm.HandWrist = attachmentPosition(handClone, side .. "WristRigAttachment", Vector3.new(0, handClone.Size.Y / 2, 0))
		arm.HandGrip = attachmentPosition(handClone, side .. "GripAttachment", Vector3.new(0, -handClone.Size.Y / 4, 0))

		arm.UpperMotor = newMotor(root, upperClone)
		arm.LowerMotor = newMotor(root, lowerClone)
		arm.HandMotor = newMotor(root, handClone)
		return arm
	end

	local whole = character:FindFirstChild(side .. " Arm")
	if whole and whole:IsA("BasePart") then
		local clone = whole:Clone()
		if not clone then
			return nil
		end
		prepareClone(clone)
		scaleClone(clone, armScale)
		clone.Parent = model
		arm.Sources[whole] = clone
		arm.Jointed = false
		-- Just short of the block's end, so the rim sits in the "hand".
		arm.HandGrip = Vector3.new(0, -clone.Size.Y / 2 + 0.2, 0)
		arm.HandMotor = newMotor(root, clone)
		return arm
	end

	return nil
end

-- Brings along anything rigid the avatar wears ON an arm (bracelets, watches,
-- gloves-as-accessories). Layered clothing is skipped: it is a deforming mesh
-- wrapped round the whole body's cage and cannot be cut down to its sleeves.
local function cloneArmAccessories(character, model, sources, armScale)
	for _, accessory in character:GetChildren() do
		local handle = accessory:IsA("Accessory") and accessory:FindFirstChild("Handle")
		if not (handle and handle:IsA("BasePart")) or handle:FindFirstChildWhichIsA("WrapLayer") then
			continue
		end
		local weld = handle:FindFirstChild("AccessoryWeld")
		if not (weld and weld:IsA("JointInstance")) then
			continue
		end
		local source = if weld.Part0 == handle then weld.Part1 else weld.Part0
		local armClone = source and sources[source]
		if not armClone then
			continue
		end

		local handleClone = handle:Clone()
		if not handleClone then
			continue
		end
		prepareClone(handleClone)
		-- Shrunk with the arm it sits on. An accessory is not lined up with
		-- the arm's axes, so it gets the arm's thickness scale all round
		-- rather than a squash along some arbitrary direction of its own;
		-- where it SITS is in the arm's space, so that scales per axis.
		scaleClone(handleClone, Vector3.one * armScale.X)
		handleClone.Name = accessory.Name

		local offset = source.CFrame:ToObjectSpace(handle.CFrame)
		local joint = Instance.new("Weld")
		joint.Part0 = armClone
		joint.Part1 = handleClone
		joint.C0 = offset.Rotation + offset.Position * armScale
		joint.Parent = handleClone
		handleClone.Parent = model
	end
end

-- Where the wheel is, which way its column points and how big its rim is, all
-- in the seat's space. Read once on entry: the prop only ever spins about its
-- own column through its own centre, so none of this changes while driving.
local function measureWheel(carModel, seat, eyeOffset)
	local part = VehiclePhysics.GetSteeringWheelPart(carModel)
	local chassis = carModel.PrimaryPart
	if not (part and chassis) then
		return FALLBACK_WHEEL
	end

	local config = VehiclePhysics.GetConfig(chassis)
	local localAxis = VehiclePhysics.AxisFromConfig(config.SteeringWheelAxis, part)
	local centre = seat.CFrame:PointToObjectSpace(part.Position)
	local axis = seat.CFrame:VectorToObjectSpace(part.CFrame:VectorToWorldSpace(localAxis)).Unit
	-- "Auto" only knows the column's line, not which end is which. Everything
	-- below wants it pointing AT the driver.
	if axis:Dot(eyeOffset.Position - centre) < 0 then
		axis = -axis
	end

	-- The two dimensions across the column are the wheel's face; the smaller
	-- is the safer radius for a prop that is not perfectly round.
	local size = part.Size
	local along = math.abs(localAxis.X) * size.X + math.abs(localAxis.Y) * size.Y + math.abs(localAxis.Z) * size.Z
	local across = {}
	for _, dimension in { "X", "Y", "Z" } do
		if math.abs(localAxis[dimension]) < 0.5 then
			table.insert(across, size[dimension])
		end
	end
	local radius = (if #across > 0 then math.min(table.unpack(across)) else 1.8) / 2 - RIM_INSET

	-- A prop modelled with its boss or a stub of column is deeper than its
	-- rim, and the rim is always at the driver's end of it.
	centre += axis * math.max(along / 2 - 0.15, 0)

	return {
		Centre = centre,
		Axis = axis,
		Radius = radius,
		MaxAngle = math.rad(config.SteeringWheelMaxAngle or 0),
	}
end

-- Where this hand is on the rim for a given turn of the wheel, as an angle
-- clockwise from this arm's own side of the wheel (so 0 is 3 o'clock for the
-- right hand and 9 o'clock for the left), plus how far it is lifted off the
-- rim (0..1). `armAngle` is the ARMS' wheel angle - the geared-down one, see
-- ARM_SWEEP_AT_LOCK - positive = steering right. See the HAND OVER HAND note
-- at the top for the choreography this implements.
local function gripForAngle(arm, armAngle, canCross)
	-- Worked out as if this were the right hand, with `toward` the turn
	-- TOWARDS this hand's own side; the left hand is the exact mirror, so the
	-- sign goes back on at the end. Angles here are clockwise from 12.
	local rest = math.pi / 2 - GRIP_REST_ANGLE
	local toward = armAngle * arm.Sign
	local angle = rest + toward
	local lift = 0

	if canCross and toward > CROSS_START then
		-- This hand is the one being carried down its own side, so it is the
		-- one that crosses: from riding its resting spot to riding a spot
		-- HAND_SPACING behind where the OTHER hand (which started a mirror
		-- image away and has turned just as far) now is.
		local progress = math.clamp((toward - CROSS_START) / (CROSS_END - CROSS_START), 0, 1)
		local eased = progress * progress * (3 - 2 * progress)
		angle -= eased * (2 * rest + HAND_SPACING)
		lift = math.sin(math.pi * progress)
	end

	return arm.Sign * (angle - math.pi / 2), lift
end

-- Poses one arm with its hand on the rim.
local function poseArm(arm, wheel, shoulderHome, armAngle, canCross)
	local sign = arm.Sign
	local axis = wheel.Axis
	local gripAngle, lift = gripForAngle(arm, armAngle, canCross)

	-- Straight out to this arm's side of the wheel, flattened into the
	-- wheel's own plane, then wound round the column to wherever the hand is
	-- gripping. The axis points at the driver, so "clockwise as the driver
	-- sees it" is a NEGATIVE rotation about it.
	local side = Vector3.new(sign, 0, 0)
	side = (side - axis * side:Dot(axis)).Unit
	local radial = CFrame.fromAxisAngle(axis, -gripAngle):VectorToWorldSpace(side)
	local gripPoint = wheel.Centre
		+ radial * (wheel.Radius + REGRAB_LIFT.X * lift)
		+ axis * (REGRAB_LIFT.Y * lift)

	local shoulder = shoulderHome

	if not arm.Jointed then
		-- R6: one block, aimed from the shoulder at the rim.
		local along = (shoulder - gripPoint).Unit
		local rotation = boneFrame(along, -radial * sign)
		arm.HandMotor.C0 = CFrame.new(gripPoint) * rotation * CFrame.new(-arm.HandGrip)
		return
	end

	-- The hand: fingers reaching forward through the wheel (the hand's -Y is
	-- its fingertip end), palm against the rim facing the hub. A left palm is
	-- the hand's +X face and a right palm its -X, hence the sign.
	local handX = -radial * sign
	local handRotation = CFrame.fromMatrix(Vector3.zero, handX, axis, handX:Cross(axis))
	local handCFrame = CFrame.new(gripPoint) * handRotation * CFrame.new(-arm.HandGrip)
	arm.HandMotor.C0 = handCFrame

	local wrist = handCFrame * arm.HandWrist
	local upperLength, lowerLength = arm.UpperLength, arm.LowerLength
	local maxReach = (upperLength + lowerLength) * MAX_REACH_FRACTION
	local minReach = math.abs(upperLength - lowerLength) + 0.05

	local toWrist = wrist - shoulder
	local distance = toWrist.Magnitude
	local direction = if distance > 1e-4 then toWrist / distance else -Vector3.zAxis
	if distance > maxReach or distance < minReach then
		distance = math.clamp(distance, minReach, maxReach)
		shoulder = wrist - direction * distance
	end

	-- Law of cosines for the angle at the shoulder, then the elbow is that far
	-- off the shoulder-wrist line, towards the pole.
	local cosine = (upperLength * upperLength + distance * distance - lowerLength * lowerLength) / (2 * upperLength * distance)
	cosine = math.clamp(cosine, -1, 1)
	local pole = Vector3.new(ELBOW_POLE.X * sign, ELBOW_POLE.Y, ELBOW_POLE.Z)
	local outward = pole - direction * pole:Dot(direction)
	outward = if outward.Magnitude > 1e-4 then outward.Unit else Vector3.yAxis:Cross(direction).Unit
	local elbow = shoulder + direction * (upperLength * cosine) + outward * (upperLength * math.sqrt(1 - cosine * cosine))

	-- An R15 elbow folds the forearm FORWARD about the arm's +X axis, so +X
	-- has to end up along this for the bend to go the anatomical way round
	-- rather than showing the back of the elbow on the inside of the fold.
	local hinge = outward:Cross(direction)

	arm.UpperMotor.C0 = CFrame.new(shoulder) * boneFrame((elbow - shoulder).Unit, hinge) * arm.UpperRest * CFrame.new(-arm.UpperShoulder)
	arm.LowerMotor.C0 = CFrame.new(elbow) * boneFrame((wrist - elbow).Unit, hinge) * arm.LowerRest * CFrame.new(-arm.LowerElbow)
end

local function attachArms(carModel, character)
	removeArms()

	local driverSeat = VehicleSeats.GetDriverSeat(carModel)
	if not driverSeat then
		return
	end

	local model = Instance.new("Model")
	model.Name = "ViewmodelArms"

	-- The one part physics actually holds on to. Sits exactly on the seat, so
	-- "seat space" and "root space" are the same thing and every Motor6D.C0
	-- below is simply where that part belongs in the cab.
	local root = Instance.new("Part")
	root.Name = "ArmsRoot" -- deliberately NOT HumanoidRootPart: see the Humanoid below
	root.Size = Vector3.one * 0.2
	root.Transparency = 1
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = false
	root.Massless = true
	root.CFrame = driverSeat.CFrame
	root.Parent = model

	local armScale = getArmScale()
	local arms = {}
	local sources = {}
	for _, side in { "Left", "Right" } do
		local arm = buildArm(character, model, root, side, armScale)
		if arm then
			table.insert(arms, arm)
			for source, clone in arm.Sources do
				sources[source] = clone
			end
		end
	end
	if #arms == 0 then
		model:Destroy()
		return
	end
	cloneArmAccessories(character, model, sources, armScale)

	-- Classic shirts are not a property of the arm: Roblox paints them on only
	-- for limbs inside a model that has a Humanoid and the Shirt next to it.
	-- So the rig gets a Humanoid purely as a clothes hanger. It must never
	-- wake up as a CHARACTER - a live humanoid welded into the car's assembly
	-- fights the raycast suspension for control of it, which once made cars
	-- grind to a halt a second after getting in - so its state machine is
	-- switched off and the rig has no HumanoidRootPart for it to push on.
	local sourceHumanoid = character:FindFirstChildOfClass("Humanoid")
	local humanoid = Instance.new("Humanoid")
	humanoid.EvaluateStateMachine = false
	humanoid.AutomaticScalingEnabled = false -- or it would put the limbs back to avatar size, undoing the arm scale
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	if sourceHumanoid then
		humanoid.RigType = sourceHumanoid.RigType
	end
	humanoid.Parent = model
	local shirt = character:FindFirstChildOfClass("Shirt")
	if shirt then
		shirt:Clone().Parent = model
	end

	local eyeOffset = VehicleEyePoint.GetSeatEyeOffset(driverSeat)
	local wheel = measureWheel(carModel, driverSeat, eyeOffset)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = driverSeat
	weld.Part1 = root
	weld.Parent = root

	model.Parent = workspace
	currentArms = model
	-- The clones were taken off a character that VehicleEyePoint may already
	-- have hidden for first person, so start from a known state.
	setArmsHidden(not shouldShowArms())

	currentVisibilityConnection = RunService.RenderStepped:Connect(function()
		local hide = not shouldShowArms()
		if hide ~= armsHidden then
			setArmsHidden(hide)
		end
	end)

	-- See ARM_SWEEP_AT_LOCK. Never MORE than the wheel itself turns, so a car
	-- with a short-travel wheel keeps its hands glued to the rim - and if that
	-- leaves no room to finish a hand-over, there is no hand-over at all
	-- rather than one abandoned half way.
	local sweepAtLock = math.min(ARM_SWEEP_AT_LOCK, wheel.MaxAngle or ARM_SWEEP_AT_LOCK)
	local canCross = sweepAtLock >= CROSS_END
	if not canCross then
		sweepAtLock = math.min(sweepAtLock, NO_CROSS_SWEEP)
	end

	currentSteerConnection = RunService.RenderStepped:Connect(function()
		if armsHidden then
			return
		end
		-- LocalSmoothSteer (set by RayCastSuspension every frame, purely
		-- local, no network round-trip) is the driver's own frame-perfect
		-- steer value - the same one the actual wheel prop turns with.
		-- NetSteer is only a fallback for the first frame or so, before
		-- that script has run yet.
		local steer = carModel:GetAttribute("LocalSmoothSteer") or carModel:GetAttribute("NetSteer") or 0
		-- Straight off the steer value, with nothing smoothing or delaying it:
		-- the arms are at lock on the same frame the wheel is, and stop dead
		-- with it.
		local armAngle = steer * sweepAtLock

		for _, arm in arms do
			local shoulderHome = eyeOffset.Position
				+ Vector3.new(SHOULDER_FROM_EYE.X * arm.Sign, SHOULDER_FROM_EYE.Y, SHOULDER_FROM_EYE.Z)
			poseArm(arm, wheel, shoulderHome, armAngle, canCross)
		end
	end)
end

-- What the arms are currently built for, so a change of arm size can rebuild
-- them in place. Nil whenever the player is not driving.
local currentCar = nil
local currentCharacter = nil

local function onSeated(character, isSeated, seatPart)
	currentCar, currentCharacter = nil, nil
	if not isSeated or not seatPart then
		removeArms()
		return
	end

	local carModel = seatPart.Parent
	if not carModel or VehicleSeats.GetDriverSeat(carModel) ~= seatPart then
		removeArms()
		return
	end

	currentCar, currentCharacter = carModel, character
	attachArms(carModel, character)
end

-- Size is baked into the rig when it is built, so a new size means a new rig.
-- That is also what makes the slider live: drag it with the menu open while
-- sitting in the cab and the arms behind it change as it moves. ("Show arms"
-- needs nothing here - the visibility check reads it every frame.)
GameSettings.OnChanged(function(key)
	if key == ARM_SIZE_SETTING and currentArms and currentCar and currentCharacter then
		attachArms(currentCar, currentCharacter)
	end
end)

local function bindCharacter(character)
	local humanoid = character:WaitForChild("Humanoid")
	humanoid.Seated:Connect(function(isSeated, seatPart)
		onSeated(character, isSeated, seatPart)
	end)
	humanoid.Died:Connect(removeArms)
end

if player.Character then
	bindCharacter(player.Character)
end
player.CharacterAdded:Connect(bindCharacter)



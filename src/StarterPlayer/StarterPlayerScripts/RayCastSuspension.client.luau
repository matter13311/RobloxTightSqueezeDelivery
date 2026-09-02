local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local Gearbox = require(ReplicatedStorage.Modules.Vehicles.Gearbox)
local VehicleDashboard = require(script.Parent.VehicleDashboard)

local player = Players.LocalPlayer

-- Name of the Attachment (or Part) that marks where the driver is put down
-- when they press F. Put one on the Chassis, at GROUND level just outside the
-- driver's door - the character's standing height is added on top of it here,
-- so you're placing their feet, not their torso. Missing one isn't fatal:
-- exitCFrame below falls back to dropping them beside the car instead.
local EXIT_MARKER_NAME = "DriverExit"

local HANDBRAKE_ACTION = "VehicleHandbrake"
local EXIT_ACTION = "VehicleExit"

-- Per-vehicle state for the wheel VISUALS only (every client tracks this for
-- every car it can see, not just the one it's driving - see UpdateWheelVisuals).
local wheelAttachmentsCache = {} -- [vehicle] = attachments
local wheelRotationState = {} -- [vehicle] = { FL = angle, ... }
local drivingStates = {} -- [vehicle] = physics State, only set while THIS client is driving it

-- The one car this client is driving right now, or nil. Everything the input
-- bindings need to touch hangs off here, so a binding never has to care which
-- car it belongs to - it's always this one, and it's unbound the moment the
-- player gets out.
local session = nil

-- Returns nil (instead of erroring) if this car hasn't finished loading yet -
-- e.g. PrimaryPart or a WheelXX attachment not set up yet during the first
-- few frames after it's added to workspace.Vehicles. Callers should just
-- skip the vehicle for this frame and it'll pick up again once it's ready.
local function getWheelAttachments(vehicle)
	local cached = wheelAttachmentsCache[vehicle]
	if cached then
		return cached
	end

	local chassis = vehicle.PrimaryPart
	if not chassis then
		return nil
	end

	local ok, attachments = pcall(VehiclePhysics.GetWheelAttachments, chassis)
	if not ok then
		return nil
	end

	wheelAttachmentsCache[vehicle] = attachments
	return attachments
end

-- Sounds are created here on the client rather than pre-placed in the model,
-- so adding a new car needs no audio setup at all. The tradeoff is that they
-- only play for the driver - if these should be audible to bystanders too,
-- they'd need to be server-created (or fired over a RemoteEvent) instead.
local function createSound(parent, name, soundId, volume)
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = soundId
	sound.Volume = volume
	sound.RollOffMaxDistance = 150
	sound.Parent = parent
	return sound
end

local function playSound(sound)
	if sound then
		-- TimePosition reset rather than a plain Play(): shifts can come fast
		-- enough (and the selector can be spammed) that an already-playing
		-- sound would otherwise swallow the next one entirely.
		sound.TimePosition = 0
		sound:Play()
	end
end

-- Where the driver ends up after pressing F. `chassis` is used for the
-- fallback and for facing, `marker` is the DriverExit Attachment/Part if the
-- car has one.
local function exitCFrame(carModel, chassis, humanoid, rootPart)
	local marker = carModel:FindFirstChild(EXIT_MARKER_NAME, true)

	local footPosition
	if marker and marker:IsA("Attachment") then
		footPosition = marker.WorldPosition
	elseif marker and marker:IsA("BasePart") then
		footPosition = marker.Position
	else
		-- No marker set up: step out to the car's left, far enough clear of
		-- the body that the character doesn't spawn inside it.
		footPosition = (chassis.CFrame * CFrame.new(-(chassis.Size.X / 2 + 3), -(chassis.Size.Y / 2), 0)).Position
	end

	-- The marker marks the ground; a Humanoid stands with its root part a
	-- leg's length above that. HipHeight reports 0 on R6 rigs, so fall back to
	-- roughly where an R6 torso sits rather than burying them in the floor.
	local standHeight = humanoid.HipHeight + rootPart.Size.Y / 2
	if standHeight < 1 then
		standHeight = 3
	end

	local standPosition = footPosition + Vector3.new(0, standHeight, 0)

	-- Face away from the car, so you step out looking where you're going
	-- rather than straight into the door you just came through. Taken from the
	-- marker's offset rather than any orientation you'd have to set in Studio.
	local outward = standPosition - chassis.Position
	outward = Vector3.new(outward.X, 0, outward.Z)
	if outward.Magnitude < 0.1 then
		outward = -chassis.CFrame.RightVector
	end

	return CFrame.lookAt(standPosition, standPosition + outward.Unit)
end

local function tryExitVehicle()
	if not session then
		return
	end

	local humanoid = session.Humanoid
	local character = humanoid.Parent
	local carModel = session.CarModel
	local chassis = session.Chassis
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	humanoid.Sit = false

	if not rootPart then
		return
	end

	task.spawn(function()
		-- The seat weld isn't gone yet on this frame - teleporting now just
		-- gets undone by it. One physics step later the character is free.
		RunService.Heartbeat:Wait()
		if humanoid.SeatPart then
			return -- didn't actually get out (something re-seated them)
		end
		character:PivotTo(exitCFrame(carModel, chassis, humanoid, rootPart))
		-- Otherwise you keep the car's momentum and get flung down the road.
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end)
end

local function bindDrivingControls()
	-- High priority + Sink is what stops Space from reaching the default
	-- character controls at all, so it never sets Humanoid.Jump and never
	-- pops the player out of the seat. Disabling the Jumping state in
	-- beginDrive covers the other routes into a jump (mobile button, gamepad).
	ContextActionService:BindActionAtPriority(HANDBRAKE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			if session and not session.Handbrake then
				session.Handbrake = true
				playSound(session.HandbrakeSound)
			end
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			if session then
				session.Handbrake = false
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space)

	ContextActionService:BindAction(EXIT_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			tryExitVehicle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.F)
end

local function unbindDrivingControls()
	for _, action in { HANDBRAKE_ACTION, EXIT_ACTION } do
		ContextActionService:UnbindAction(action)
	end
end

-- `expected` guards against a stale drive loop tearing down the session that
-- REPLACED it. Swapping seats fires Seated(false) then Seated(true), so a new
-- session can already be live by the time the old loop notices its own seat
-- is empty and unwinds - and an unguarded teardown there would strip the
-- bindings and HUD off a car the player is now sitting in. Called with no
-- argument (the Seated/Died handlers) it means "whatever is current".
local function endDrive(expected)
	if not session or (expected and session ~= expected) then
		return
	end

	unbindDrivingControls()
	session.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	session.Dashboard:Destroy()
	if session.ShiftSound then
		session.ShiftSound:Destroy()
	end
	if session.SelectorSound then
		session.SelectorSound:Destroy()
	end
	if session.HandbrakeSound then
		session.HandbrakeSound:Destroy()
	end

	if drivingStates[session.CarModel] == session.State then
		drivingStates[session.CarModel] = nil
	end
	session = nil
end

local function beginDrive(humanoid, seatPart)
	local carModel = seatPart.Parent
	local chassis = carModel.PrimaryPart
	local attachments = getWheelAttachments(carModel)
	if not attachments then
		warn("RayCastSuspension: " .. carModel:GetFullName() .. " isn't fully set up (missing PrimaryPart or a WheelXX attachment) - can't drive it")
		return
	end

	-- Defensive: normally Seated(false) has already torn the previous session
	-- down, but never run two drive loops at once if it somehow hasn't.
	endDrive()

	local config = VehiclePhysics.GetConfig(chassis)
	local state = VehiclePhysics.NewState()
	drivingStates[carModel] = state

	session = {
		Humanoid = humanoid,
		CarModel = carModel,
		Chassis = chassis,
		Config = config,
		State = state,
		Gearbox = Gearbox.new(config),
		Dashboard = VehicleDashboard.new(player),
		Handbrake = false,
		DriveThrottle = 0,

		ShiftSound = createSound(chassis, "GearShiftSound", config.GearShiftSoundId, config.ShiftSoundVolume),
		SelectorSound = createSound(chassis, "GearSelectorSound", config.SelectorSoundId, config.SelectorSoundVolume),
		HandbrakeSound = createSound(chassis, "HandbrakeSound", config.HandbrakeSoundId, config.HandbrakeSoundVolume),
	}

	-- Space is the handbrake now, so jumping out of the seat has to go away
	-- entirely - not just the keybind, since the seat pops you out on the
	-- Jumping state itself however it was triggered.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	bindDrivingControls()

	local mySession = session

	-- No grace period needed here anymore - that was to give the server
	-- time to safely reclaim network ownership before resuming its own
	-- force application, a race that no longer exists now that a parked
	-- car is just Anchored (a plain replicated property, not something
	-- subject to network-ownership timing) instead of server-simulated.
	while seatPart.Occupant == humanoid and session == mySession do
		local delta = RunService.Heartbeat:Wait()

		-- The condition above was true when the frame STARTED; this yield is
		-- where the session can end underneath us. Pressing F sets
		-- Humanoid.Sit = false, which fires Seated(false) -> endDrive() while
		-- we're parked here, so by the time we resume `session` is nil and
		-- every session.X below would throw. Re-check before touching it.
		if session ~= mySession then
			break
		end

		-- Raw key state, nothing more. What W and S actually DO is the
		-- gearbox's decision, because it depends on which way the car is
		-- currently pointed - in D, S is the brake; in R, S is the gas.
		local throttleFloat = seatPart.ThrottleFloat
		local forwardKey = throttleFloat > 0.1
		local backKey = throttleFloat < -0.1

		-- SIGNED speed along the car, not magnitude. The gearbox needs to
		-- know whether the car is still rolling forwards to decide whether S
		-- means "keep braking" or "now go backwards", and it must be measured
		-- along the car's own axis - sliding sideways with the handbrake up
		-- isn't road speed, and on magnitude the box would happily upshift
		-- through a skid and the speedo would read the slide.
		local signedSpeed = chassis.CFrame.LookVector:Dot(chassis.AssemblyLinearVelocity)
		local speed = math.abs(signedSpeed)

		local drive = Gearbox.Update(mySession.Gearbox, config, delta, signedSpeed, forwardKey, backKey)
		if mySession.Gearbox.ShiftedThisFrame then
			playSound(mySession.ShiftSound)
		end
		if mySession.Gearbox.DirectionChangedThisFrame then
			-- Swapping between forwards and backwards is the closest thing
			-- left to a lever movement, so it keeps the louder, more
			-- mechanical sound rather than the quiet automatic-shift one.
			playSound(mySession.SelectorSound)
		end
		-- Handed to the wheel-visual render step, which runs on its own clock
		-- and has no other way to know what the gearbox decided this frame.
		mySession.DriveThrottle = drive.Throttle

		VehiclePhysics.Step(carModel, attachments, config, state, delta, {
			Throttle = drive.Throttle,
			Steer = seatPart.SteerFloat,
			Brake = drive.Brake,
			Handbrake = mySession.Handbrake,
			TorqueMultiplier = drive.TorqueMultiplier,
			GearMaxSpeed = drive.GearMaxSpeed,
			Rpm = drive.Rpm,
		})

		mySession.Dashboard:Update(mySession.Gearbox, speed, mySession.Handbrake)
	end

	endDrive(mySession)
end

local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")

	humanoid.Seated:Connect(function(seated, seatPart)
		if not (seated and seatPart) then
			-- Covers getting out by any route other than F (the seat being
			-- destroyed, a script unseating you, dying) - the drive loop below
			-- also exits on its own, but the bindings and HUD have to come
			-- down even if it was already unwound.
			endDrive()
			return
		end
		if not (seatPart:FindFirstAncestor("Vehicles") and seatPart:IsA("VehicleSeat")) then
			return
		end

		beginDrive(humanoid, seatPart)
	end)

	humanoid.Died:Connect(function()
		endDrive()
	end)

	-- Headlights placeholder, kept from before the gearbox work: bound for the
	-- whole character rather than per drive session, and does nothing until
	-- the SwitchLight remote actually exists.
	ContextActionService:BindAction("lightButton", function(_, inputState)
		if humanoid.SeatPart and inputState == Enum.UserInputState.Begin then
			-- game.ReplicatedStorage.SwitchLight:FireServer()
		end
	end, false, Enum.KeyCode.L)
end

-- Wheel visuals for every car in view, not just the one being driven, so this
-- is bound once for the client rather than per character spawn.
RunService:BindToRenderStep("MoveWheels", 5, function()
	for _, vehicle in workspace.Vehicles:GetChildren() do
		local attachments = getWheelAttachments(vehicle)
		local chassis = attachments and vehicle.PrimaryPart
		-- Parked cars are Anchored and don't need their wheels touched at
		-- all - skip them outright rather than relying on velocity happening
		-- to read exactly zero every frame, which is a guarantee, not a hope.
		if attachments and not chassis.Anchored then
			local config = VehiclePhysics.GetConfig(chassis)

			wheelRotationState[vehicle] = wheelRotationState[vehicle] or {}

			-- Only the car THIS client is currently driving has a real smoothed
			-- steer value (from the physics loop above) - other cars' front
			-- wheels stay centered visually, since we don't get their driver's
			-- steer input replicated to us. Same story for throttle (used for
			-- the wheelspin visual) and the handbrake (used to stop locked
			-- wheels turning): only known for the car we're driving.
			local drivingState = drivingStates[vehicle]
			local smoothSteer = drivingState and drivingState.SmoothSteer or 0
			local throttle = 0
			local handbrake = false
			if session and session.CarModel == vehicle then
				-- The GEAR's drive demand, not the raw seat axis. S is the
				-- brake now, so feeding ThrottleFloat straight in here would
				-- spin the wheels backwards every time you slowed down.
				throttle = session.DriveThrottle
				handbrake = session.Handbrake
			end

			VehiclePhysics.UpdateWheelVisuals(vehicle, attachments, config, smoothSteer, wheelRotationState[vehicle], throttle, handbrake)
		end
	end
end)

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

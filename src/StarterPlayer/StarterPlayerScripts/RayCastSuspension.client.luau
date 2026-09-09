local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local Gearbox = require(ReplicatedStorage.Modules.Vehicles.Gearbox)
local VehicleDashboard = require(script.Parent.VehicleDashboard)
local VehicleControlsHint = require(script.Parent.VehicleControlsHint)
local VehicleEffects = require(script.Parent.VehicleEffects)
local ExhaustEffects = require(script.Parent.ExhaustEffects)
local VehicleLights = require(script.Parent.VehicleLights)
local VehicleDashboardGauges = require(script.Parent.VehicleDashboardGauges)
local VehicleControls = require(script.Parent.VehicleControls)
local VehicleMirrorViews = require(script.Parent.VehicleMirrorViews)
local VehicleZoom = require(script.Parent.VehicleZoom)
local VehicleViewMode = require(script.Parent.VehicleViewMode)
local VehicleThirdPersonShop = require(script.Parent.VehicleThirdPersonShop)
local VehicleTouchControls = require(script.Parent.VehicleTouchControls)
-- Temporary instrumentation; see the module header. Remove with the rest of it.
local VehicleEntryDebug = require(ReplicatedStorage.Modules.Vehicles.VehicleEntryDebug)
local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)

local player = Players.LocalPlayer

-- Braking/reversing/burnout state is only known to the client actually
-- driving a car - a bystander can't derive it from replicated velocity the
-- way cornering slip can (see VehicleEffects.luau). This RemoteEvent is how
-- the driving client tells the server, which stamps it onto the vehicle as
-- Attributes for everyone else to read straight off - see
-- VehicleNetworkState.server.luau.
local vehicleNetworkState = ReplicatedStorage:WaitForChild("VehicleNetworkState")

-- Pressing F to get out no longer unseats immediately - it asks
-- VehicleDoors.server.luau to pick the exit and play the door cue, which fires this
-- back once it's open. Only then does the actual unseat + step-out below
-- run, so you never see the character walk through a closed door.
local exitVehicleRemote = ReplicatedStorage:WaitForChild("ExitVehicle")

-- How much the ramped throttle has to move before it's worth another
-- RemoteEvent - without this, DriveThrottle's continuous ramp would fire one
-- every single frame the whole time the pedal is moving.
local NET_THROTTLE_EPSILON = 0.05
local NET_RPM_EPSILON = 0.03
-- Steering ramps continuously too (config.SteerSpeed), so it needs the same
-- treatment. Sized against what it's actually FOR: a bystander measures tire
-- slip in the wheel's own steered frame, and an error of e in steer shows up
-- as a phantom sideways velocity of speed * sin(e * steerAngle) - at 0.05 of
-- full lock that's around 1 stud/s at speed, well under the several studs/s
-- TractionSlipThreshold wants to see before it calls a tire slipping.
local NET_STEER_EPSILON = 0.05

local HANDBRAKE_ACTION = "VehicleHandbrake"
local EXIT_ACTION = "VehicleExit"
local STEER_ACTION = "VehicleSteer"
local HEADLIGHT_ACTION = "VehicleHeadlights"
local TURN_SIGNAL_LEFT_ACTION = "VehicleTurnSignalLeft"
local TURN_SIGNAL_RIGHT_ACTION = "VehicleTurnSignalRight"
local HORN_ACTION = "VehicleHorn"
local THIRD_PERSON_SHOP_ACTION = "VehicleThirdPersonShop"

-- Which way A/D are being held right now, read straight off the keys instead
-- of off VehicleSeat.SteerFloat. The seat derives its axes from
-- Humanoid.MoveDirection, which is a UNIT vector: holding W and D together
-- gives it (0.707, 0, -0.707), so SteerFloat drops from 1 to 0.707 the moment
-- you touch the gas and the wheels visibly unwind ~30% of their lock. Keys are
-- digital, so this doesn't happen here. Gamepad/touch steering is genuinely
-- analog and still comes from the seat (see steerInput).
local steerLeftHeld = false
local steerRightHeld = false

-- Dedicated GAS/BRAKE buttons for touch (VehicleTouchControls), read the same
-- way steerLeftHeld/steerRightHeld are: an explicit override that wins over
-- whatever the seat's own ThrottleFloat says, rather than something that has
-- to fight it. Without this, a touch player's only throttle input is Roblox's
-- default vehicle joystick, which is not what the two clearly-labelled pedals
-- on screen are supposed to be driving - see throttleInput below.
local mobileGasHeld = false
local mobileBrakeHeld = false

-- Whether the player's last input was touch, tracked live the same way
-- VehicleTouchControls/CustomPrompt do - a hybrid touchscreen device can
-- switch between mouse and touch mid-drive. This decides whether the seat's
-- own ThrottleFloat is even trusted as a throttle FALLBACK (see
-- throttleInput): Roblox's default touch vehicle control is a single wheel
-- that blends steer and throttle into one drag, and now that GAS/BRAKE are
-- dedicated buttons, that blend is worse than nothing - a player trying to
-- only steer would otherwise still nudge the throttle every time they turn.
local touchInputActive = UserInputService:GetLastInputType() == Enum.UserInputType.Touch
UserInputService.LastInputTypeChanged:Connect(function(inputType)
	touchInputActive = inputType == Enum.UserInputType.Touch
end)

-- Whether H is currently down. Tracked (rather than just fired and
-- forgotten) so unbindDrivingControls below can send the matching release for
-- a horn that's still held when the drive ends - see the comment there.
local hornHeld = false

-- Per-vehicle state for the wheel VISUALS only (every client tracks this for
-- every car it can see, not just the one it's driving - see UpdateWheelVisuals).
local wheelAttachmentsCache = {} -- [vehicle] = attachments
local wheelRotationState = {} -- [vehicle] = { FL = angle, ... }
local wheelSlipState = {} -- [vehicle] = { FL = slip studs/s, ... }, reused each frame so the render step allocates nothing
local drivingStates = {} -- [vehicle] = physics State, only set while THIS client is driving it

-- How many frames a newly-parked car keeps having its wheels re-posed before
-- the render step goes back to leaving parked cars alone entirely. Has to
-- outlast the server's EXIT_SETTLE_FRAMES re-assert window (Raycast.server.luau)
-- plus the replication of it, or the last pose written here would be one taken
-- while the chassis was still being pulled into place.
local PARKED_POSE_FRAMES = 15
-- [vehicle] = frames of parked posing still owed. nil means "not posed since
-- it last parked", 0 means done - see the Anchored branch in MoveWheels.
local parkedPoseFrames = {}

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

-- Fires only when something a bystander would actually see has changed,
-- rather than every frame - booleans are compared exactly, Throttle against
-- NET_THROTTLE_EPSILON since it ramps continuously while accelerating.
local function sendNetworkStateIfChanged(mySession, carModel)
	local sent = mySession.NetSent
	local changed = sent.Braking ~= mySession.Braking
		or sent.Reversing ~= mySession.Reversing
		or sent.Burnout ~= mySession.Burnout
		or sent.Handbrake ~= mySession.Handbrake
		or math.abs(sent.Throttle - mySession.DriveThrottle) >= NET_THROTTLE_EPSILON
		or math.abs(sent.Rpm - mySession.DriveRpm) >= NET_RPM_EPSILON
		or math.abs(sent.Steer - mySession.NetSteerValue) >= NET_STEER_EPSILON
	if not changed then
		return
	end

	sent.Braking = mySession.Braking
	sent.Reversing = mySession.Reversing
	sent.Burnout = mySession.Burnout
	sent.Handbrake = mySession.Handbrake
	sent.Throttle = mySession.DriveThrottle
	sent.Rpm = mySession.DriveRpm
	sent.Steer = mySession.NetSteerValue

	vehicleNetworkState:FireServer(
		carModel,
		sent.Braking,
		sent.Reversing,
		sent.Burnout,
		sent.Handbrake,
		sent.Throttle,
		sent.Rpm,
		sent.Steer
	)
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

-- Where the driver/passenger ends up after pressing F. `chassis` is used for
-- the fallback and for facing, `marker` is whichever Exit# Attachment (or
-- Part) VehicleDoors.server.luau picked - see VehicleExits.ChooseExit - or
-- nil if the car has none set up.
local function exitCFrame(carModel, chassis, humanoid, rootPart, marker)
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

-- The actual unseat + step-out, run only once the server confirms the door
-- is open (see exitVehicleRemote.OnClientEvent below). `mySession` is
-- captured at request time so a session that's already ended (or been
-- replaced) by the time the door finishes opening doesn't get acted on.
local function performExit(mySession, exitMarker)
	if session ~= mySession then
		return
	end

	local humanoid = mySession.Humanoid
	local character = humanoid.Parent
	local carModel = mySession.CarModel
	local chassis = mySession.Chassis
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
		character:PivotTo(exitCFrame(carModel, chassis, humanoid, rootPart, exitMarker))
		-- Otherwise you keep the car's momentum and get flung down the road.
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero
	end)
end

-- Requests the exit - doesn't unseat anything itself. ExitRequested guards
-- against spamming F while the door is still swinging open.
local EXIT_REQUEST_TIMEOUT = 5 -- seconds - if the server never answers (dropped request, error on its end), let F work again rather than locking the player out for the rest of the drive
local function tryExitVehicle()
	if not session or session.ExitRequested then
		return
	end
	session.ExitRequested = true
	local mySession = session
	exitVehicleRemote:FireServer()

	task.delay(EXIT_REQUEST_TIMEOUT, function()
		if session == mySession and session.ExitRequested then
			session.ExitRequested = false
		end
	end)
end

exitVehicleRemote.OnClientEvent:Connect(function(exitMarker)
	if session then
		performExit(session, exitMarker)
	end
end)

-- Full lock is full lock whether or not you're also on the gas. On a keyboard
-- that means reading A/D directly, because the seat's own SteerFloat is a
-- component of a normalised move vector and shrinks to 0.707 as soon as W is
-- added. Nothing held on the keyboard falls back to the seat, which is what
-- keeps gamepad thumbsticks and the mobile steering slider analog.
local function steerInput(seatPart)
	local keyboardSteer = (if steerRightHeld then 1 else 0) - (if steerLeftHeld then 1 else 0)
	if keyboardSteer ~= 0 then
		return keyboardSteer
	end
	return seatPart.SteerFloat
end

-- Same idea as steerInput, for the mobile GAS/BRAKE buttons. Only overrides
-- the seat when one of the two is actually held, so keyboard W/S and gamepad
-- throttle keep working exactly as before for anyone not using the dedicated
-- buttons. Both held at once cancels out rather than picking a winner, same
-- as a real car's pedals would.
--
-- On touch, the seat's ThrottleFloat is never trusted as a fallback even when
-- neither button is held - see touchInputActive above. The default touch
-- wheel still drives SteerFloat (steerInput falls back to it exactly as
-- before), it just no longer gets a say in the throttle: that job now belongs
-- entirely to GAS/BRAKE.
local function throttleInput(seatPart)
	if mobileGasHeld and not mobileBrakeHeld then
		return 1
	elseif mobileBrakeHeld and not mobileGasHeld then
		return -1
	elseif mobileGasHeld and mobileBrakeHeld then
		return 0
	end
	if touchInputActive then
		return 0
	end
	return seatPart.ThrottleFloat
end

-- The driving actions themselves, pulled out of the ContextActionService
-- callbacks below so the on-screen touch buttons (VehicleTouchControls) can
-- call the exact same code a keyboard press does - one activation path per
-- action, no separate "mobile version" that could drift out of sync.

local function setHandbrake(active)
	if not session then
		return
	end
	if active and not session.Handbrake then
		session.Handbrake = true
		playSound(session.HandbrakeSound)
	elseif not active and session.Handbrake then
		session.Handbrake = false
	end
end

-- These two just flip the override throttleInput reads - no session needed,
-- since there's nothing to do to the car itself until next frame's Step call
-- picks the new value up.
local function setGas(active)
	mobileGasHeld = active
end

local function setBrake(active)
	mobileBrakeHeld = active
end

local function toggleHeadlights()
	if session then
		VehicleControls.ToggleHeadlights(session.CarModel)
	end
end

local function toggleTurnSignal(side)
	if session then
		VehicleControls.ToggleTurnSignal(session.CarModel, side)
	end
end

local function setHorn(active)
	if not session then
		return
	end
	if active and not hornHeld then
		hornHeld = true
		VehicleControls.SetHorn(session.CarModel, true)
	elseif not active and hornHeld then
		hornHeld = false
		VehicleControls.SetHorn(session.CarModel, false)
	end
end

-- Only worth doing anything for a player who doesn't already have the
-- third-person perk - there is nothing here to open for one who does.
local function toggleThirdPersonShop()
	if not VehicleViewMode.HasThirdPersonAccess() then
		VehicleThirdPersonShop.Toggle()
	end
end

local function bindDrivingControls()
	-- High priority + Sink is what stops Space from reaching the default
	-- character controls at all, so it never sets Humanoid.Jump and never
	-- pops the player out of the seat. Disabling the Jumping state in
	-- beginDrive covers the other routes into a jump (mobile button, gamepad).
	ContextActionService:BindActionAtPriority(HANDBRAKE_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			setHandbrake(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			setHandbrake(false)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space)

	-- Passes the keys through rather than sinking them: the seat still sees
	-- them (it's what turns the character to face the car's heading and what
	-- other clients replicate), we just don't trust its steer axis.
	ContextActionService:BindAction(STEER_ACTION, function(_, inputState, inputObject)
		local key = inputObject.KeyCode
		local held = inputState == Enum.UserInputState.Begin
		if key == Enum.KeyCode.A or key == Enum.KeyCode.Left then
			steerLeftHeld = held
		elseif key == Enum.KeyCode.D or key == Enum.KeyCode.Right then
			steerRightHeld = held
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.A, Enum.KeyCode.D, Enum.KeyCode.Left, Enum.KeyCode.Right)

	ContextActionService:BindAction(EXIT_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			tryExitVehicle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.F)

	ContextActionService:BindAction(HEADLIGHT_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			toggleHeadlights()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.L)

	ContextActionService:BindAction(TURN_SIGNAL_LEFT_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			toggleTurnSignal("Left")
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q)

	ContextActionService:BindAction(TURN_SIGNAL_RIGHT_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			toggleTurnSignal("Right")
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.E)

	-- The one control here that's held rather than toggled, so it sends on
	-- both Begin and End. Cancel is folded in with End on purpose: the action
	-- being cancelled (the window losing focus, another binding taking the
	-- key) is precisely the case where no key-up is ever coming, and letting
	-- that leave the horn on would strand it until the server's timeout.
	ContextActionService:BindAction(HORN_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			setHorn(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			setHorn(false)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.H)

	ContextActionService:BindAction(THIRD_PERSON_SHOP_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			toggleThirdPersonShop()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.T)
end

local function unbindDrivingControls()
	-- Released BEFORE the bindings go away, because getting out (or dying) is
	-- exactly the path where the horn is still held down and no key-up will
	-- ever be delivered. The server would cut it at MAX_HORN_SECONDS anyway,
	-- but that's ten seconds of a driverless car blaring at everyone.
	if hornHeld then
		hornHeld = false
		if session then
			VehicleControls.SetHorn(session.CarModel, false)
		end
	end

	for _, action in {
		HANDBRAKE_ACTION,
		EXIT_ACTION,
		STEER_ACTION,
		HEADLIGHT_ACTION,
		TURN_SIGNAL_LEFT_ACTION,
		TURN_SIGNAL_RIGHT_ACTION,
		HORN_ACTION,
		THIRD_PERSON_SHOP_ACTION,
	} do
		ContextActionService:UnbindAction(action)
	end
	steerLeftHeld = false
	steerRightHeld = false
	-- A finger still down on GAS/BRAKE when the drive ends (exiting mid-press)
	-- would otherwise leak into whatever this player sits in next.
	mobileGasHeld = false
	mobileBrakeHeld = false
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
	VehicleMirrorViews.Stop()
	VehicleZoom.Stop()
	VehicleThirdPersonShop.Close()
	VehicleViewMode.ReleaseCameraMode()
	session.Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	session.Dashboard:Destroy()
	session.ControlsHint:Destroy()
	session.TouchControls:Destroy()
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
		ControlsHint = VehicleControlsHint.new(player),
		TouchControls = VehicleTouchControls.new(player, {
			OnExit = tryExitVehicle,
			OnGasChanged = setGas,
				OnBrakeChanged = setBrake,
				OnHandbrakeChanged = setHandbrake,
			OnHeadlightsToggle = toggleHeadlights,
			OnTurnSignal = toggleTurnSignal,
			OnHornChanged = setHorn,
			OnThirdPersonShop = toggleThirdPersonShop,
			ShowThirdPersonButton = not VehicleViewMode.HasThirdPersonAccess(),
		}),
		Handbrake = false,
		DriveThrottle = 0,
		DriveRpm = config.Transmission.IdleRpm,
		Burnout = false,
		Braking = false,
		Reversing = false,
		ExitRequested = false,
		-- Set the first frame this client actually simulates the car; see the
		-- handover note in the drive loop below.
		TookOver = false,
		-- Mirror of the physics state's smoothed steer, refreshed each drive
		-- frame purely so the network payload can be assembled from one table.
		NetSteerValue = 0,
		-- Last state actually sent over the network - starts at sentinel
		-- values so the very first frame always sends, even though 0/false
		-- match Throttle/Handbrake's own initial values above.
		NetSent = {
			Braking = false,
			Reversing = false,
			Burnout = false,
			Handbrake = false,
			Throttle = -math.huge,
			Rpm = -math.huge,
			Steer = -math.huge,
		},

		ShiftSound = createSound(chassis, "GearShiftSound", config.GearShiftSoundId, config.ShiftSoundVolume),
		SelectorSound = createSound(chassis, "GearSelectorSound", config.SelectorSoundId, config.SelectorSoundVolume),
		HandbrakeSound = createSound(chassis, "HandbrakeSound", config.HandbrakeSoundId, config.HandbrakeSoundVolume),
	}

	-- Space is the handbrake now, so jumping out of the seat has to go away
	-- entirely - not just the keybind, since the seat pops you out on the
	-- Jumping state itself however it was triggered.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	bindDrivingControls()

	-- Live mirrors exist ONLY for the car this client is driving, and only on
	-- this client - so they are built here and torn down in endDrive rather
	-- than living with the model. A bystander (or a driver of a different car)
	-- never pays for them. See VehicleMirrorViews.
	VehicleMirrorViews.Start(carModel, config)
	-- Hold right mouse to zoom in - mainly so the far door mirror is
	-- readable. Session-scoped like the mirrors, so it cannot fire on foot.
	VehicleZoom.Start()

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

		-- The server hands network ownership over a few frames after the
		-- seat is taken (see Raycast.server.luau), and until it has, this
		-- client's impulses land on a body the server is still holding in
		-- place - they achieve nothing except a fight whose result the
		-- client then inherits as its opening state. Sit those frames out.
		-- The attribute is absent on a car saved before this existed, so
		-- treat a missing value as ready rather than never driving it.
		if carModel:GetAttribute("DriveReady") == false then
			continue
		end

		-- FIRST frame this client is both allowed and able to simulate.
		--
		-- Ownership arrives one frame before the suspension does, and in that
		-- gap the chassis is a bare rigid body: unanchored, client-owned, and
		-- with nothing holding it up. Roblox integrates a full frame of
		-- gravity into it before this loop ever gets to push back. At 60fps
		-- that is 3.3 studs/s and invisible. At 20fps it is 11.4 studs/s, and
		-- a 20fps capture shows exactly what that does next: the springs
		-- absorb the fall (bottoming out at 0.55 of 3 studs of travel), store
		-- the energy, and throw the car straight back up - one enormous bounce
		-- with a peak suspension impulse of 19.7 studs/s against an
		-- ImpactMinDeltaV of 12. That bounce is the "car jumps around
		-- violently on entry" symptom, and it is NOT an instability - it is a
		-- correct spring response to a drop that should never have happened.
		--
		-- The car was parked and stationary a frame ago (parked cars are
		-- Anchored), so any velocity it has right now is handover artifact and
		-- nothing else. Dropping it is not cheating physics; it is declining
		-- to inherit a frame of freefall that the player did not cause.
		--
		-- Deliberately only the first frame. A hitch LATER in a drive is a
		-- real car really falling, and cancelling that would be wrong.
		if not mySession.TookOver then
			mySession.TookOver = true
			VehicleEntryDebug.Note(
				"TAKEOVER - discarding handover velocity %.2f studs/s (angular %.2f)",
				chassis.AssemblyLinearVelocity.Magnitude,
				chassis.AssemblyAngularVelocity.Magnitude
			)
			-- Booked as a deliberate change before it is made, or the crash
			-- detector reads cancelling the drop as a crash in its own right.
			VehiclePhysics.NoteNonCollisionDeltaV(carModel, -chassis.AssemblyLinearVelocity)
			chassis.AssemblyLinearVelocity = Vector3.zero
			chassis.AssemblyAngularVelocity = Vector3.zero
		end

		-- Crates are still going on the back. The truck is held still for the
		-- few seconds that takes, so the player watches (and hears, and feels
		-- through the springs) the load arrive instead of pulling away
		-- half-loaded and never noticing it happened.
		--
		-- Done by taking the pedals away and pulling the handbrake rather than
		-- by anchoring the chassis: the truck is still a live physics body, so
		-- it still dips on its suspension as each crate lands - which is the
		-- entire point of loading them one at a time. Anchoring would freeze
		-- exactly the motion we are trying to show.
		--
		-- Not a security boundary, and does not need to be. The server has
		-- already committed the load and taken the contract; a client that
		-- ignored this would just drive off and have its crates appear around
		-- it on schedule. This is feel, not enforcement.
		local cargoLoading = CargoLoad.IsLoading(carModel)

		-- Raw key state, nothing more. What W and S actually DO is the
		-- gearbox's decision, because it depends on which way the car is
		-- currently pointed - in D, S is the brake; in R, S is the gas.
		local throttleFloat = if cargoLoading then 0 else throttleInput(seatPart)
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
		mySession.DriveRpm = drive.Rpm

		-- Handbrake plus gas, while barely moving: the wheels are turning and
		-- the car isn't. Nothing in the physics tracks wheel rotation apart
		-- from road speed, so there's no slip velocity to measure here - the
		-- driver's client just declares it, and only for its own car.
		mySession.Burnout = mySession.Handbrake
			and drive.Throttle ~= 0
			and speed < config.TractionMinCarSpeed

		-- Selector == "R" rather than Throttle < 0, so the reverse light is on
		-- for the whole time the car is in reverse gear - including sitting
		-- still with no gas held - the same as a real reverse light.
		mySession.Braking = drive.Brake > 0
		mySession.Reversing = mySession.Gearbox.Selector == "R"
		-- Last frame's smoothed steer (Step below is what advances it). One
		-- frame stale is nothing next to the network trip it's about to take,
		-- and reading it here keeps the whole network payload assembled in
		-- one place.
		mySession.NetSteerValue = state.SmoothSteer
		sendNetworkStateIfChanged(mySession, carModel)

		VehiclePhysics.Step(carModel, attachments, config, state, delta, {
			Throttle = drive.Throttle,
			-- Steering is frozen along with the throttle, so the wheels are not
			-- being scrubbed sideways under a load that is still landing.
			Steer = if cargoLoading then 0 else steerInput(seatPart),
			Brake = drive.Brake,
			-- Held on for the duration of a load, but NOT written back into
			-- mySession.Handbrake: that field is the player's own switch
			-- position, and it drives the handbrake sound, the dashboard light
			-- and the burnout test. Overriding it here would sound the
			-- handbrake at every dock and leave it showing as engaged after
			-- the load finished.
			Handbrake = mySession.Handbrake or cargoLoading,
			TorqueMultiplier = drive.TorqueMultiplier,
			GearMaxSpeed = drive.GearMaxSpeed,
			Rpm = drive.Rpm,
		})

		-- Re-checked every frame rather than once on entry: a third-person
		-- perk can expire mid-drive and a player who has one can freely
		-- swap views, so neither the lock, the HUD, nor the countdown can
		-- be decided just once at the start of the session.
		mySession.Dashboard:Update(mySession.Gearbox, speed, mySession.Handbrake, VehicleViewMode.ThirdPersonSecondsRemaining())
		VehicleViewMode.EnforceCameraMode()
		local firstPerson = VehicleViewMode.IsFirstPerson()
		mySession.Dashboard:SetVisible(not firstPerson)
		mySession.ControlsHint:SetVisible(firstPerson)
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
		-- Name-checked, not just class-checked: a PassengerSeat is a
		-- VehicleSeat too, but only the DriverSeat should ever start the
		-- driving controls/HUD.
		if not (seatPart:FindFirstAncestor("Vehicles") and seatPart.Name == "DriverSeat") then
			return
		end

		beginDrive(humanoid, seatPart)
	end)

	humanoid.Died:Connect(function()
		endDrive()
	end)
end

-- Rotates the steering wheel prop in the cab to match the road wheels. The
-- weld and its untouched resting C0 are set up on the server (see
-- Raycast.server.luau) - all that happens here is spinning about the part's
-- own axis, so the prop keeps whatever position and tilt it was built with.
-- Axis resolution ("Auto" or an explicit Vector3) is shared with the
-- dashboard gauge needles - see VehiclePhysics.AxisFromConfig.
local function updateSteeringWheel(vehicle, config, smoothSteer)
	local part = VehiclePhysics.GetSteeringWheelPart(vehicle)
	if not part then
		return -- car simply doesn't have one, which is fine
	end
	local weld = part:FindFirstChild("SteeringWheelWeld")
	local baseC0 = weld and weld:GetAttribute("BaseC0")
	if not baseC0 then
		return -- server hasn't finished setting it up yet
	end

	-- Direction is SteeringWheelInvert's job alone, so a wheel that spins the
	-- wrong way is one boolean and never a reason to go back and re-guess the
	-- axis. Post-multiplying rotates about the part's own axes through its own
	-- centre, so the wheel spins in place and keeps the position and tilt it
	-- was built with.
	local direction = if config.SteeringWheelInvert then -1 else 1
	local angle = math.rad(smoothSteer * config.SteeringWheelMaxAngle * direction)
	weld.C0 = baseC0 * CFrame.fromAxisAngle(VehiclePhysics.AxisFromConfig(config.SteeringWheelAxis, part), angle)
end

-- Cars can be removed at runtime; their smoke emitters and screech loop are
-- client-created, so they have to be cleaned up here rather than going with
-- the model.
workspace.Vehicles.ChildRemoved:Connect(function(vehicle)
	VehicleEffects.Clear(vehicle)
	ExhaustEffects.Clear(vehicle)
	VehicleLights.Clear(vehicle)
	VehicleDashboardGauges.Clear(vehicle)
	wheelAttachmentsCache[vehicle] = nil
	wheelRotationState[vehicle] = nil
	wheelSlipState[vehicle] = nil
	drivingStates[vehicle] = nil
	parkedPoseFrames[vehicle] = nil
end)

-- Wheel visuals for every car in view, not just the one being driven, so this
-- is bound once for the client rather than per character spawn.
RunService:BindToRenderStep("MoveWheels", 5, function()
	for _, vehicle in workspace.Vehicles:GetChildren() do
		-- Headlights and turn signals are switch state, not driving
		-- telemetry - they react to their own Attribute-changed signals (see
		-- VehicleLights) and matter even for a parked, Anchored car (e.g. a
		-- driver left the headlights on when they got out), so this runs
		-- unconditionally rather than inside the Anchored check below.
		VehicleLights.EnsureHeadlights(vehicle)
		VehicleLights.EnsureTurnSignals(vehicle)
		VehicleDashboardGauges.EnsureGauges(vehicle)
		VehicleDashboardGauges.EnsureBlinkers(vehicle)

		local attachments = getWheelAttachments(vehicle)
		local chassis = attachments and vehicle.PrimaryPart
		-- Parked cars are Anchored and don't need their wheels touched at
		-- all - skip them outright rather than relying on velocity happening
		-- to read exactly zero every frame, which is a guarantee, not a hope.
		if attachments and chassis.Anchored then
			-- Parked (nobody driving): the block below never runs for this
			-- vehicle, so nothing else ever calls ExhaustEffects.Update again
			-- to shut it off - without this, smoke (and the last-set engine
			-- pitch) would freeze at whatever it was the instant the driver
			-- got out, instead of stopping.
			ExhaustEffects.Update(vehicle, 0)

			-- The wheels have exactly the same problem, and it is far more
			-- visible: the block below is what writes each wheel's weld C0
			-- from its suspension raycast, so skipping it outright freezes the
			-- wheels at whatever the LAST unanchored frame produced. That
			-- frame is the worst possible one to keep - it lands inside the
			-- exit handover (see Raycast.server.luau's Occupant handler),
			-- where the chassis is being snapped to its parked pose as network
			-- ownership moves back to the server. A ray cast mid-snap can
			-- easily miss the ground entirely, which clamps springLength to
			-- SuspensionMaxLength and leaves the struts hanging fully
			-- extended, driving the wheels down through the floor.
			--
			-- So pose them once more against the settled pose. Counted rather
			-- than done on the single first anchored frame, because that frame
			-- may itself still be mid-handover; the count outlasts the
			-- server's own re-assert window, and then stops. A car that has
			-- been parked for a while costs nothing, which is the whole reason
			-- this branch skips the work in the first place.
			local remaining = parkedPoseFrames[vehicle]
			if remaining == nil then
				remaining = PARKED_POSE_FRAMES
			end
			if remaining > 0 then
				parkedPoseFrames[vehicle] = remaining - 1
				wheelRotationState[vehicle] = wheelRotationState[vehicle] or {}
				VehiclePhysics.UpdateWheelVisuals(
					vehicle,
					attachments,
					VehiclePhysics.GetConfig(chassis),
					wheelRotationState[vehicle],
					-- A parked car is straight-wheeled and still. Deliberately
					-- no SlipOut: a stationary car generates no slip, and
					-- passing one would only invite the effects layer to read
					-- stale numbers from the last drive.
					{ SmoothSteer = 0, Throttle = 0, Handbrake = false, Burnout = false }
				)
			end
		elseif attachments then
			-- Unanchored again (someone got in): re-arm the pass, so the next
			-- park gets its own settle rather than reusing a spent count.
			parkedPoseFrames[vehicle] = nil
		end
		if attachments and not chassis.Anchored then
			local config = VehiclePhysics.GetConfig(chassis)

			wheelRotationState[vehicle] = wheelRotationState[vehicle] or {}

			-- Steer, like throttle/handbrake/burnout/braking/reversing, is
			-- replicated for other cars (see VehicleNetworkState) at lower
			-- fidelity than the driver's own frame-perfect value (see
			-- sendNetworkStateIfChanged). It has to be: tire slip is measured
			-- in the wheel's OWN steered frame (see UpdateWheelVisuals), so a
			-- bystander that assumed every other car's wheels were centred
			-- measured a perfectly gripping steered tire as sliding sideways
			-- at speed * sin(steer) and made an ordinary turn screech and
			-- smoke - for everyone except the driver, who alone had the real
			-- steer value and so alone saw the car behaving.
			wheelSlipState[vehicle] = wheelSlipState[vehicle] or {}

			local drivingState = drivingStates[vehicle]
			local smoothSteer = drivingState and drivingState.SmoothSteer
			local throttle = 0
			local handbrake = false
			local burnout = false
			local isBraking = false
			local isReversing = false
			local rpm = 0
			if session and session.CarModel == vehicle then
				-- The GEAR's drive demand, not the raw seat axis. S is the
				-- brake now, so feeding ThrottleFloat straight in here would
				-- spin the wheels backwards every time you slowed down.
				throttle = session.DriveThrottle
				handbrake = session.Handbrake
				burnout = session.Burnout
				isBraking = session.Braking
				isReversing = session.Reversing
				rpm = session.DriveRpm or 0
			else
				-- Someone else's car (or nobody's driving it) - including a
				-- car another player is driving while THIS client is also
				-- driving one of its own, since this loop runs over every
				-- vehicle in workspace.Vehicles regardless of the local
				-- player's own session. There's no local session to read for
				-- it, so fall back to whatever its driving client last
				-- reported over VehicleNetworkState. Defaults match a car
				-- nobody is driving - see the Occupant reset in
				-- Raycast.server.luau.
				throttle = vehicle:GetAttribute("NetThrottle") or 0
				handbrake = vehicle:GetAttribute("NetHandbrake") or false
				burnout = vehicle:GetAttribute("NetBurnout") or false
				isBraking = vehicle:GetAttribute("NetBraking") or false
				isReversing = vehicle:GetAttribute("NetReversing") or false
				rpm = vehicle:GetAttribute("NetRpm") or 0
			end
			-- Not folded into the session branch above: this client only has
			-- a live SmoothSteer for a car it is driving ITSELF, which is a
			-- narrower thing than having a session for it - hence the
			-- separate fallback to the replicated value.
			if smoothSteer == nil then
				smoothSteer = vehicle:GetAttribute("NetSteer") or 0
			end

			-- Purely local (never replicated - SetAttribute from a client
			-- never leaves it), so anything else on THIS client wanting the
			-- driver's own frame-perfect steer - e.g. ViewmodelArms scrubbing
			-- a grip animation - can read it with none of NetSteer's network
			-- round-trip lag, same reasoning as the comment above.
			vehicle:SetAttribute("LocalSmoothSteer", smoothSteer)

			VehiclePhysics.UpdateWheelVisuals(vehicle, attachments, config, wheelRotationState[vehicle], {
				SmoothSteer = smoothSteer,
				Throttle = throttle,
				Handbrake = handbrake,
				Burnout = burnout,
				SlipOut = wheelSlipState[vehicle],
			})
			VehicleEffects.Update(vehicle, config, wheelSlipState[vehicle])
			ExhaustEffects.Update(vehicle, rpm)
			-- Own car's Step() already set this from the live gearbox this
			-- frame; for every other car, `rpm` came from NetRpm above, so
			-- this is what makes a bystander hear an accelerating car's
			-- pitch actually rise instead of droning at a fixed note.
			VehiclePhysics.UpdateEngineSound(vehicle, config, rpm)
			VehicleLights.Update(vehicle, isBraking, isReversing)
			updateSteeringWheel(vehicle, config, smoothSteer)
			-- Speed comes straight off the chassis' own replicated velocity
			-- rather than the session/Net split above - see the module
			-- comment in VehicleDashboardGauges for why that's fine.
			VehicleDashboardGauges.UpdateGauges(vehicle, config, chassis.AssemblyLinearVelocity.Magnitude, rpm)
		end
	end
end)

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

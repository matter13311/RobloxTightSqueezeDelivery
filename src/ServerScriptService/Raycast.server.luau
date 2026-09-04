local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local wheelsFolder = ReplicatedStorage.Wheels
local defaultWheelModel = wheelsFolder.UAZWheelDetailed
local VehicleFolder = workspace.Vehicles

-- Same recursive lookup VehiclePhysics.Step uses to find the engine sound
-- (Engine/<enginePart>/Sound) - kept here too since starting/stopping it is
-- occupancy, not physics, and doesn't belong in the Step loop.
local function SetEngineSoundPlaying(carModel, playing)
	local sound = carModel:FindFirstChild("Sound", true)
	if not sound then
		return
	end
	if playing and not sound.IsPlaying then
		sound:Play()
	elseif not playing and sound.IsPlaying then
		sound:Stop()
	end
end

local INITIAL_SETTLE_TIME = 5 -- seconds - how long the server runs real suspension physics on a freshly-placed car before freezing it, so it settles onto the ground correctly instead of anchoring wherever it happened to be placed in Studio (often floating or embedded)

-- Frames the server holds the car in its parked pose after unanchoring it,
-- before handing the driver network ownership. The real cure for the car
-- swinging round on entry is seating the character properly in the first
-- place (see tryEnter in VehicleDoors.server.luau); this is the safety net for
-- whatever residual the weld still has to settle, and it has to happen while
-- the SERVER still owns the chassis - once ownership is the driver's, their
-- client's physics state is authoritative and anything written here is
-- overwritten by the next replication tick.
local SEAT_SETTLE_FRAMES = 3

-- Runs real suspension physics briefly so a freshly-placed car (which may be
-- floating or embedded, wherever it was left in Studio) settles onto the
-- ground properly, then Anchors it there. Only ever runs once, at setup -
-- this is not the old always-on parked-car loop, it's a one-time calibration.
local function SettleThenAnchor(carModel, chassis, attachments, driverSeat)
	local config = VehiclePhysics.GetConfig(chassis)
	local state = VehiclePhysics.NewState()

	chassis.Anchored = false
	chassis:SetNetworkOwner(nil) -- server simulates this settle-in period

	local elapsed = 0
	while elapsed < INITIAL_SETTLE_TIME do
		local delta = RunService.Heartbeat:Wait()
		-- Someone may have already gotten in while this was still settling -
		-- back off immediately rather than fighting the driving client.
		if driverSeat.Occupant then
			return
		end
		elapsed += delta
		VehiclePhysics.Step(carModel, attachments, config, state, delta, { Throttle = 0, Steer = 0 })
	end

	if not driverSeat.Occupant then
		chassis.Anchored = true
	end
end

-- The steering wheel prop has to turn, so it needs a joint whose offset can
-- be changed at runtime - that means a Weld (which has C0/C1) and NOT a
-- WeldConstraint, which just pins two parts together with no offset to
-- animate. Any existing joint on the part is replaced, so it doesn't matter
-- how it was welded in Studio; whatever pose it was left in becomes its
-- resting pose.
--
-- The resting C0 is stored as an attribute rather than kept in a table here,
-- because the client is what actually spins the wheel and it needs a
-- neutral to rotate away from. Reading it back off the joint means the client
-- can never accumulate rotation onto an already-rotated value and drift.
local function SetUpSteeringWheel(carModel, chassis)
	local part = VehiclePhysics.GetSteeringWheelPart(carModel)
	if not part then
		return -- car has no steering wheel prop, which is fine
	end

	for _, joint in carModel:GetDescendants() do
		if (joint:IsA("Weld") or joint:IsA("WeldConstraint") or joint:IsA("Motor6D"))
			and (joint.Part0 == part or joint.Part1 == part)
		then
			joint:Destroy()
		end
	end

	part.Anchored = false
	part.CanCollide = false
	-- Multi-part steering wheel (rim, spokes, horn boss): everything else
	-- rides on the part we're about to animate, so the whole assembly turns
	-- together. The container has to be a "SteeringWheel" wrapper and NOT the
	-- car model itself - a steering wheel that is a direct part child of the
	-- car would otherwise match here and weld the entire vehicle to it.
	local assembly = part.Parent
	if assembly ~= carModel and assembly.Name == "SteeringWheel" then
		for _, other in assembly:GetDescendants() do
			if other:IsA("BasePart") and other ~= part then
				other.Anchored = false
				other.CanCollide = false
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = part
				weld.Part1 = other
				weld.Parent = other
			end
		end
	end

	local weld = Instance.new("Weld")
	weld.Name = "SteeringWheelWeld"
	weld.Part0 = chassis
	weld.Part1 = part
	weld.C0 = chassis.CFrame:ToObjectSpace(part.CFrame)
	weld:SetAttribute("BaseC0", weld.C0)
	weld.Parent = part
end

local function AddCar(carModel)
	local chassis = carModel.PrimaryPart
	if not chassis then
		warn("VehicleManager: " .. carModel:GetFullName() .. " has no PrimaryPart set - skipping this car")
		return
	end
	local driverSeat = VehicleSeats.GetDriverSeat(carModel)
	if not driverSeat then
		warn("VehicleManager: " .. carModel:GetFullName() .. " has no DriverSeat - skipping this car")
		return
	end
	local attachments = VehiclePhysics.GetWheelAttachments(chassis)

	-- Roblox draws its own speedometer/throttle HUD for anyone sitting in a
	-- VehicleSeat, which sits on top of our dashboard. Set on the server so
	-- it replicates to every player who ever sits in this car, rather than
	-- being re-disabled per client on each sit.
	driverSeat.HeadsUpDisplay = false

	-- Light switches are a physical position, not driving telemetry - they
	-- start off/centered and stay wherever a driver last left them, rather
	-- than resetting when the car is vacated (see the Occupant listener
	-- below, which only resets the Net* driving telemetry).
	carModel:SetAttribute("HeadlightsOn", false)
	carModel:SetAttribute("TurnSignal", "None")

	-- Engine starts off: the Sound instance is pre-placed in the model and may
	-- have been left Playing in Studio, so this can't just assume silence.
	SetEngineSoundPlaying(carModel, false)

	-- Rigidly weld static decoration (body panels, lights) to the chassis so it
	-- rides along with suspension movement. Only the steering wheel is
	-- deliberately left out - it gets its own animatable joint just below,
	-- because it has to turn.
	--
	-- Doors used to be left out too, back when they swung on a HingeConstraint.
	-- They are now ordinary welded panels living in Body, which makes the whole
	-- car a single physics assembly and lets a door be knocked off in a crash
	-- like any other cosmetic part. See VehicleDoors.server.luau.
	--
	-- "Collision" is the invisible hull boxes that are the car's real shape for
	-- crash purposes (see VehicleCollision). Welded here rather than by the
	-- tool that builds them, so a car whose hulls were hand-edited in Studio
	-- and left unwelded still ends up rigid.
	--
	-- "Mirror" is deliberately NOT in this list. A mirror is welded in Studio to
	-- the door panel it sits on, and that is what makes it fall off with that
	-- panel when the panel is knocked off in a crash - welding it to the chassis
	-- as well would leave it hanging in mid-air once the door had gone.
	--
	-- If a mirror ever drops straight to the floor on spawn, check the Enabled
	-- property of its WeldConstraint before suspecting anything here: a disabled
	-- one still shows up in the Explorer looking exactly like a working weld.
	for _, folderName in { "Body", "Lights", "Engine", "Collision" } do
		local folder = carModel:FindFirstChild(folderName)
		if folder then
			VehiclePhysics.WeldFolderToChassis(folder, chassis)
		end
	end

	SetUpSteeringWheel(carModel, chassis)

	-- Parked by default: fully Anchored, so there is no physics running at
	-- all (and nothing that can jitter) until someone actually drives it.
	-- Suspension only runs while unanchored, in the driving client's own
	-- Step() loop - parking just freezes whatever pose the car was last
	-- settled into (e.g. wheels raised correctly onto a curb), it doesn't
	-- keep re-simulating to hold that pose. Starts Anchored immediately so
	-- there's no gap where it's an unowned, unsimulated physics body -
	-- SettleThenAnchor (below) briefly takes over right after to calibrate
	-- its actual resting pose before freezing it there for real.
	chassis.Anchored = true

	driverSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = driverSeat.Occupant
		if occupant then
			local player = Players:GetPlayerFromCharacter(occupant.Parent)
			if player then
				SetEngineSoundPlaying(carModel, true)

				local pose = chassis.CFrame
				chassis.Anchored = false

				-- Hold the parked pose for a few frames while the server still
				-- owns the chassis, so anything the seat weld still wants to
				-- settle gets absorbed here instead of showing up as the car
				-- lurching or swinging as the driver takes over. Setting CFrame
				-- on a part moves its whole assembly, so the seated character
				-- comes along rather than being left behind.
				for _ = 1, SEAT_SETTLE_FRAMES do
					if driverSeat.Occupant ~= occupant then
						return -- got out, died or disconnected mid-settle
					end
					chassis.CFrame = pose
					chassis.AssemblyLinearVelocity = Vector3.zero
					chassis.AssemblyAngularVelocity = Vector3.zero
					RunService.Heartbeat:Wait()
				end

				if driverSeat.Occupant ~= occupant then
					return
				end
				chassis:SetNetworkOwner(player)
			end
		else
			chassis.Anchored = true
			SetEngineSoundPlaying(carModel, false)
			-- Nobody's left to keep sending updates for these, so clear them
			-- rather than leaving the last driver's state stuck (e.g. a
			-- bystander walking up to a parked car that's frozen mid-brake
			-- light because that's how its last driver left it).
			carModel:SetAttribute("NetBraking", false)
			carModel:SetAttribute("NetReversing", false)
			carModel:SetAttribute("NetBurnout", false)
			carModel:SetAttribute("NetHandbrake", false)
			carModel:SetAttribute("NetThrottle", 0)
			carModel:SetAttribute("NetRpm", 0)
		end
	end)

	-- wheels (purely cosmetic - a car can override its wheel mesh via a
	-- "WheelModelName" attribute on the Chassis, or a WheelModelName entry in
	-- its Configs/<name>.luau file, naming a different model in
	-- ReplicatedStorage.Wheels)
	local wheelModelName = VehiclePhysics.GetConfig(chassis).WheelModelName
	local wheelModel = (wheelModelName and wheelsFolder:FindFirstChild(wheelModelName)) or defaultWheelModel

	local wheelFolder = Instance.new("Folder", carModel)
	wheelFolder.Name = "Wheels"
	for _, wheelName in VehiclePhysics.WheelNames do
		local attachment = attachments[wheelName]
		local clonedWheel = wheelModel:Clone()
		clonedWheel.Parent = wheelFolder
		clonedWheel.Name = wheelName

		-- Works for both a single Part wheel and a multi-part Model wheel
		-- (rim/tire/hubcap etc, rigidly welded together internally with the
		-- model's PrimaryPart as the one part we connect to the chassis).
		local parts = clonedWheel:IsA("Model") and clonedWheel:GetDescendants() or { clonedWheel }
		for _, part in parts do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Anchored = false
			end
		end

		local wheelPrimary = VehiclePhysics.GetWheelPrimaryPart(clonedWheel)
		local weld = Instance.new("Weld", wheelPrimary)
		weld.Part0 = chassis
		weld.Part1 = wheelPrimary
		weld.C0 = CFrame.new(attachment.Position)

		if attachment.Position.X > 0 then
			weld.C0 = weld.C0 * CFrame.Angles(0, math.rad(180), 0)
		end
	end

	task.spawn(SettleThenAnchor, carModel, chassis, attachments, driverSeat)
end

local function TryAddCar(carModel)
	-- One misconfigured car (missing PrimaryPart, missing a WheelXX
	-- attachment, etc) shouldn't be able to take down every other car's
	-- setup by erroring out of this script entirely.
	local ok, err = pcall(AddCar, carModel)
	if not ok then
		warn("VehicleManager: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	TryAddCar(carModel)
end
VehicleFolder.ChildAdded:Connect(TryAddCar)

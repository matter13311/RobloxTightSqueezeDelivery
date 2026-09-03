-- Drives the driver/passenger door hinges around getting in and out of a
-- car: EnterVehicle request -> open door -> sit the player -> close door,
-- and the reverse on the way out. Server-authoritative for the same reason
-- VehicleLightSwitches is - a client can fire the enter/exit remotes, but
-- never move a door or seat anyone by itself, which is also where the
-- ownership check (see playerCanEnter below) has to live once that exists.
--
-- The "Enter" UI itself is a custom BillboardGui, not a ProximityPrompt (see
-- VehicleDoorPrompts.client.luau) - that client only decides WHEN to show a
-- prompt and fires EnterVehicle when F is pressed, so distance is still
-- re-checked here rather than trusted from the client.
--
-- Door discovery (Frame.InteriorFrame.<Side>DoorAttachment.HingeConstraint,
-- Doors.<Side>Door) is shared with the client via VehicleDoorRig - see that
-- module for the exact structure a car needs. Lower/UpperAngle, ActuatorType
-- etc are authored here rather than trusted from Studio, so a car is fully
-- configured by code alone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleDoorRig = require(ReplicatedStorage.Modules.Vehicles.VehicleDoorRig)

local VehicleFolder = workspace.Vehicles
local DOOR_SIDES = VehicleDoorRig.Sides

-- Hinge tuning. AngularSpeed/AngularResponsiveness control how the Servo
-- actually moves; DOOR_SWING_TIME is how long the enter/exit sequence PAUSES
-- to let that motion finish before continuing (sitting the player, playing
-- the close sound, etc). These aren't derived from each other - if you speed
-- up or slow down the swing, re-tune DOOR_SWING_TIME to match or the
-- sequence will either wait too long or cut the animation off early.
local DOOR_LOWER_ANGLE = 0
-- Left and Right are mirror images of each other, so "open" is the opposite
-- rotation sign on each side even though "closed" (0) is shared.
local DOOR_UPPER_ANGLE = { Left = 75, Right = -75 }
local DOOR_ANGULAR_SPEED = 2.5
local DOOR_ANGULAR_RESPONSIVENESS = 15
local DOOR_SWING_TIME = 1

-- Extra pause after the exit go-ahead is sent, before the door swings shut -
-- gives the client's own teleport-out (which happens a frame or two after it
-- gets the signal) time to actually clear the doorway first.
local EXIT_CLEAR_TIME = 0.3

-- Generous compared to the client's own prompt-visibility range (see
-- VehicleDoorPrompts.client.luau) - this exists to catch a cheated/forged
-- request from way outside the car, not to be the source of truth for
-- exactly how close is "close enough" to see the prompt.
local MAX_ENTER_DISTANCE = 12

local doorSoundEvent = Instance.new("RemoteEvent")
doorSoundEvent.Name = "PlayDoorSound"
doorSoundEvent.Parent = ReplicatedStorage

local enterVehicleEvent = Instance.new("RemoteEvent")
enterVehicleEvent.Name = "EnterVehicle"
enterVehicleEvent.Parent = ReplicatedStorage

local exitVehicleEvent = Instance.new("RemoteEvent")
exitVehicleEvent.Name = "ExitVehicle"
exitVehicleEvent.Parent = ReplicatedStorage

-- [carModel] = { CarModel, Doors = { Left = {...}, Right = {...} }, Seat, Busy }
local carsData = {}

-- Placeholder for the per-car ownership system planned later (each player
-- spawns their own car and only they may enter it). Both entry paths funnel
-- through this one check, so wiring that in later is a one-function change -
-- e.g. `return carModel:GetAttribute("OwnerUserId") == player.UserId`.
local function playerCanEnter(player, carModel)
	return true
end

-- GetJoints() returns both classic joints (Weld, Motor6D, ...), which use
-- Part0/Part1, and Constraint-based ones (WeldConstraint, HingeConstraint,
-- ...), which use Attachment0/Attachment1 instead - and never the door's own
-- HingeConstraint, which must survive this untouched.
local function getJointOtherPart(joint, part)
	if joint:IsA("HingeConstraint") then
		return nil
	end
	if joint:IsA("Constraint") then
		local a0, a1 = joint.Attachment0, joint.Attachment1
		local p0 = a0 and a0.Parent
		local p1 = a1 and a1.Parent
		if p0 == part then
			return p1
		elseif p1 == part then
			return p0
		end
		return nil
	end
	return if joint.Part0 == part then joint.Part1 else joint.Part0
end

-- Studio auto-creates a rigid Weld between two parts that were touching when
-- they got placed/moved - if that happened between a door and the frame, it
-- fights the HingeConstraint for control of the door (this is exactly what a
-- door that slowly creeps open under gravity, and barely responds to
-- TargetAngle changes, looks like). Only joints leading OUTSIDE the door
-- model are removed, so welds holding the door's own parts together (and the
-- HingeConstraint itself) survive.
local function removeExternalJoints(doorModel)
	for _, part in doorModel:GetDescendants() do
		if part:IsA("BasePart") then
			for _, joint in part:GetJoints() do
				local other = getJointOtherPart(joint, part)
				if other and not other:IsDescendantOf(doorModel) then
					joint:Destroy()
				end
			end
		end
	end
end

local function configureHinge(hinge, side)
	hinge.ActuatorType = Enum.ActuatorType.Servo
	hinge.LowerAngle = DOOR_LOWER_ANGLE
	hinge.UpperAngle = DOOR_UPPER_ANGLE[side]
	hinge.AngularSpeed = DOOR_ANGULAR_SPEED
	hinge.AngularResponsiveness = DOOR_ANGULAR_RESPONSIVENESS
	-- Doesn't default to anything usable - a Servo with zero max torque can't
	-- actually move the door no matter what TargetAngle is set to. Unlimited
	-- here; lower it later if you want a door that can be shoved open by
	-- something heavy enough to overpower the servo.
	hinge.ServoMaxTorque = math.huge
	hinge.TargetAngle = DOOR_LOWER_ANGLE
end

local function setDoorOpen(hinge, open)
	hinge.TargetAngle = open and hinge.UpperAngle or hinge.LowerAngle
end

-- Disabled while a player is stepping out through it, so the door swinging
-- shut behind them can't physically shove them back into the car.
local function setDoorCollision(doorModel, canCollide)
	for _, part in doorModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = canCollide
		end
	end
end

-- Only fires to a player who's still actually connected - a player who left
-- mid-sequence has a dead Instance that FireClient would otherwise error on.
local function fireDoorSound(player, doorPart, action)
	if player.Parent then
		doorSoundEvent:FireClient(player, doorPart, action)
	end
end

-- Picks whichever door is physically closer to a given world position, and
-- how far away it is. Shared by entering (nearest to where the player is
-- actually standing) and exiting (nearest to where they're about to end up).
local function nearestDoorSideToPosition(carData, referencePosition)
	local bestSide, bestDistance = nil, math.huge
	for side, door in carData.Doors do
		local distance = (door.FrameAttachment.WorldPosition - referencePosition).Magnitude
		if distance < bestDistance then
			bestSide = side
			bestDistance = distance
		end
	end
	return bestSide, bestDistance
end

-- Where the player is about to end up standing after getting out - the
-- DriverExit marker if the car has one, otherwise just the seat.
local function exitReferencePosition(carData)
	local marker = carData.CarModel:FindFirstChild("DriverExit", true)
	if marker and marker:IsA("Attachment") then
		return marker.WorldPosition
	elseif marker and marker:IsA("BasePart") then
		return marker.Position
	end
	return carData.Seat.Position
end

local function tryEnter(carData, side, player)
	if carData.Busy or carData.Seat.Occupant then
		return
	end
	if not playerCanEnter(player, carData.CarModel) then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.SeatPart then
		return -- already sitting somewhere (this car or another) - can't be entering a second one
	end

	carData.Busy = true

	-- Busy only has to cover the "is someone committed to entering right
	-- now" window - it's released the moment that's decided (seated, or
	-- bailed out) rather than held for the whole visual door-closing tail
	-- afterwards. Otherwise pressing F to leave again immediately after
	-- getting in can land while Busy is still true from this same sequence,
	-- and get silently dropped (see tryExit's own Busy check) while the
	-- client sits there waiting for a server response that never comes.
	local ok, err = pcall(function()
		local door = carData.Doors[side]
		setDoorOpen(door.Hinge, true)
		fireDoorSound(player, door.Part, "Open")

		task.wait(DOOR_SWING_TIME)

		-- Bail (and swing the door back shut) if something changed while it
		-- was opening - the seat got taken another way, or the player left/died.
		if carData.Seat.Occupant or not player.Parent or humanoid.Parent ~= character or character.Parent == nil then
			carData.Busy = false
			setDoorOpen(door.Hinge, false)
			fireDoorSound(player, door.Part, "Close")
			task.wait(DOOR_SWING_TIME)
			return
		end

		carData.Seat:Sit(humanoid)
		carData.Busy = false -- committed - Seat.Occupant now guards re-entry on its own

		setDoorOpen(door.Hinge, false)
		fireDoorSound(player, door.Part, "Close")
		task.wait(DOOR_SWING_TIME)
	end)

	-- Safety net: if the sequence above errored before reaching its own
	-- release point, don't leave this car permanently unusable.
	carData.Busy = false
	if not ok then
		warn("VehicleDoors: enter sequence errored for " .. carData.CarModel:GetFullName() .. ": " .. tostring(err))
	end
end

local function tryExit(carData, player)
	if carData.Busy or not carData.Seat.Occupant then
		return
	end
	local occupantPlayer = Players:GetPlayerFromCharacter(carData.Seat.Occupant.Parent)
	if occupantPlayer ~= player then
		return
	end

	carData.Busy = true

	local door
	local ok, err = pcall(function()
		local side = nearestDoorSideToPosition(carData, exitReferencePosition(carData))
		door = carData.Doors[side]
		setDoorOpen(door.Hinge, true)
		fireDoorSound(player, door.Part, "Open")

		-- Off for the whole time the player might be standing in the
		-- doorway - otherwise the door swinging shut on its way back to
		-- closed can physically shove them back into the seat.
		setDoorCollision(door.Model, false)

		task.wait(DOOR_SWING_TIME)
		-- Go-ahead: the driving client does its own unseat + step-out (see
		-- tryExitVehicle in RayCastSuspension.client.luau) once it gets this.
		if player.Parent then
			exitVehicleEvent:FireClient(player)
		end
		carData.Busy = false -- released as soon as the client's been told to go - the closing tail below doesn't need to block anything else

		task.wait(EXIT_CLEAR_TIME)

		setDoorOpen(door.Hinge, false)
		fireDoorSound(player, door.Part, "Close")
		task.wait(DOOR_SWING_TIME)

		setDoorCollision(door.Model, true)
	end)

	carData.Busy = false
	if not ok then
		warn("VehicleDoors: exit sequence errored for " .. carData.CarModel:GetFullName() .. ": " .. tostring(err))
		-- Whatever step failed, don't leave the door permanently un-collidable.
		if door then
			setDoorCollision(door.Model, true)
		end
	end
end

local function setupCarDoors(carModel)
	local doors = VehicleDoorRig.GetDoors(carModel)
	local seat = carModel:FindFirstChildOfClass("VehicleSeat")
	if not (doors and doors.Left and doors.Right and seat) then
		warn("VehicleDoors: " .. carModel:GetFullName() .. " is missing a Left/RightDoorAttachment HingeConstraint or a VehicleSeat - skipping doors")
		return
	end

	-- Walking into the seat would otherwise sit the player instantly, bypassing
	-- the door entirely - Seat:Sit(humanoid) (used by tryEnter above) still
	-- works fine on a Disabled seat, so this only blocks the automatic
	-- touch-to-sit path, not our own scripted one.
	seat.Disabled = true

	local carData = { CarModel = carModel, Doors = doors, Seat = seat, Busy = false }
	carsData[carModel] = carData

	for _, side in DOOR_SIDES do
		local door = doors[side]
		removeExternalJoints(door.Model)
		configureHinge(door.Hinge, side)
	end
end

local function trySetupCarDoors(carModel)
	local ok, err = pcall(setupCarDoors, carModel)
	if not ok then
		warn("VehicleDoors: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

-- The client-side prompt (see VehicleDoorPrompts.client.luau) only decides
-- WHEN to show its single "Enter" UI (one prompt per car, not one per door)
-- and fires this on F - which door that resolves to is decided here, from
-- the player's actual position, rather than trusted from the client.
enterVehicleEvent.OnServerEvent:Connect(function(player, carModel)
	local carData = typeof(carModel) == "Instance" and carsData[carModel]
	if not carData then
		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local side, distance = nearestDoorSideToPosition(carData, rootPart.Position)
	if not side or distance > MAX_ENTER_DISTANCE then
		return
	end

	tryEnter(carData, side, player)
end)

-- One shared remote for every car, so the handler has to work out which car
-- (if any) the requesting player is actually seated in rather than assuming.
exitVehicleEvent.OnServerEvent:Connect(function(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seatPart = humanoid and humanoid.SeatPart
	local carData = seatPart and carsData[seatPart.Parent]
	if carData and carData.Seat == seatPart then
		tryExit(carData, player)
	end
end)

for _, carModel in VehicleFolder:GetChildren() do
	trySetupCarDoors(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetupCarDoors)
VehicleFolder.ChildRemoved:Connect(function(carModel)
	carsData[carModel] = nil
end)

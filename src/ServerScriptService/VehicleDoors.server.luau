-- Getting in and out of a car. The player is teleported onto the seat (and
-- back out again) with the door open/close cue played over the top - there is
-- no physical door swing any more.
--
-- WHY THE HINGES WENT
--
-- A swinging door has to be its own physics assembly, because that is what a
-- HingeConstraint is for. That made every car three assemblies instead of one,
-- and any hull box overlapping a door was two separate bodies fighting over
-- the same space - the truck shook itself apart until the doors were moved
-- into their own collision group. The enter/exit sequences also had to be
-- async around the swing (open, wait, seat, wait, close), which is where most
-- of their state and most of their bugs lived.
--
-- Doors are now plain welded panels in the Body folder, which means they are
-- one assembly with the chassis, and - as a bonus - they are cosmetic damage
-- parts like any other, so a hard enough crash knocks one clean off.
--
-- Server-authoritative for the same reason VehicleLightSwitches is: a client
-- can fire the enter/exit remotes, but never seat anyone by itself. The "Enter"
-- UI is a custom BillboardGui (VehicleDoorPrompts.client.luau) which decides
-- WHEN to offer the prompt; distance is still re-checked here rather than
-- trusted from the client.
--
-- WHERE "THE DOOR" IS, NOW THAT THERE ISN'T ONE
--
-- The Exit# attachments on the Chassis (see VehicleExits) - ground level, just
-- outside each door. They already existed to decide where a player steps out,
-- they are on the chassis so nothing can knock them off, and they are exactly
-- the "you are standing at a door" reference the prompt and the range check
-- need. That is why there is no door rig module any more.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleExits = require(ReplicatedStorage.Modules.Vehicles.VehicleExits)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local VehicleFolder = workspace.Vehicles

-- Deliberately looser than the client's own prompt-visibility range (see
-- MAX_PROMPT_DISTANCE in VehicleDoorPrompts.client.luau) - this exists to catch
-- a cheated/forged request from way outside the car, not to be the source of
-- truth for how close is "close enough". Keep it comfortably above that
-- number: measured from the same exit attachments, but a player who was
-- legitimately in range when they pressed F can still have walked or been
-- shoved a little way off by the time the request lands here.
local MAX_ENTER_DISTANCE = 12

-- The beat between the door-open cue and the door-close cue. With no swing to
-- wait for, this is purely how long the two sounds are held apart so it reads
-- as "door opens, you get in, door shuts" rather than as one noise. Short
-- enough that entering still feels instant.
local DOOR_SOUND_GAP = 0.35

-- Extra pause on the way out before the close cue, so the client's own
-- teleport-out (a frame or two after it gets the go-ahead) has visibly
-- happened before the door is heard shutting.
local EXIT_CLEAR_TIME = 0.3

-- How far above the seat's own centre the character's pivot (its
-- HumanoidRootPart) is placed just before being welded in - see tryEnter. Only
-- has to be close enough that the seat weld has no meaningful error left to
-- resolve; the weld itself decides the exact final position.
local SEAT_PIVOT_HEIGHT = 2

local doorSoundEvent = Instance.new("RemoteEvent")
doorSoundEvent.Name = "PlayDoorSound"
doorSoundEvent.Parent = ReplicatedStorage

local enterVehicleEvent = Instance.new("RemoteEvent")
enterVehicleEvent.Name = "EnterVehicle"
enterVehicleEvent.Parent = ReplicatedStorage

local exitVehicleEvent = Instance.new("RemoteEvent")
exitVehicleEvent.Name = "ExitVehicle"
exitVehicleEvent.Parent = ReplicatedStorage

-- [carModel] = { CarModel, Seat, Busy }
local carsData = {}

-- Authoritative ownership gate. The rule itself lives in VehicleOwnership so
-- the client's "Enter" prompt can ask the same question and never offer a car
-- that would be refused here - but this is the copy that decides, and it runs
-- on a request the client cannot forge past.
local function playerCanEnter(player, carModel)
	return VehicleOwnership.CanEnter(player, carModel)
end

local function attachmentPosition(exit)
	return if exit:IsA("Attachment") then exit.WorldPosition else exit.Position
end

-- Nearest exit attachment to a world position, and how far away it is. Shared
-- by entering (nearest to where the player is actually standing) and by the
-- sound cue (so the door you hear is the one you are next to).
local function nearestExitToPosition(carModel, referencePosition)
	local best, bestDistance = nil, math.huge
	for _, exit in VehicleExits.GetExits(carModel) do
		local distance = (attachmentPosition(exit) - referencePosition).Magnitude
		if distance < bestDistance then
			best, bestDistance = exit, distance
		end
	end
	return best, bestDistance
end

-- Only fires to a player who's still actually connected - a player who left
-- mid-sequence has a dead Instance that FireClient would otherwise error on.
--
-- `at` is an Exit Attachment rather than a door part: a Sound parented to an
-- Attachment plays at that attachment's world position, so the cue still comes
-- from the right side of the truck without a door existing to hang it on.
local function fireDoorSound(player, at, action)
	if player.Parent and at then
		doorSoundEvent:FireClient(player, at, action)
	end
end

local function tryEnter(carData, exit, player)
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

	local ok, err = pcall(function()
		fireDoorSound(player, exit, "Open")

		-- Put the character ON the seat, facing the way the seat faces, BEFORE
		-- welding them to it. Seat:Sit() creates a rigid weld and leaves the
		-- solver to resolve whatever error is left between the two ends - and
		-- an anchored car cannot resolve anything, because an anchored assembly
		-- does not simulate at all. So the entire error was still sitting there
		-- unresolved at the moment the car was unanchored, at which point both
		-- ends were dynamic and the solver split the correction between them by
		-- mass: instead of the character being pulled into the seat, the CAR
		-- swung round to line up with whichever way the character happened to
		-- be facing when they pressed F. Landing them on the seat first leaves
		-- the weld with essentially no error to resolve, so there is nothing
		-- left to swing the car with.
		local seatPivot = carData.Seat.CFrame * CFrame.new(0, SEAT_PIVOT_HEIGHT, 0)
		character:PivotTo(seatPivot)
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			-- They were running a moment ago. Once welded that momentum becomes
			-- the whole car's momentum.
			rootPart.AssemblyLinearVelocity = Vector3.zero
			rootPart.AssemblyAngularVelocity = Vector3.zero
		end

		carData.Seat:Sit(humanoid)
		carData.Busy = false -- committed - Seat.Occupant now guards re-entry on its own

		task.wait(DOOR_SOUND_GAP)
		fireDoorSound(player, exit, "Close")
	end)

	-- Safety net: if the sequence above errored before reaching its own release
	-- point, don't leave this car permanently unusable.
	carData.Busy = false
	if not ok then
		warn("VehicleDoors: enter sequence errored for " .. carData.CarModel:GetFullName() .. ": " .. tostring(err))
	end
end

local function tryExit(carData, player)
	if carData.Busy or not carData.Seat.Occupant then
		return
	end
	local occupantCharacter = carData.Seat.Occupant.Parent
	local occupantPlayer = Players:GetPlayerFromCharacter(occupantCharacter)
	if occupantPlayer ~= player then
		return
	end

	carData.Busy = true

	local ok, err = pcall(function()
		-- The seat's preferred exit if it's clear, otherwise the nearest other
		-- one that is - see VehicleExits.ChooseExit. The same attachment is
		-- used for the sound and sent to the client, so what you hear and where
		-- you land always agree.
		local chosenExit = VehicleExits.ChooseExit(carData.CarModel, carData.Seat, occupantCharacter)
		fireDoorSound(player, chosenExit, "Open")

		-- Go-ahead: the driving client does its own unseat + step-out (see
		-- tryExitVehicle in RayCastSuspension.client.luau) once it gets this.
		if player.Parent then
			exitVehicleEvent:FireClient(player, chosenExit)
		end
		carData.Busy = false -- released as soon as the client's been told to go

		task.wait(EXIT_CLEAR_TIME)
		fireDoorSound(player, chosenExit, "Close")
	end)

	carData.Busy = false
	if not ok then
		warn("VehicleDoors: exit sequence errored for " .. carData.CarModel:GetFullName() .. ": " .. tostring(err))
	end
end

local function setupCar(carModel)
	local seat = VehicleSeats.GetDriverSeat(carModel)
	if not seat then
		warn("VehicleDoors: " .. carModel:GetFullName() .. " has no DriverSeat - skipping")
		return
	end
	if #VehicleExits.GetExits(carModel) == 0 then
		warn(
			"VehicleDoors: "
				.. carModel:GetFullName()
				.. " has no Exit# attachments on its Chassis - nobody will be able to get in or out. See VehicleExits."
		)
		return
	end

	-- Walking into the seat would otherwise sit the player instantly, bypassing
	-- the prompt entirely - Seat:Sit(humanoid) (used by tryEnter above) still
	-- works fine on a Disabled seat, so this only blocks the automatic
	-- touch-to-sit path, not our own scripted one.
	seat.Disabled = true

	carsData[carModel] = { CarModel = carModel, Seat = seat, Busy = false }
end

local function trySetupCar(carModel)
	local ok, err = pcall(setupCar, carModel)
	if not ok then
		warn("VehicleDoors: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

-- The client-side prompt (see VehicleDoorPrompts.client.luau) only decides WHEN
-- to show its single "Enter" UI and fires this on F - which door that resolves
-- to is decided here, from the player's actual position, rather than trusted
-- from the client.
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

	local exit, distance = nearestExitToPosition(carModel, rootPart.Position)
	if not exit or distance > MAX_ENTER_DISTANCE then
		return
	end

	tryEnter(carData, exit, player)
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
	trySetupCar(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetupCar)
VehicleFolder.ChildRemoved:Connect(function(carModel)
	carsData[carModel] = nil
end)

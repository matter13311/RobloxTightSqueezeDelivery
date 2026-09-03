-- Shows a single custom "Enter Vehicle" prompt (see CustomPrompt.luau) per
-- car instead of a real ProximityPrompt - see CustomPrompt.luau's own header
-- for why. One prompt covering both doors, not one each: with two doors
-- close enough together that being in range of one usually means being in
-- range of the other too, a prompt per door meant both could show at once,
-- and (since each independently bound the same F key) only one of them could
-- ever actually receive the keypress. This script only decides WHEN to show
-- the prompt and fires EnterVehicle when it's triggered - which door that
-- resolves to is VehicleDoors.server.luau's call, based on which one the
-- player is actually standing closer to at that moment.
--
-- Nothing here is a security boundary. Whether a player may actually enter is
-- decided by the server (VehicleDoors.server.luau) using the same
-- VehicleOwnership rule this script asks - so what's on screen matches what
-- would happen, but a client that lies about it still gets refused.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CustomPrompt = require(ReplicatedStorage.Modules.UI.CustomPrompt)
local VehicleDoorRig = require(ReplicatedStorage.Modules.Vehicles.VehicleDoorRig)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)

local player = Players.LocalPlayer
local VehicleFolder = workspace.Vehicles

-- Measured to the nearer DOOR, not to the seat at the car's centre. Measuring
-- from the centre meant the radius had to cover half the length of the truck
-- before it reached a door at all, so the prompt appeared while the player was
-- still well clear of the car - and appeared just as readily standing at the
-- back of the tray, nowhere near a way in. Door-relative, this is the real
-- "close enough to reach the handle" distance, so it can be small.
local MAX_PROMPT_DISTANCE = 6

local enterVehicleEvent = ReplicatedStorage:WaitForChild("EnterVehicle")

-- [carModel] = CustomPrompt
local carPrompts = {}

local function setupCarPrompts(carModel)
	-- Never build a second prompt for a car that already has one. Both the
	-- startup sweep and the ChildAdded handler can reach the same car, and a
	-- duplicate would parent a second billboard to the same seat that nothing
	-- holds a reference to - so tearing the car down would leave it behind,
	-- permanently visible, with no way to reach it.
	if carPrompts[carModel] then
		return true
	end

	local doors = VehicleDoorRig.GetDoors(carModel)
	local seat = carModel:FindFirstChildOfClass("VehicleSeat")
	if not (doors and doors.Left and doors.Right and seat) then
		return false -- not fully set up yet - the retry below will catch it once it is
	end

	local prompt = CustomPrompt.new(seat, {
		Text = "Enter Vehicle",
		KeyCode = Enum.KeyCode.F,
		MaxActivationDistance = MAX_PROMPT_DISTANCE,
		-- The billboard still floats over the seat (centred over the cab, so
		-- it reads the same from either side), but range is judged from the
		-- door openings.
		DistanceFrom = { doors.Left.FrameAttachment, doors.Right.FrameAttachment },
		-- Re-asked every frame rather than pushed from event handlers. The
		-- previous version drove this off Seat.Occupant changing and the local
		-- Humanoid.Seated firing, and a prompt that outlives EITHER of those -
		-- a car that finished replicating with someone already in it, a
		-- Seated event during a respawn, a car whose seat reference went stale -
		-- had no way back to hidden and simply stayed on screen. Asking the
		-- live values every frame has no such failure mode.
		--
		-- CustomPrompt separately hides any prompt while the local player is
		-- seated in anything at all, so that case is covered even if this
		-- car's own Occupant hasn't replicated yet.
		ShouldShow = function()
			-- Occupant covers "somebody is in this car" from the CAR's side,
			-- which is the half CustomPrompt's own seated check cannot see
			-- (that one only knows about the local player). Together they
			-- close the gap in both directions: this car being occupied by
			-- anyone, and the local player being inside anything at all.
			return seat.Occupant == nil and VehicleOwnership.CanEnter(player, carModel)
		end,
	})
	prompt.Triggered:Connect(function()
		enterVehicleEvent:FireServer(carModel)
	end)
	carPrompts[carModel] = prompt
	return true
end

-- A freshly-added car (or one that just hasn't finished replicating to this
-- client yet at game start - Workspace isn't guaranteed fully replicated the
-- instant PlayerScripts starts running) may not have its Frame/Doors in
-- place for a bit. Retries every second, for up to a minute, rather than
-- giving up after a single attempt.
local SETUP_RETRY_INTERVAL = 1
local SETUP_RETRY_TIMEOUT = 60

local function trySetupCarPrompts(carModel)
	if setupCarPrompts(carModel) then
		return
	end
	task.spawn(function()
		local elapsed = 0
		while carModel.Parent == VehicleFolder and not carPrompts[carModel] and elapsed < SETUP_RETRY_TIMEOUT do
			task.wait(SETUP_RETRY_INTERVAL)
			elapsed += SETUP_RETRY_INTERVAL
			if carModel.Parent == VehicleFolder and not carPrompts[carModel] and setupCarPrompts(carModel) then
				return
			end
		end
		if carModel.Parent == VehicleFolder and not carPrompts[carModel] then
			warn("VehicleDoorPrompts: gave up waiting for " .. carModel:GetFullName() .. " to have Left/RightDoorAttachment hinges and a VehicleSeat")
		end
	end)
end

local function teardownCarPrompts(carModel)
	local prompt = carPrompts[carModel]
	if prompt then
		prompt:Destroy()
		carPrompts[carModel] = nil
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	trySetupCarPrompts(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetupCarPrompts)
VehicleFolder.ChildRemoved:Connect(teardownCarPrompts)

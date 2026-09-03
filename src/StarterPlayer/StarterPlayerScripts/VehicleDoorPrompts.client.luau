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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CustomPrompt = require(ReplicatedStorage.Modules.UI.CustomPrompt)
local VehicleDoorRig = require(ReplicatedStorage.Modules.Vehicles.VehicleDoorRig)

local player = Players.LocalPlayer
local VehicleFolder = workspace.Vehicles
-- Measured from the seat (roughly the car's center), not a door directly, so
-- this needs enough radius to comfortably reach either side from outside.
local MAX_PROMPT_DISTANCE = 10

local enterVehicleEvent = ReplicatedStorage:WaitForChild("EnterVehicle")

-- [carModel] = CustomPrompt
local carPrompts = {}
-- [carModel] = function that re-checks that car's own prompt against both
-- its Occupant and playerSeated below
local carRefreshers = {}

-- Belt-and-suspenders on top of each car's own Occupant check: no "Enter"
-- prompt should ever show while the LOCAL player is seated in ANYTHING, not
-- just this car - covers it even if something upstream about a specific
-- car's Occupant replication is ever delayed or missed.
local playerSeated = false

local function refreshAllCarPrompts()
	for _, refresh in carRefreshers do
		refresh()
	end
end

local function setupCarPrompts(carModel)
	local doors = VehicleDoorRig.GetDoors(carModel)
	local seat = carModel:FindFirstChildOfClass("VehicleSeat")
	if not (doors and doors.Left and doors.Right and seat) then
		return false -- not fully set up yet - the retry below will catch it once it is
	end

	local prompt = CustomPrompt.new(seat, {
		Text = "Enter Vehicle",
		KeyCode = Enum.KeyCode.F,
		MaxActivationDistance = MAX_PROMPT_DISTANCE,
	})
	prompt.Triggered:Connect(function()
		enterVehicleEvent:FireServer(carModel)
	end)
	carPrompts[carModel] = prompt

	-- Nobody should see an "Enter" prompt on a car that's already occupied -
	-- that includes the driver looking at their own door from inside.
	local function refresh()
		prompt:SetEnabled(seat.Occupant == nil and not playerSeated)
	end
	seat:GetPropertyChangedSignal("Occupant"):Connect(refresh)
	carRefreshers[carModel] = refresh
	refresh()
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
		carRefreshers[carModel] = nil
	end
end

local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")
	humanoid.Seated:Connect(function(seated)
		playerSeated = seated
		refreshAllCarPrompts()
	end)
end
if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

for _, carModel in VehicleFolder:GetChildren() do
	trySetupCarPrompts(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetupCarPrompts)
VehicleFolder.ChildRemoved:Connect(teardownCarPrompts)

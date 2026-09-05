-- The horn (H). Deliberately the one vehicle sound that is NOT created and
-- played on the driving client.
--
-- Every other car sound in this game (gear shifts, the handbrake, tire
-- screech) is built client-side by whoever is driving - see createSound in
-- RayCastSuspension.client.luau, and the comment above it explaining that the
-- tradeoff is those sounds only ever play for the driver. That tradeoff is
-- fine for a gearbox nobody outside the cab can hear anyway. It is exactly
-- wrong for a horn, whose entire purpose is to be heard by OTHER players.
--
-- So the Sound instance itself is created here, on the server, parented to
-- the car's Chassis. That gets both halves of what a horn needs for free:
--   * a Sound that exists on the server replicates to every client, so
--     :Play()/:Stop() called here is heard by everyone in earshot - including
--     someone who wasn't even streamed the car when the honk started;
--   * because it lives ON the chassis rather than in a client's local
--     SoundService, Roblox positions it in 3D at that car, so players hear
--     WHICH car is honking and from which direction.
--
-- Looped, so holding H sustains the horn and releasing it cuts the sound - a
-- short beep recording covers both a tap and a long lean without needing two
-- assets. The client sends true on key-down and false on key-up (and again
-- when it tears its driving session down); MAX_HORN_SECONDS below is the
-- backstop for the case where that "false" never arrives.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local HORN_SOUND_NAME = "HornSound"

-- A stuck horn is one of the more obnoxious things that can happen to a
-- server full of players, and the release message is the kind of thing that
-- genuinely can go missing: the driver disconnects mid-honk, the character
-- dies, the client errors between key-down and key-up. Nobody legitimately
-- holds a horn longer than this, so cutting it here costs nothing and means
-- no combination of lost messages can leave a car honking forever.
local MAX_HORN_SECONDS = 10

-- Created before anything here touches Workspace, for the same reason
-- PlotManager creates its remotes up front: every client blocks on
-- ReplicatedStorage:WaitForChild("SetHorn") when it requires VehicleControls,
-- so if this script errored on a missing folder before reaching this line,
-- the failure would surface as every client's vehicle scripts hanging
-- forever with nothing printed to explain why.
local remote = Instance.new("RemoteEvent")
remote.Name = "SetHorn"
remote.Parent = ReplicatedStorage

local VehicleFolder = workspace:WaitForChild("Vehicles")

-- [vehicle] = Player currently holding the horn down. Also the "is it on"
-- flag: the Sound's own IsPlaying can't be trusted for that, because a Sound
-- that fails to load never reports playing.
local hornHolders = {}

-- [vehicle] = number, bumped on every start AND every stop. The timeout
-- thread below captures the value it was started with and does nothing if it
-- no longer matches, so a tap-tap-tap on the horn can't have an early tap's
-- expired timer cut off a later one.
local hornGenerations = {}

-- Built once per car, when it enters workspace.Vehicles rather than on the
-- first honk, so the asset is already loaded by the time anyone presses H -
-- a horn that arrives half a second late reads as the key not having worked.
local function setUpHorn(carModel)
	local chassis = carModel.PrimaryPart
	if not chassis then
		warn("VehicleHorn: " .. carModel:GetFullName() .. " has no PrimaryPart set - it will have no horn")
		return
	end
	if chassis:FindFirstChild(HORN_SOUND_NAME) then
		return
	end

	-- GetConfig, not the raw config file, so a per-instance HonkSoundId
	-- Attribute on this Chassis beats the car type's file, which in turn
	-- beats VehiclePhysics.Defaults - the same precedence every other tuning
	-- value in this game follows.
	local config = VehiclePhysics.GetConfig(chassis)
	local soundId = config.HonkSoundId
	if type(soundId) ~= "string" or soundId == "" then
		return -- a car can legitimately opt out of having a horn at all
	end

	local sound = Instance.new("Sound")
	sound.Name = HORN_SOUND_NAME
	sound.SoundId = soundId
	sound.Volume = config.HonkSoundVolume
	sound.RollOffMaxDistance = config.HonkSoundRollOffMaxDistance
	sound.Looped = true
	sound.Parent = chassis
end

local function trySetUpHorn(carModel)
	if not carModel:IsA("Model") then
		return
	end
	local ok, err = pcall(setUpHorn, carModel)
	if not ok then
		warn("VehicleHorn: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	trySetUpHorn(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetUpHorn)
VehicleFolder.ChildRemoved:Connect(function(carModel)
	hornHolders[carModel] = nil
	hornGenerations[carModel] = nil
end)

local function stopHorn(carModel)
	hornHolders[carModel] = nil
	hornGenerations[carModel] = (hornGenerations[carModel] or 0) + 1

	local chassis = carModel.PrimaryPart
	local sound = chassis and chassis:FindFirstChild(HORN_SOUND_NAME)
	if sound and sound:IsA("Sound") then
		sound:Stop()
	end
end

local function startHorn(carModel, player)
	local chassis = carModel.PrimaryPart
	local sound = chassis and chassis:FindFirstChild(HORN_SOUND_NAME)
	if not sound or not sound:IsA("Sound") then
		return
	end

	if hornHolders[carModel] == player then
		return -- already honking for this driver; key auto-repeat, or a duplicate message
	end

	hornHolders[carModel] = player
	local generation = (hornGenerations[carModel] or 0) + 1
	hornGenerations[carModel] = generation

	sound:Play()

	task.delay(MAX_HORN_SECONDS, function()
		if hornGenerations[carModel] == generation then
			stopHorn(carModel)
		end
	end)
end

remote.OnServerEvent:Connect(function(player, vehicle, active)
	if typeof(vehicle) ~= "Instance" or not vehicle:IsA("Model") or vehicle.Parent ~= VehicleFolder then
		return
	end

	if active == true then
		-- Same check as VehicleLightSwitches/VehicleNetworkState: only the
		-- player actually in this car's DriverSeat may speak for it. Without
		-- it any client could lay on any other car's horn from across the map.
		if VehicleSeats.GetDriverPlayer(vehicle) ~= player then
			return
		end
		startHorn(vehicle, player)
	elseif hornHolders[vehicle] == player then
		-- Stopping is gated on being the player who STARTED this honk, not on
		-- still being the driver. Pressing F to get out cuts the horn (the
		-- client sends a release as it tears its driving session down) and by
		-- then the seat is already empty, so a driver check here would reject
		-- exactly the message that matters most. Checking the holder instead
		-- is just as tight - it still means nobody can silence anyone else's
		-- horn, including a previous driver's late key-up landing after a
		-- seat swap.
		stopHorn(vehicle)
	end
end)

-- A driver who leaves the game never sends a key-up. MAX_HORN_SECONDS would
-- catch it eventually, but a horn that keeps blaring for ten seconds after
-- someone disconnects is exactly the kind of thing players notice.
Players.PlayerRemoving:Connect(function(player)
	for carModel, holder in hornHolders do
		if holder == player then
			stopHorn(carModel)
		end
	end
end)

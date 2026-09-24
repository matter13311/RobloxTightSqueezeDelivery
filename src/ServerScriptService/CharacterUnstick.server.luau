-- The last net under every way a player can end up inside a car.
--
-- Being inside one is always the tail end of a window in which the player and
-- the car were not solid to each other - a knockdown, a jump-exit, a lean on a
-- car that was still settling. Each of those windows has its own guard now (see
-- VehicleUnstick for the list and why they exist at all), and each of those
-- guards is a fix for the way IN. None of them is a fix for already being
-- there, and "already there" is the state the player actually complains about,
-- because Roblox's answer to a character overlapping solid geometry with no
-- short way out is to hold it exactly where it is. Under a truck, that means
-- respawning - losing the walk back, and the cargo condition, and the run.
--
-- So this watches for the state rather than for any of its causes: a player
-- who is not in a seat, whose HumanoidRootPart has been intersecting a car for
-- several seconds together, is stuck by definition - nobody stands inside a
-- truck on purpose - and gets put down on clear ground beside it.
--
-- Deliberately slow and deliberately blunt. It polls once a second, needs the
-- overlap to persist across several polls before it does anything, and when it
-- acts it teleports a few studs. All three are because the cost of acting when
-- the player was fine is far higher than the cost of taking an extra second to
-- act when they aren't.

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RagdollUtility = require(ReplicatedStorage.Modules.RagdollUtility)
local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)
local VehicleUnstick = require(ReplicatedStorage.Modules.Vehicles.VehicleUnstick)

local POLL_INTERVAL = 1
-- Consecutive polls the overlap has to survive. Comfortably longer than the
-- collision graces (0.5s and 0.75s) and than a jump-exit takes to clear the
-- doorway, so a player passing legitimately through a car's volume is never
-- picked up by this.
local POLLS_BEFORE_ACTING = 3

-- [Player] = { Character = the character those polls were about, Polls = n }.
-- Keyed by player and carrying the character, so a respawn starts the count
-- again from zero rather than inheriting the dead body's tally.
local stuck = {}

local function shouldCheck(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	-- A seated player is inside a car because they are IN it.
	if humanoid.SeatPart then
		return false
	end
	-- A ragdoll under a car is VehiclePlayerImpact's recovery timer's problem,
	-- and that one already moves them clear before standing them up. Two
	-- systems teleporting the same body on their own schedules would fight.
	if RagdollUtility.IsRagdolled(character) then
		return false
	end
	return true
end

local function poll()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character or not character.Parent or not shouldCheck(character) then
			stuck[player] = nil
			continue
		end

		local car = VehicleUnstick.FindOverlappingVehicle(character, 0)
		if not car then
			stuck[player] = nil
			continue
		end

		local entry = stuck[player]
		if not entry or entry.Character ~= character then
			entry = { Character = character, Polls = 0 }
			stuck[player] = entry
		end
		entry.Polls += 1
		if entry.Polls < POLLS_BEFORE_ACTING then
			continue
		end

		stuck[player] = nil
		if VehicleUnstick.MoveClear(character, car) then
			if VehicleCollision.DebugLogging then
				print(("[Unstick] moved %s out of %s"):format(player.Name, car.Name))
			end
		end
	end
end

Players.PlayerRemoving:Connect(function(player)
	stuck[player] = nil
end)

task.spawn(function()
	while true do
		task.wait(POLL_INTERVAL)
		local ok, err = pcall(poll)
		if not ok then
			warn("CharacterUnstick: " .. tostring(err))
		end
	end
end)

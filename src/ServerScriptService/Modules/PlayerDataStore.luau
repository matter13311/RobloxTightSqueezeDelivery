-- Persistent per-player save data: money, which vehicles are owned, which
-- vehicle is selected, and - the grindy part - which upgrade level has been
-- bought for every stat of every owned car, plus wherever the player last
-- dragged that car's sliders to. PlotManager.server.luau is the only caller;
-- this module knows nothing about plots, spawning or remotes, only the data
-- and how to get it in and out of a DataStore.
--
-- Server-authoritative and the only writer: the client never sees this
-- table directly, only whatever GetPlotData chooses to hand back.
--
-- Shape (all fields always present after Load - see Reconcile):
--   {
--     Money = number,
--     OwnedVehicleIds = { [vehicleId] = true },
--     SelectedVehicleId = string,
--     UpgradeLevels = { [vehicleId] = { [statName] = number } },
--     CarConfigs = { [vehicleId] = { [statName] = number } }, -- slider values, always <= UpgradeLevels' unlocked notch
--   }

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCatalog = require(ReplicatedStorage.Modules.Vehicles.VehicleCatalog)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleUpgrades = require(ReplicatedStorage.Modules.Vehicles.VehicleUpgrades)

local PlayerDataStore = {}

-- Bump this if the shape of the saved table ever changes in a way old saves
-- can't just be reconciled into (see Reconcile below for the kind of change
-- that DOESN'T need a bump - adding a new vehicle/stat reconciles for free).
local DATASTORE_NAME = "PlayerData_v1"
local store = DataStoreService:GetDataStore(DATASTORE_NAME)

local RETRY_ATTEMPTS = 3
local RETRY_BACKOFF = 1 -- seconds, doubles each attempt

local function withRetries(fn)
	local lastErr = nil
	for attempt = 1, RETRY_ATTEMPTS do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		if attempt < RETRY_ATTEMPTS then
			task.wait(RETRY_BACKOFF * attempt)
		end
	end
	return false, lastErr
end

-- DataStores reject NaN and infinity outright (they can't be encoded as
-- JSON), and a single poisoned number is enough to fail the whole SetAsync -
-- taking every other field down with it. PlotManager's AwardMoney already
-- refuses a NaN payout, so this is the second line of defence for a value
-- that got there some other way (an older build, a bad manual edit) rather
-- than a duplicate of that check: nothing that can't be written should be
-- able to sit in the table waiting to fail at save time.
local function sanitizeMoney(value)
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return math.max(0, math.floor(value))
end

local function newDefaultData()
	return {
		Money = 0,
		OwnedVehicleIds = VehicleCatalog.DefaultOwnedIds(),
		SelectedVehicleId = VehicleCatalog.Order[1],
		UpgradeLevels = {},
		CarConfigs = {},
	}
end

-- Fills in anything a saved table is missing - a brand new vehicle added to
-- the catalog after a player last saved, a brand new upgrade stat added to a
-- car they already own, or (for a player with no save at all) the whole
-- table. Also clamps every saved upgrade level/config value against the
-- CURRENT spec, so a spec tightened after the player bought into it (Max
-- lowered, Step changed) can never leave them holding an out-of-range value.
local function reconcile(data)
	data = data or {}
	data.Money = sanitizeMoney(data.Money)
	data.OwnedVehicleIds = type(data.OwnedVehicleIds) == "table" and data.OwnedVehicleIds or {}
	data.UpgradeLevels = type(data.UpgradeLevels) == "table" and data.UpgradeLevels or {}
	data.CarConfigs = type(data.CarConfigs) == "table" and data.CarConfigs or {}

	-- Drop anything the catalog no longer knows about, BEFORE the checks
	-- below start trusting these ids. A vehicle id is only ever as stable as
	-- the catalog entry it names, and renaming one (StarterTruck ->
	-- StarterVehicle) leaves every existing save holding a dead id: owned,
	-- selected, and impossible to look up. Without this the save reconciles
	-- "successfully", SelectedVehicleId passes the owned-check right below
	-- (it IS still in OwnedVehicleIds), and the failure surfaces much later
	-- and much less clearly as PlotManager's "tried to spawn an
	-- unowned/unknown vehicle" the first time the player presses spawn.
	--
	-- Values are normalised to `true` at the same time, so a save that came
	-- back with something else in there can't make an ownership check pass
	-- (or fail) in a way the rest of the code doesn't expect.
	for id, owned in data.OwnedVehicleIds do
		if owned and VehicleCatalog.Get(id) then
			data.OwnedVehicleIds[id] = true
		else
			data.OwnedVehicleIds[id] = nil
		end
	end

	-- Every player owns whatever the catalog currently marks DefaultOwned,
	-- even if that flag was added after they first played.
	for id in VehicleCatalog.DefaultOwnedIds() do
		data.OwnedVehicleIds[id] = true
	end

	-- Same pruning for the two per-vehicle tables. These are keyed by
	-- vehicle id too, so they accumulate a dead entry for every renamed or
	-- removed car and carry it in the save forever - and, unlike
	-- OwnedVehicleIds, nothing downstream would ever notice.
	for _, byVehicle in { data.UpgradeLevels, data.CarConfigs } do
		for id, values in byVehicle do
			if not data.OwnedVehicleIds[id] or type(values) ~= "table" then
				byVehicle[id] = nil
			end
		end
	end

	if type(data.SelectedVehicleId) ~= "string" or not data.OwnedVehicleIds[data.SelectedVehicleId] then
		data.SelectedVehicleId = VehicleCatalog.Order[1]
	end

	for vehicleId in data.OwnedVehicleIds do
		local def = VehicleCatalog.Get(vehicleId)
		local specs = def and VehiclePhysics.GetUpgradeSpecs(def.TemplateName)
		if specs then
			local levels = data.UpgradeLevels[vehicleId]
			if type(levels) ~= "table" then
				levels = {}
				data.UpgradeLevels[vehicleId] = levels
			end
			local configValues = data.CarConfigs[vehicleId]
			if type(configValues) ~= "table" then
				configValues = {}
				data.CarConfigs[vehicleId] = configValues
			end

			for statName, spec in specs do
				local level = VehicleUpgrades.ClampLevel(spec, type(levels[statName]) == "number" and levels[statName] or 0)
				levels[statName] = level

				local value = configValues[statName]
				if type(value) ~= "number" then
					value = spec.Min -- never configured before - starts parked at the free default
				end
				configValues[statName] = VehicleUpgrades.NearestUnlockedValue(spec, level, value)
			end
		end
	end

	return data
end

-- [userId] = true for a player whose data actually came back from the
-- DataStore (including the legitimate "no save yet, here are the defaults"
-- answer). Anyone NOT in here is running on fallback defaults because the
-- read failed, and Save below refuses to write for them - see why there.
local loadSucceeded = {}

-- Always returns a usable table, even if the DataStore call itself failed -
-- falling back to defaults (rather than e.g. kicking the player) keeps the
-- game playable through a DataStore outage. What it must NOT do is let that
-- fallback be written back, which is what Save guards against.
function PlayerDataStore.Load(player)
	local ok, result = withRetries(function()
		return store:GetAsync("Player_" .. player.UserId)
	end)

	if not ok then
		loadSucceeded[player.UserId] = nil
		warn(
			"PlayerDataStore: failed to load data for "
				.. player.Name
				.. " after "
				.. RETRY_ATTEMPTS
				.. " attempts ("
				.. tostring(result)
				.. ") - starting them fresh this session. Their real progress is left untouched: "
				.. "no save will be written for them for the rest of this session."
		)
		return newDefaultData()
	end

	loadSucceeded[player.UserId] = true
	return reconcile(result)
end

-- Refuses to write when this player's Load failed. That case is the single
-- most destructive thing this module can do: the player is sitting on a
-- default table that only LOOKS like a save, and writing it wipes however
-- many hours of real progress the read couldn't reach. A player who plays a
-- session on defaults and loses it is annoyed; a player whose actual save is
-- overwritten by those defaults is gone.
--
-- Deliberately NOT symmetrical with Load's forgiving fallback: a failed read
-- is recoverable next join, a bad write is not recoverable at all.
function PlayerDataStore.Save(player, data)
	if not loadSucceeded[player.UserId] then
		warn(
			"PlayerDataStore: refusing to save "
				.. player.Name
				.. " - their data never loaded this session, so this table is defaults, not progress."
		)
		return false
	end
	if type(data) ~= "table" then
		warn("PlayerDataStore: refusing to save " .. player.Name .. " - data is not a table")
		return false
	end

	-- Sanitized on the way out as well as on the way in: Money is the one
	-- field other scripts write to between Load and Save (see PlotManager's
	-- setMoney / AwardMoney), so it's the only one that can have gone bad
	-- since reconcile last saw it.
	data.Money = sanitizeMoney(data.Money)

	local ok, err = withRetries(function()
		store:SetAsync("Player_" .. player.UserId, data)
	end)
	if not ok then
		warn("PlayerDataStore: failed to save data for " .. player.Name .. ": " .. tostring(err))
	end
	return ok
end

-- Called by PlotManager when a player leaves, once their final save is done.
-- Without this, loadSucceeded would grow by one entry per player for the
-- lifetime of the server, and a rejoining player would inherit the previous
-- visit's verdict instead of their new Load's.
function PlayerDataStore.Release(player)
	loadSucceeded[player.UserId] = nil
end

return PlayerDataStore

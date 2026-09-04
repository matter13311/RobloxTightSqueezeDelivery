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
	data.Money = type(data.Money) == "number" and data.Money or 0
	data.OwnedVehicleIds = type(data.OwnedVehicleIds) == "table" and data.OwnedVehicleIds or {}
	data.UpgradeLevels = type(data.UpgradeLevels) == "table" and data.UpgradeLevels or {}
	data.CarConfigs = type(data.CarConfigs) == "table" and data.CarConfigs or {}

	-- Every player owns whatever the catalog currently marks DefaultOwned,
	-- even if that flag was added after they first played.
	for id in VehicleCatalog.DefaultOwnedIds() do
		data.OwnedVehicleIds[id] = true
	end

	if type(data.SelectedVehicleId) ~= "string" or not data.OwnedVehicleIds[data.SelectedVehicleId] then
		data.SelectedVehicleId = VehicleCatalog.Order[1]
	end

	for vehicleId in data.OwnedVehicleIds do
		local def = VehicleCatalog.Get(vehicleId)
		local rawConfig = def and VehiclePhysics.GetRawConfig(def.TemplateName)
		local specs = rawConfig and rawConfig.Upgrades
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

-- Always returns a usable table, even if the DataStore call itself failed -
-- see the warn below for why silently falling back to defaults (rather than
-- e.g. kicking the player) is the right call here.
function PlayerDataStore.Load(player)
	local ok, result = withRetries(function()
		return store:GetAsync("Player_" .. player.UserId)
	end)

	if not ok then
		warn(
			"PlayerDataStore: failed to load data for "
				.. player.Name
				.. " after "
				.. RETRY_ATTEMPTS
				.. " attempts ("
				.. tostring(result)
				.. ") - starting them fresh this session. Nothing will be SAVED over their real "
				.. "progress unless a later save this session succeeds, but they will see defaults until then."
		)
		return newDefaultData()
	end

	return reconcile(result)
end

function PlayerDataStore.Save(player, data)
	local ok, err = withRetries(function()
		store:SetAsync("Player_" .. player.UserId, data)
	end)
	if not ok then
		warn("PlayerDataStore: failed to save data for " .. player.Name .. ": " .. tostring(err))
	end
	return ok
end

return PlayerDataStore

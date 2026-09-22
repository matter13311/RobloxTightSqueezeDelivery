-- Every vehicle a player can own/spawn from their plot terminal. This is the
-- foundation the shop tab (PlotTerminal.client.luau) and PlotManager's
-- spawning logic both read from.
--
-- `TemplateName` names a Model that must exist under
-- ServerStorage.VehicleTemplates for that vehicle to be spawnable - see the
-- warning PlotManager.server.luau logs if one is missing. Nothing else about
-- a vehicle (welding, wheels, collision, doors) is configured here; once
-- cloned into workspace.Vehicles it's picked up by the same pipeline every
-- hand-placed car already goes through (Raycast.server.luau,
-- VehicleCollisionSetup.server.luau, etc).
--
-- There are no thumbnails: the garage shows every vehicle as a live model
-- parked in the player's bay (GarageStage.luau, fed by VehiclePreviews.server
-- .luau), so a new car needs nothing here beyond its template.
--
-- `RequiredDeliveries` is the second half of a vehicle's price. Money alone is
-- a weak gate in a game where money is the reward for driving - a player can
-- grind an afternoon and buy everything - whereas lifetime deliveries can only
-- be paid in the one currency the game actually wants spent, and cannot be
-- handed over in a lump.
--
-- Stated in deliveries rather than in a level, because deliveries is the only
-- progression number the game has (see ProgressionConfig's header) and because
-- the player is already counting them. A locked card is still SHOWN in the
-- shop, greyed out with the figure it needs; hiding it would make the ladder
-- invisible to exactly the players it is meant to pull along. nil or 0 means no
-- requirement.

local VehicleCatalog = {}

VehicleCatalog.Vehicles = {
	StarterVehicle = {
		Id = "StarterVehicle",
		DisplayName = "Starter Vehicle",
		TemplateName = "StarterVehicle",
		Price = 0,
		RequiredDeliveries = 0, -- the car you start in; gating it would lock a new player out of the game
		DefaultOwned = true, -- every player starts owning this one, no purchase needed
	},
	PickupTruck = {
		Id = "PickupTruck",
		DisplayName = "Pickup Truck",
		TemplateName = "PickupTruck",
		-- Placeholder - adjust to taste.
		Price = 5000,
		-- Twenty deliveries is roughly an hour of play, and it is deliberately
		-- the SAME figure as the first contract-slot milestone
		-- (ProgressionConfig.Contracts.CapMilestones) so the two rewards land
		-- together: the twentieth delivery is an event rather than a number
		-- ticking over.
		RequiredDeliveries = 20,
		DefaultOwned = false, -- purchasable from the shop tab instead
	},
	BoxTruck = {
		Id = "BoxTruck",
		DisplayName = "Box Truck",
		TemplateName = "BoxTruck", -- must exist under ServerStorage.VehicleTemplates
		-- The next tier up from PickupTruck, so priced/gated higher.
		-- ~2x what a typical player has earned by the delivery gate below,
		-- the same ratio as PickupTruck's $5,000 at 20.
		Price = 1, --default 15,000
		-- 75 is the next CapMilestones step up from PickupTruck's 20 (see
		-- ProgressionConfig.Contracts.CapMilestones), so this vehicle lands
		-- alongside that milestone's own reward the same way PickupTruck lines
		-- up with the 20 milestone.
		RequiredDeliveries = 1, --default 75
		DefaultOwned = false, -- purchasable from the shop tab instead
	},
	StraightTruck = {
		Id = "StraightTruck",
		DisplayName = "Straight Truck",
		TemplateName = "StraightTruck", -- must exist under ServerStorage.VehicleTemplates
		-- Placeholder - adjust to taste. The tier above BoxTruck.
		Price = 1000, --default 40,000
		-- 200 is the next CapMilestones step up from BoxTruck's 75 (see
		-- ProgressionConfig.Contracts.CapMilestones), same pairing as the
		-- vehicles before it.
		RequiredDeliveries = 20, --default 200
		DefaultOwned = false, -- purchasable from the shop tab instead
	},
	AmericanHitchTruck = {
		Id = "AmericanHitchTruck",
		DisplayName = "American Hitch Truck",
		TemplateName = "AmericanHitchTruck", -- must exist under ServerStorage.VehicleTemplates
		-- Placeholder - adjust to taste. The top of the ladder, above StraightTruck.
		Price = 1, --default 100,000
		-- 450 is the next CapMilestones step up from StraightTruck's 200 (see
		-- ProgressionConfig.Contracts.CapMilestones), same pairing as the
		-- vehicles before it.
		RequiredDeliveries = 1, --default 450
		DefaultOwned = false, -- purchasable from the shop tab instead
	},
}

-- Stable display order (table iteration order is unspecified in Lua).
-- StarterVehicle first: VehicleCatalog.Order[1] is what PlayerDataStore
-- assigns as a fresh player's SelectedVehicleId.
VehicleCatalog.Order = { "StarterVehicle", "PickupTruck", "BoxTruck", "StraightTruck", "AmericanHitchTruck" }

function VehicleCatalog.Get(vehicleId)
	return VehicleCatalog.Vehicles[vehicleId]
end

-- The lifetime deliveries a vehicle needs, normalised. Shared so the shop's
-- grey-out and PlotManager's purchase check can never disagree about what
-- "unlocked" means - the same split VehicleOwnership.CanEnter exists for.
function VehicleCatalog.RequiredDeliveries(vehicleDef)
	local required = vehicleDef and vehicleDef.RequiredDeliveries
	return if type(required) == "number" and required > 0 then math.floor(required) else 0
end

function VehicleCatalog.DefaultOwnedIds()
	local owned = {}
	for _, id in VehicleCatalog.Order do
		if VehicleCatalog.Vehicles[id].DefaultOwned then
			owned[id] = true
		end
	end
	return owned
end

return VehicleCatalog

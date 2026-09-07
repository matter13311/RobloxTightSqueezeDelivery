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
-- `ImageId` is nil/"" until a thumbnail is uploaded - PlotTerminal.client.luau
-- renders an "Image Coming Soon" placeholder in its place rather than a blank
-- image, so it's fine to leave unset for a vehicle still in progress.
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
		ImageId = "rbxassetid://125430916118158", -- no thumbnail rendered yet
		Price = 0,
		RequiredDeliveries = 0, -- the car you start in; gating it would lock a new player out of the game
		DefaultOwned = true, -- every player starts owning this one, no purchase needed
	},
	PickupTruck = {
		Id = "PickupTruck",
		DisplayName = "Pickup Truck",
		TemplateName = "PickupTruck",
		-- Thumbnail rendered from the photo-display build (see
		-- tools/BuildPhotoDisplayCar_CommandBar.luau) and uploaded as a Decal/
		-- Image asset - shown large in the garage carousel and as the card
		-- image in the shop grid (see PlotTerminal.client.luau).
		ImageId = "rbxassetid://111532050787860",
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
}

-- Stable display order (table iteration order is unspecified in Lua).
-- StarterVehicle first: VehicleCatalog.Order[1] is what PlayerDataStore
-- assigns as a fresh player's SelectedVehicleId.
VehicleCatalog.Order = { "StarterVehicle", "PickupTruck" }

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

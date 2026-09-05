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

local VehicleCatalog = {}

VehicleCatalog.Vehicles = {
	StarterVehicle = {
		Id = "StarterVehicle",
		DisplayName = "Starter Vehicle",
		TemplateName = "StarterVehicle",
		ImageId = nil, -- no thumbnail rendered yet
		Price = 0,
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

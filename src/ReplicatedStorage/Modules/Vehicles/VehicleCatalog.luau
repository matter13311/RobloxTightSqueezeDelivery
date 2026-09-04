-- Every vehicle a player can own/spawn from their plot terminal. This is the
-- foundation the shop tab (PlotTerminal.client.luau) and PlotManager's
-- spawning logic both read from - for now it lists just the free starter car;
-- add more entries here (with a Price > 0) once the shop actually sells
-- anything.
--
-- `TemplateName` names a Model that must exist under
-- ServerStorage.VehicleTemplates for that vehicle to be spawnable - see the
-- warning PlotManager.server.luau logs if one is missing. Nothing else about
-- a vehicle (welding, wheels, collision, doors) is configured here; once
-- cloned into workspace.Vehicles it's picked up by the same pipeline every
-- hand-placed car already goes through (Raycast.server.luau,
-- VehicleCollisionSetup.server.luau, etc).

local VehicleCatalog = {}

VehicleCatalog.Vehicles = {
	StarterCar = {
		Id = "StarterCar",
		DisplayName = "Starter Car",
		TemplateName = "StarterCar",
		Price = 0,
		DefaultOwned = true, -- every player starts owning this one, no purchase needed
	},
}

-- Stable display order (table iteration order is unspecified in Lua).
VehicleCatalog.Order = { "StarterCar" }

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

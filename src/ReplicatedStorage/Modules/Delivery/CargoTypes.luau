-- What a crate can BE. One entry per kind of goods a contract can ask for,
-- and the only place their appearance and worth are described.
--
-- Crates are built procedurally from these numbers rather than cloned from a
-- Studio model, on purpose: it means cargo works the moment this file syncs,
-- with nothing to place by hand, and a new goods type is a table entry rather
-- than a modelling job. Set `TemplateName` on a type once a real model exists
-- for it and CargoManager will clone that instead - see its buildCrate.
--
-- Fragility is the one number that connects a type to the crash pipeline: it
-- scales how much of an impact's severity lands on cargo condition, so glass
-- is punishing to carry over kerbs and gravel effectively is not. It does NOT
-- change handling - that comes from mass alone (see CargoLoad).

local CargoTypes = {}

-- Every field is required on every type; there is no defaults/merge tier here
-- the way VehiclePhysics has one, because a goods type with a missing value
-- has no sensible fallback (what should an unstated ValuePerUnit be?) and a
-- silently-zero-value crate would be a long debugging session.
CargoTypes.Types = {
	Parcels = {
		Id = "Parcels",
		DisplayName = "Parcels",
		-- Money per crate delivered intact, before every delivery-side
		-- multiplier (park grade, distance) is applied by DeliveryManager.
		ValuePerUnit = 35,
		-- 1 is the baseline. Higher means impacts hurt cargo condition more.
		Fragility = 1,
		-- Multiplies CargoMassFractionPerUnit for this type, so a crate of
		-- bricks weighs more than a crate of cushions without either one
		-- needing its own mass field in studs.
		MassMultiplier = 1,
		CrateSize = Vector3.new(2.6, 2.4, 2.6),
		Color = Color3.fromRGB(174, 133, 86),
		Material = Enum.Material.Cardboard,
	},

	Produce = {
		Id = "Produce",
		DisplayName = "Fresh Produce",
		ValuePerUnit = 55,
		Fragility = 1.6, -- bruises: the cheap way into "drive smoothly" contracts
		MassMultiplier = 1.15,
		CrateSize = Vector3.new(2.8, 2.0, 2.8),
		Color = Color3.fromRGB(126, 156, 86),
		Material = Enum.Material.WoodPlanks,
	},

	Glassware = {
		Id = "Glassware",
		DisplayName = "Glassware",
		ValuePerUnit = 110,
		-- The high-risk contract: pays triple Parcels and punishes a single
		-- kerb strike. This is the type the reverse-park bonus is worth
		-- chasing on.
		Fragility = 3.2,
		MassMultiplier = 0.9,
		CrateSize = Vector3.new(2.4, 2.6, 2.4),
		Color = Color3.fromRGB(196, 216, 224),
		Material = Enum.Material.Glass,
	},

	Aggregate = {
		Id = "Aggregate",
		DisplayName = "Sand & Gravel",
		-- Cheap per crate, but nearly unbreakable and very heavy - so its
		-- difficulty is entirely handling, not care. The mirror image of
		-- Glassware, which is what makes both worth having.
		ValuePerUnit = 25,
		Fragility = 0.25,
		MassMultiplier = 2.1,
		CrateSize = Vector3.new(2.8, 1.8, 2.8),
		Color = Color3.fromRGB(120, 116, 108),
		Material = Enum.Material.Slate,
	},
}

-- Stable display order (table iteration order is unspecified in Lua) - same
-- reason VehicleCatalog.Order exists.
CargoTypes.Order = { "Parcels", "Produce", "Glassware", "Aggregate" }

CargoTypes.DefaultTypeId = "Parcels"

function CargoTypes.Get(typeId)
	return CargoTypes.Types[typeId]
end

-- Never returns nil: an unknown id (an old save, a renamed type, a client
-- sending nonsense) falls back to the default rather than erroring deep inside
-- a physics or payout calculation where the real cause would be invisible.
function CargoTypes.GetOrDefault(typeId)
	return CargoTypes.Types[typeId] or CargoTypes.Types[CargoTypes.DefaultTypeId]
end

return CargoTypes

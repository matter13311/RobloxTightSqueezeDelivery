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
--
-- HOW A TYPE IS PRICED. ValuePerUnit follows one rule, and a new type has to
-- follow it too or the board stops making sense:
--
--     value ~= 32 * MassMultiplier^1.3 * (1 + 0.25 * (Fragility - 1))
--                                        ...with that last term floored at 0.85
--
-- MASS IS THE LEADING TERM, and that is the deliberate half. It used to be the
-- opposite: Aggregate was the heaviest thing in the game and paid 25 a crate
-- while Glassware paid 110, so the most valuable run was the one that barely
-- touched the truck's handling and the punishing one paid worst. Since a bed
-- holds N CRATES regardless of what is in them, that made "heavy" a pure
-- downside - worse braking, worse cornering, less money - and no player who
-- noticed would ever take it.
--
-- Weight is the difficulty this game is actually about (it is called Tight
-- Squeeze), so weight is what pays. Fragility is a premium ON TOP, not the main
-- event: it buys Glassware a real risk margin without letting a feather-light
-- load out-earn a full bed of gravel.
--
-- Where the current four land, per crate:
--
--     type        mass   fragility   rule says   pays
--     Parcels     1.00   1.00           32         32   the baseline both scales are set from
--     Produce     1.15   1.60           44         44
--     Glassware   1.40   3.20           77         74   heavy AND fragile - the hard one
--     Aggregate   2.10   0.25           71         80   heaviest, so it pays most
--
-- The rule is a starting point, not a law, and the top two are nudged off it on
-- purpose. Left at 77 and 71 the fragility premium would have carried Glassware
-- past Aggregate, and "the lighter load pays more" is the exact thing this
-- pricing exists to stop - so the two were pushed apart until pay rose with
-- mass across all four. THAT is the property to preserve when adding a type or
-- re-tuning one; the formula is just how to get close before checking it.

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
		ValuePerUnit = 32,
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
		ValuePerUnit = 44,
		Fragility = 1.6, -- bruises: the cheap way into "drive smoothly" contracts
		MassMultiplier = 1.15,
		CrateSize = Vector3.new(2.8, 2.0, 2.8),
		Color = Color3.fromRGB(126, 156, 86),
		Material = Enum.Material.WoodPlanks,
	},

	Glassware = {
		Id = "Glassware",
		DisplayName = "Glassware",
		ValuePerUnit = 74,
		-- The hard one, and the only type that is difficult on BOTH axes:
		-- heavy enough to change how the truck stops, and wrecked by a single
		-- kerb strike. It pays more than twice Parcels for that, and it is the
		-- type the careful-parking bonus is actually worth chasing on.
		Fragility = 3.2,
		MassMultiplier = 1.4,
		CrateSize = Vector3.new(2.4, 2.6, 2.4),
		Color = Color3.fromRGB(196, 216, 224),
		Material = Enum.Material.Glass,
	},

	Aggregate = {
		Id = "Aggregate",
		DisplayName = "Sand & Gravel",
		-- The best-paying crate in the game, and nearly unbreakable with it -
		-- because it is also by far the heaviest, so its difficulty is entirely
		-- in driving a loaded truck rather than in driving a gentle one. The
		-- mirror image of Glassware, which is what makes both worth having: one
		-- job punishes a heavy foot, the other punishes a heavy landing.
		ValuePerUnit = 80,
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

--=============================================================================
-- How the board TALKS about fragility
--=============================================================================

-- Fragility as a word, because the raw number is unreadable to the person it
-- was being shown to. The board used to print "fragility 0.25" and "fragility
-- 3.20" next to each other, which asks the player to know that the scale runs
-- upward, that 1 is the middle of it, and that neither end is bounded - three
-- things nothing in the game has ever told them. A player seeing 0.25 has no
-- way to know whether that is the safe end or the dangerous one.
--
-- Banded for the same reason DeliveryConfig bands weight: the player is
-- choosing between jobs in a truck, not reading a spec sheet. Same four-band
-- shape and same Id/Label split, so renaming a label never silently drops its
-- colour on the client.
--
-- Ordered most-fragile first; the first band whose Above the value clears wins.
CargoTypes.CareBands = {
	{ Id = "Fragile", Label = "Fragile", Above = 2.2 },
	{ Id = "Delicate", Label = "Delicate", Above = 1.3 },
	{ Id = "Sturdy", Label = "Sturdy", Above = 0.6 },
	{ Id = "Tough", Label = "Tough", Above = -math.huge },
}

function CargoTypes.CareBand(fragility)
	if type(fragility) ~= "number" or fragility ~= fragility then
		fragility = 1
	end
	for _, band in CargoTypes.CareBands do
		if fragility > band.Above then
			return band
		end
	end
	return CargoTypes.CareBands[#CargoTypes.CareBands]
end

return CargoTypes

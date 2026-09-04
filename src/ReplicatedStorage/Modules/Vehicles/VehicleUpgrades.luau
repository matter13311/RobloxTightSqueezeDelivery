-- The math behind the per-car upgrade ladder. Shared between the server
-- (PlayerDataStore.luau validates purchases and clamps saved values against
-- this) and the client (PlotTerminal.client.luau draws sliders from it) so
-- both sides agree on what a given level means without either one trusting
-- the other's arithmetic.
--
-- A stat's spec (see any Configs/<Name>.luau's Upgrades table) looks like:
--   { Min = 25, Max = 50, Step = 5, BaseCost = 150, CostGrowth = 1.5 }
-- Min is level 0 - the value every fresh car already has, free. Level N's
-- value is Min + Step*N, and level N tops out at Max. Buying the Nth level
-- (going from N-1 to N) costs BaseCost * CostGrowth^(N-1), rounded, so each
-- purchase costs more than the last - the "grindy" part.

local VehicleUpgrades = {}

-- How many levels exist above the free level-0 default, rounded because
-- float division of two config numbers (e.g. 0.20 / 0.05) can land a hair off
-- an integer.
function VehicleUpgrades.MaxLevel(spec)
	return math.round((spec.Max - spec.Min) / spec.Step)
end

function VehicleUpgrades.ClampLevel(spec, level)
	return math.clamp(math.floor(level + 0.5), 0, VehicleUpgrades.MaxLevel(spec))
end

function VehicleUpgrades.ValueAtLevel(spec, level)
	return spec.Min + spec.Step * VehicleUpgrades.ClampLevel(spec, level)
end

-- Cost to buy level `level` (i.e. to go from level-1 to level). Level 0 is
-- free and never purchased, so this is only meaningful for level >= 1.
function VehicleUpgrades.CostForLevel(spec, level)
	return math.round(spec.BaseCost * (spec.CostGrowth ^ (level - 1)))
end

-- Nearest unlocked notch to an arbitrary value (e.g. wherever the player
-- dropped a dragged slider) - used to snap client input, and to reject a
-- value server-side that doesn't correspond to any notch the player has
-- actually unlocked.
function VehicleUpgrades.NearestUnlockedValue(spec, unlockedLevel, value)
	local level = math.clamp(math.round((value - spec.Min) / spec.Step), 0, VehicleUpgrades.ClampLevel(spec, unlockedLevel))
	return VehicleUpgrades.ValueAtLevel(spec, level)
end

return VehicleUpgrades

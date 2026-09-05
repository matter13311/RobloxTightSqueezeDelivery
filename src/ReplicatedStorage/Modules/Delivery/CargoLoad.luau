-- The math behind carrying a load: how much mass it adds, how much worse the
-- truck handles for it, and what it is worth. Shared deliberately, the same
-- way VehicleUpgrades is - CargoManager.server.luau is the authority on what
-- is actually loaded, VehiclePhysics.Step reads the handling penalty every
-- frame, and the loading-dock UI shows the player the numbers - and all three
-- have to agree without any of them trusting the others' arithmetic.
--
-- WHY THERE IS A HANDLING PENALTY AT ALL, when we also add real mass:
--
-- Because in VehiclePhysics, mass cancels out of exactly the two effects that
-- would make a heavy load frightening. Braking goes through
-- frictionStopImpulse, where the impulse cap is `coefficient * (mass/4) * g`
-- and the impulse needed is `v.Z * (mass/4)` - mass on both sides, so
-- deceleration is `coefficient * gravity` no matter what the truck weighs.
-- Lateral grip is built the same way. Adding mass therefore gives us, for
-- free: suspension sag (the spring force is NOT mass-scaled), sluggish
-- acceleration (neither is drive force), a raised centre of mass, and
-- collision inertia - but a fully loaded truck would still stop and corner
-- exactly like an empty one.
--
-- So the stopping distance and the grip loss are applied explicitly, here.
-- That is not a fudge: a real loaded truck stops worse precisely because tire
-- friction does not scale linearly with load.
--
-- See docs/CargoDesign.md for the whole picture.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CargoTypes = require(ReplicatedStorage.Modules.Delivery.CargoTypes)

local CargoLoad = {}

--=============================================================================
-- Attribute names
--=============================================================================

-- All of these live on the vehicle MODEL, not the Chassis - matching
-- VehicleOwnership's OwnerUserId, and for the same reason: an attribute
-- replicates on its own, so the server writes it once and every client that
-- needs it (the driver's physics loop, a HUD, a bystander's crate visuals)
-- reads the same value with no remote in between.
CargoLoad.Attributes = {
	-- number, 0-1. The only one VehiclePhysics reads.
	LoadFraction = "CargoLoadFraction",
	-- number of crates currently aboard.
	Units = "CargoUnits",
	-- string, a CargoTypes id.
	TypeId = "CargoTypeId",
	-- number, 0-1. 1 = pristine. Drops on impacts, never recovers in transit.
	Condition = "CargoCondition",
	-- number. The vehicle's AssemblyMass with nothing loaded, measured once
	-- and cached (see CargoManager) because you cannot measure it again once
	-- the ballast is in the assembly.
	EmptyMass = "CargoEmptyMass",
}

--=============================================================================
-- Load
--=============================================================================

function CargoLoad.Capacity(config)
	-- math.floor, not round: capacity is a count of crate slots, and a config
	-- that has drifted to 5.9 through an upgrade Step should mean five slots,
	-- never six that the bed has no room to lay out.
	return math.max(0, math.floor(config.CargoCapacity or 0))
end

function CargoLoad.ClampUnits(config, units)
	if type(units) ~= "number" or units ~= units then -- NaN never equals itself
		return 0
	end
	return math.clamp(math.floor(units), 0, CargoLoad.Capacity(config))
end

-- 0-1. A truck with zero capacity reads as empty rather than dividing by zero.
function CargoLoad.LoadFraction(config, units)
	local capacity = CargoLoad.Capacity(config)
	if capacity <= 0 then
		return 0
	end
	return CargoLoad.ClampUnits(config, units) / capacity
end

-- Mass to add to the assembly, in Roblox mass units.
--
-- Expressed as a fraction of the truck's own empty mass rather than an
-- absolute number, so "a full load roughly doubles the truck" stays true for
-- every vehicle in the catalog - and stays true after somebody resizes a
-- chassis part in Studio, which silently changes its mass and would quietly
-- rebalance every absolute figure we could have written instead.
function CargoLoad.AddedMass(config, emptyMass, units, typeId)
	local cargoType = CargoTypes.GetOrDefault(typeId)
	local perUnit = (config.CargoMassFractionPerUnit or 0) * cargoType.MassMultiplier
	return math.max(0, emptyMass) * perUnit * CargoLoad.ClampUnits(config, units)
end

--=============================================================================
-- Handling
--=============================================================================

local function lerp(from, to, alpha)
	return from + (to - from) * alpha
end

-- The multipliers VehiclePhysics.Step applies to BrakeFriction and to the
-- lateral grip coefficients, at a given load. Both are 1 when empty and reach
-- their configured loaded value at 100% load, interpolated linearly in
-- between - linear because the player is choosing a crate count on a slider
-- and needs "one more crate" to feel like a consistent amount worse.
--
-- Returns multipliers rather than final values so the caller keeps ownership
-- of its own config, and so this stays testable with no vehicle present.
function CargoLoad.HandlingAt(config, loadFraction)
	local alpha = math.clamp(loadFraction or 0, 0, 1)
	return {
		-- < 1 means longer stopping distance. Deceleration is
		-- BrakeFriction * gravity, so 0.7 here is a 43% longer stop.
		Brake = lerp(1, config.CargoLoadedBrakeMultiplier or 1, alpha),
		-- < 1 means the tires break away sooner in a corner. Combined with
		-- the raised centre of mass from where the ballast sits, this is what
		-- makes a full load feel like it wants to keep going straight.
		Grip = lerp(1, config.CargoLoadedGripMultiplier or 1, alpha),
	}
end

-- Convenience for the two call sites in VehiclePhysics.Step, which have a
-- carModel in hand and want the penalty without caring where it is stored.
-- Reading the attribute per-frame (rather than baking it into GetConfig, which
-- runs once per drive session) is what lets load change while the player is
-- already sitting in the truck at the loading dock.
function CargoLoad.HandlingForModel(config, carModel)
	local loadFraction = carModel and carModel:GetAttribute(CargoLoad.Attributes.LoadFraction)
	return CargoLoad.HandlingAt(config, type(loadFraction) == "number" and loadFraction or 0)
end

--=============================================================================
-- Condition and worth
--=============================================================================

-- Cargo never pays nothing. A run that ends with wrecked goods still returns
-- this share of its value, because the alternative - driving a full route and
-- collecting zero - is the single most quit-inducing outcome a delivery game
-- can produce. The floor is what keeps a bad run "disappointing" instead of
-- "wasted".
CargoLoad.MinConditionPayFactor = 0.4

-- How much of an impact lands on the cargo. VehicleDamage already clamps and
-- rate-limits `severity` (0-1) before anything sees it, so this only has to
-- decide how much a given severity is worth against a given fragility.
--
-- Tuned so an ordinary kerb scrape on Parcels is nearly free, while a solid
-- wall hit carrying Glassware (Fragility 3.2) costs about a third of the
-- load's condition - two of those and the run is at the pay floor.
CargoLoad.ConditionLossPerSeverity = 0.35

function CargoLoad.ConditionAfterImpact(condition, severity, typeId)
	local cargoType = CargoTypes.GetOrDefault(typeId)
	local loss = math.clamp(severity or 0, 0, 1) * CargoLoad.ConditionLossPerSeverity * cargoType.Fragility
	return math.clamp((condition or 1) - loss, 0, 1)
end

-- Condition -> the fraction of full value that condition is worth, floored.
function CargoLoad.PayFactorForCondition(condition)
	local clamped = math.clamp(condition or 1, 0, 1)
	return lerp(CargoLoad.MinConditionPayFactor, 1, clamped)
end

-- What this load is worth on arrival, BEFORE any delivery-side multiplier.
-- Distance, park grade and contract bonuses are deliberately not here: those
-- belong to DeliveryManager, which owns the destination. This function only
-- knows what is on the truck.
function CargoLoad.Value(units, typeId, condition)
	local cargoType = CargoTypes.GetOrDefault(typeId)
	return math.max(0, math.floor(units or 0))
		* cargoType.ValuePerUnit
		* CargoLoad.PayFactorForCondition(condition)
end

return CargoLoad

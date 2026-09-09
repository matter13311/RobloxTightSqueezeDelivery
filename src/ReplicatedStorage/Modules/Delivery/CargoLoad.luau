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
-- DeliveryConfig requires nothing itself, so this cannot cycle.
local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)

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
	-- number, or ABSENT. How many crates of an in-progress load have been
	-- placed so far - 0 the moment loading starts, and removed entirely the
	-- moment it finishes.
	--
	-- Absence is the signal, not a sentinel value: "is this truck loading
	-- right now" is exactly `GetAttribute(...) ~= nil`, which is one read with
	-- no comparison to get wrong, and a truck that is destroyed mid-load takes
	-- the flag with it rather than leaving something stuck on. Units is set to
	-- the FINAL count up front, so a HUD showing progress is placed/Units.
	LoadingPlaced = "CargoLoadingPlaced",
	-- number, server-internal. Bumped by every Load and every Unload; a
	-- running load sequence carries the value it started with and stops the
	-- moment the two disagree. See CargoManager.bumpSequence for why the
	-- cancellation token lives on the Model instead of in a table.
	--
	-- Listed here rather than kept private to CargoManager only so that every
	-- attribute this system writes to a vehicle is documented in one place.
	-- Nothing outside CargoManager should read it.
	LoadSequence = "CargoLoadSequence",
}

-- Whether crates are still being placed on this truck right now.
--
-- Shared because three unrelated places ask it and must agree: the driving
-- client immobilises the truck while it is true, the loading HUD is shown
-- while it is true, and CargoManager ignores impacts while it is true.
function CargoLoad.IsLoading(carModel)
	if not carModel then
		return false
	end
	return carModel:GetAttribute(CargoLoad.Attributes.LoadingPlaced) ~= nil
end

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
-- Weight, as the player sees it
--=============================================================================

-- The mass a load adds, as a fraction of the truck's own empty mass.
--
-- The same quantity AddedMass multiplies emptyMass by, pulled out on its own
-- because it is the vehicle-independent half: it needs no truck present, which
-- is what lets the contract board describe a job's heft before the crates
-- exist. Deliberately NOT clamped to capacity - the board quotes offers that
-- are already sized to the bed, and clamping here would silently under-report
-- a load if a caller ever passed an unclamped count.
function CargoLoad.MassFraction(config, units, typeId)
	local cargoType = CargoTypes.GetOrDefault(typeId)
	local perUnit = (config.CargoMassFractionPerUnit or 0) * cargoType.MassMultiplier
	return math.max(0, math.floor(units or 0)) * perUnit
end

-- What a FULL bed of the baseline cargo adds to this vehicle, as a fraction of
-- its empty mass. The yardstick every weight band is measured against - see
-- WeightBand.
function CargoLoad.FullBedMassFraction(config)
	return CargoLoad.Capacity(config) * math.max(0, config.CargoMassFractionPerUnit or 0)
end

-- A load turned into the two things a UI needs: a word and a 0-1 bar fill. Both
-- come from here rather than from the HUD so that a second screen showing
-- weight (a garage comparison, a van-buying preview) cannot band the same load
-- differently.
--
-- BANDED AGAINST THE TRUCK, NOT ABSOLUTELY. `reference` is what a full bed of
-- plain Parcels weighs in the vehicle being quoted (FullBedMassFraction above),
-- and the bands are multiples of that: "Heavy" means heavier than a full
-- ordinary load of whatever this truck can hold.
--
-- The first version compared massFraction against fixed thresholds, and that
-- quietly broke on the one axis the player controls. CargoCapacity is an
-- upgrade, so the mass a load CAN reach scales with it - the same job that read
-- Moderate on the stock bed of 4 read Heavy on an upgraded bed of 10, and past
-- about capacity 8 essentially every job on the board read Heavy. A band that
-- says the same word about every offer has stopped being information, which is
-- the exact complaint that got the bands re-tuned in the first place; fixed
-- thresholds would simply have moved it from the low end to the high end.
--
-- Against the truck's own full bed, the ratio is capacity-invariant by
-- construction: units/capacity times the type's MassMultiplier. Three-quarters
-- of a bed of gravel reads the same on every vehicle in the game, which is what
-- the player is actually comparing when they look at two cards side by side.
--
-- Returns an Id alongside the label so a caller can pick its own colour
-- without string-matching on display text.
function CargoLoad.WeightBand(massFraction, reference)
	local weight = DeliveryConfig.Weight
	local fraction = math.max(0, massFraction or 0)
	-- A vehicle with no cargo config at all (capacity 0, or a model nobody has
	-- prepared) has no full bed to compare against. Everything it is quoted is
	-- Light, which is both harmless and true: it cannot carry anything.
	local full = math.max(0, reference or 0)
	local ratio = if full > 0 then fraction / full else 0

	local id, label
	if ratio > weight.HeavyAbove then
		id, label = "Heavy", "Heavy"
	elseif ratio > weight.ModerateAbove then
		id, label = "Moderate", "Moderate"
	else
		id, label = "Light", "Light"
	end

	return {
		Id = id,
		Label = label,
		-- The absolute figure is still handed back: it is the physically
		-- meaningful one (this much more mass in the assembly), and a caller
		-- wanting to print a number wants that rather than the ratio.
		Fraction = fraction,
		Ratio = ratio,
		-- Pins at 1 rather than overflowing the bar; see BarFullAt.
		Fill = math.clamp(ratio / math.max(weight.BarFullAt, 0.001), 0, 1),
	}
end

--=============================================================================
-- Crate layout
--=============================================================================

-- Crates are laid out in a fixed grid around the CargoBed attachment rather
-- than fitted to the bed's real dimensions, because an Attachment is a point
-- and knows nothing about the size of the bed it sits in. Two across and three
-- deep fills a pickup bed convincingly and stacks a second layer above it once
-- capacity goes past six.
--
-- If a vehicle ever needs a different shape (a box van, a flatbed), these
-- become per-car config keys. They are constants until a second body style
-- actually exists - guessing at that API now would be guessing.
--
-- Shared rather than living in CargoManager, for the usual reason in this
-- codebase: the contract board draws a preview of the load in a ViewportFrame,
-- and a preview that stacks its crates differently from the truck is a lie the
-- player finds out about after they have already accepted the job.
CargoLoad.Layout = {
	Across = 2,
	RowsAlong = 3,
	Gap = 0.15, -- studs between crates, so a stack reads as separate boxes rather than one slab
}

-- Where the Nth crate (0-based) sits, relative to the middle of the bed FLOOR.
function CargoLoad.CrateOffset(index, crateSize)
	local layout = CargoLoad.Layout
	local perLayer = layout.Across * layout.RowsAlong
	local col = index % layout.Across
	local row = math.floor(index / layout.Across) % layout.RowsAlong
	local layer = math.floor(index / perLayer)

	-- Centred on the bed across and along, but sitting ON it vertically - the
	-- origin marks the bed FLOOR, so the first layer's centre is half a crate
	-- above it.
	return Vector3.new(
		(col - (layout.Across - 1) / 2) * (crateSize.X + layout.Gap),
		crateSize.Y / 2 + layer * (crateSize.Y + layout.Gap),
		(row - (layout.RowsAlong - 1) / 2) * (crateSize.Z + layout.Gap)
	)
end

-- The overall size of a stack of `units` crates. Only the board's preview
-- needs this today - it is what lets the camera frame any crate count without
-- a hand-tuned distance per cargo type - but it is derived from the same
-- constants as CrateOffset, which is the point of it being here.
function CargoLoad.StackSize(units, crateSize)
	local layout = CargoLoad.Layout
	local count = math.max(0, math.floor(units or 0))
	if count == 0 then
		return Vector3.zero
	end

	local perLayer = layout.Across * layout.RowsAlong
	local inLayer = math.min(count, perLayer)
	local cols = math.min(inLayer, layout.Across)
	local rows = math.min(math.ceil(inLayer / layout.Across), layout.RowsAlong)
	local layers = math.ceil(count / perLayer)

	return Vector3.new(
		cols * crateSize.X + (cols - 1) * layout.Gap,
		layers * crateSize.Y + (layers - 1) * layout.Gap,
		rows * crateSize.Z + (rows - 1) * layout.Gap
	)
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

-- Tuning and naming for the delivery loop, shared so the server's payout and
-- the player's HUD can never quote two different numbers - the same reason
-- Admin.GrantAmount lives in a shared module rather than being typed twice.
--
-- Everything the code looks for BY NAME in the world is here too, so
-- renaming a folder in Studio is a one-line change rather than a hunt through
-- three scripts. See docs/CargoDesign.md section 4 for what has to exist.

local DeliveryConfig = {}

--=============================================================================
-- World layout (see docs/CargoDesign.md section 4.2)
--=============================================================================

DeliveryConfig.World = {
	RootFolderName = "Delivery", -- workspace.Delivery
	DepotFolderName = "Depot",
	LoadingBayName = "LoadingBay",
	DestinationsFolderName = "Destinations",
	-- Any Part whose name starts with this, inside a destination model or the
	-- loading bay, is a parking space. A prefix rather than an exact name so a
	-- destination can have Space1/Space2/SpaceLoadingRamp without a list
	-- anywhere.
	SpacePrefix = "Space",
	-- Any Part whose name starts with this, inside the loading bay or a
	-- destination model, gets a sign board drawn on it. A prefix for the same
	-- reason SpacePrefix is one: a big destination can carry Sign1 over each
	-- door without a list anywhere. A destination's sign takes its text from
	-- the MODEL's name, so it never has to be typed twice.
	SignPrefix = "Sign",
	-- Optional per-space attribute, so one awkward bay can be worth more than
	-- the easy one next to it.
	SpacePayoutAttribute = "PayoutMultiplier",
}

--=============================================================================
-- Parking
--=============================================================================

DeliveryConfig.Parking = {
	-- studs/s under which the truck counts as stopped. Matches the spirit of
	-- VehiclePhysics' StoppedSpeed: above the residual jitter of the low-speed
	-- brake controller, below anything a player would call moving.
	StoppedSpeed = 1.5,
	-- ...and for this long. The delay is not padding: the server's copy of a
	-- client-owned chassis is a lagging echo while it MOVES (see
	-- VehicleDamage's header), and a truck that has been still for a second is
	-- the one case where the echo is exactly right. Good feel and correct
	-- validation happen to want the same thing here.
	StoppedHoldSeconds = 1,

	-- |dot| between the truck's forward and the space's forward, above which
	-- the truck counts as squarely in the bay one way or the other. 0.85 is
	-- about 32 degrees of slack - forgiving enough to be achievable in first
	-- person, tight enough that a visibly crooked truck gets no bonus.
	AlignmentThreshold = 0.85,

	-- How far outside the space's footprint the truck's bounding box may
	-- poke and still count as parked. A stud of slack absorbs suspension
	-- bounce and the odd wing mirror.
	ContainmentTolerance = 1,
}

--=============================================================================
-- Payout
--=============================================================================

DeliveryConfig.Payout = {
	-- Multipliers on the load's value. A nose-in park is the baseline, not a
	-- penalty: the player still did the job. Reversing in is the skill bonus.
	NoseInMultiplier = 1,
	ReverseMultiplier = 1.35,
	-- Extra on top, earned by being straight and centred rather than merely
	-- inside. Scales from 0 to this across the alignment/centering scores, so
	-- a scruffy reverse park still beats a tidy nose-in and a tidy reverse
	-- park is the best outcome available.
	PrecisionBonus = 0.15,

	-- Distance from the depot to the destination, in studs, that earns
	-- DistanceBonusAtMax on top. Linear below it, capped above. This is what
	-- makes the far side of the map worth driving to without needing to
	-- measure the route the player actually took - only where they ended up.
	DistanceForMaxBonus = 1200,
	DistanceBonusAtMax = 0.5,

	-- Hard ceiling on a single delivery, as a multiple of the load's face
	-- value. Cargo condition comes from client-reported impacts, so a cheating
	-- client's best case is arriving pristine every time; this caps how much
	-- that can ever be worth. See docs/CargoDesign.md section 6.
	MaxMultiplier = 3,
}

--=============================================================================
-- Weight banding
--=============================================================================

-- How the board describes a load's heft. The number banded here is the mass
-- the load ADDS as a fraction of the truck's own empty mass - so 0.5 means
-- "half the truck again" - which is the one measure that means the same thing
-- on every vehicle in the catalog. An absolute figure in mass units would
-- read as "heavy" on the starter van and "light" on something twice its size,
-- which is exactly backwards from how it would drive.
--
-- Banded rather than shown as a raw number because the player is choosing
-- between three jobs in a moving truck, not reading a spec sheet.
DeliveryConfig.Weight = {
	-- Below ModerateAbove is Light, above HeavyAbove is Heavy, between is
	-- Moderate. With the catalog's default CargoMassFractionPerUnit of 0.10
	-- and a capacity of 4: a full load of Glassware lands at 0.36 (Moderate)
	-- and a full load of Sand & Gravel at 0.84 (Heavy), which is the spread
	-- these are set to separate.
	ModerateAbove = 0.25,
	HeavyAbove = 0.55,
	-- What a completely full bar means. Above this the bar simply pins - the
	-- difference between "doubles the truck" and "triples it" is not something
	-- a 90-pixel bar can usefully show.
	BarFullAt = 1,
}

--=============================================================================
-- Depot guides (the floor glow and the sign)
--=============================================================================

-- Pure client-side feedback. None of this is read by the server - see
-- DepotGuides.client.luau's header for why the colour is not replicated.
DeliveryConfig.Guides = {
	-- How far outside the space's footprint the truck can be and still get any
	-- colour at all. The glow runs red at this distance and green the moment
	-- the truck is fully inside, so the player can see the bay reacting to
	-- them before they are anywhere near parked - which is the entire point of
	-- it. Measured on the worst corner of the truck's bounding box.
	ApproachStuds = 10,

	-- How near the vehicle has to be before a space's guide appears at all,
	-- measured from the vehicle to the space's centre. Separate from
	-- ApproachStuds, and much larger, because the two answer different
	-- questions: this one is "is this bay any of my business right now", and
	-- ApproachStuds is "how close am I to being parked in it". Without this
	-- gate every bay in the map glows red the moment you sit in a vehicle,
	-- which turns the guide from a hint into wallpaper.
	ShowWithinStuds = 75,
	-- The guide fades in across this last stretch of ShowWithinStuds rather
	-- than popping on at the boundary.
	FadeBandStuds = 25,

	-- The floor frame the guide draws, when a space has no outline of its own.
	FrameThickness = 0.45,
	FrameHeight = 0.08, -- how far above the space's own base the frame floats, so it does not z-fight a decal
}

--=============================================================================
-- Contracts
--=============================================================================

DeliveryConfig.Contracts = {
	-- How many jobs the board offers at once. Three is enough for a real
	-- choice between a safe short run and a risky long one without turning the
	-- dock into a menu to study.
	OfferCount = 3,
	-- Offers are sized to the truck's own capacity, so buying CargoCapacity
	-- directly raises what the board is willing to hand you. The range keeps
	-- some offers deliberately light - a part load of Glassware is a real
	-- choice against a full load of Parcels.
	MinUnitsFraction = 0.5,
	-- A truck with no capacity at all still gets offers, for this many crates,
	-- so an unprepared vehicle shows something explicable on the board rather
	-- than an empty list.
	FallbackUnits = 1,
}

return DeliveryConfig

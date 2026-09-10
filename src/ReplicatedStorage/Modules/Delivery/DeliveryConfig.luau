-- Tuning and naming for the delivery loop, shared so the server's payout and
-- the player's HUD can never quote two different numbers.
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
	-- studs/s under which the vehicle counts as stopped, measured HORIZONTALLY
	-- ONLY - see ParkGrade.IsStopped, which is the one place this is applied.
	-- Matches the spirit of VehiclePhysics' StoppedSpeed: above the residual
	-- jitter of the low-speed brake controller, below anything a player would
	-- call moving.
	StoppedSpeed = 1.5,

	-- The same question, on the vertical axis, and deliberately eight times
	-- more forgiving.
	--
	-- A parked car on a raycast suspension does not sit still: it bobs, and it
	-- bobs HARDER the more cargo is loaded into it, which is exactly the moment
	-- the game most needs to agree that it is parked. Measured as one speed
	-- (which is what `AssemblyLinearVelocity.Magnitude` gives you) that bob
	-- crosses 1.5 studs/s several times a second, and every system that asks
	-- "is it parked" flickers in step with the springs - the job board opening
	-- and closing, an accepted contract silently refused on the one frame the
	-- click landed, and a delivery that never completes because the one-second
	-- hold below is reset before it can ever elapse.
	--
	-- Splitting the axes fixes all of that at once, and is the more correct
	-- test rather than merely a looser one: "stopped" means the vehicle is not
	-- GOING anywhere, and bouncing in place is not going anywhere. The vertical
	-- limit is kept rather than dropped entirely so that a car in free fall -
	-- which passes a horizontal-only test perfectly - cannot be parked, and it
	-- sits far above any bob and far below the ~60 studs/s a fall reaches in a
	-- third of a second.
	StoppedVerticalSpeed = 12,

	-- ...and for this long. The delay is not padding: the server's copy of a
	-- client-owned chassis is a lagging echo while it MOVES (see
	-- VehicleDamage's header), and a truck that has been still for a second is
	-- the one case where the echo is exactly right. Good feel and correct
	-- validation happen to want the same thing here.
	StoppedHoldSeconds = 1,

	-- How long a vehicle that has just failed the parked test still COUNTS as
	-- parked, for anything that only displays something.
	--
	-- Shared rather than left as a private constant in the HUD, because it is
	-- the number that decides whether two systems agree: the board is shown on
	-- this grace, so anything else that says "the board is open" - the
	-- tutorial's step four, today - has to be told the same story or it
	-- contradicts what the player can see on their own screen. That
	-- disagreement is precisely the bug this constant was extracted to kill.
	--
	-- NOT applied to anything that pays out or loads cargo. Those re-check the
	-- instant they act, on purpose.
	LeaveGraceSeconds = 1,

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
-- Loading the crates on
--=============================================================================

-- Cargo does not appear on the truck all at once - the crates are placed one
-- at a time, each with its own thud, and the weight goes on with them.
--
-- WHY, since the end state is identical: a player at the dock is looking
-- FORWARD, out of the windscreen, and the bed is behind them. A load that
-- lands in a single frame is a truck that silently starts handling worse for
-- no reason they ever saw. Placed one crate at a time it is a truck that
-- audibly and visibly sags, six times, in their peripheral vision - the
-- suspension spring is not mass-scaled (see CargoLoad's header), so every
-- crate makes the whole vehicle dip on its springs for free. That dip is the
-- clearest statement the game can make about weight, and it costs nothing but
-- the delay below.
DeliveryConfig.Loading = {
	-- Gap between crates.
	--
	-- TUNED SLOW ON PURPOSE, and slower than it first looks like it should be.
	-- The first pass ran at 0.35 and playtested badly: an adult reads it fine,
	-- but a child cannot process six separate events in two seconds - the
	-- thuds blur into one rumble, the individual suspension dips merge into a
	-- single sag, and the counter on the overlay is finished before they have
	-- worked out what it is counting. At 0.8 each crate is unmistakably its
	-- own arrival: thud, dip, one more box on the pile, and time to look at it
	-- before the next one.
	--
	-- If this is ever tuned again, tune it DOWNWARDS from something too slow
	-- rather than upwards from something too fast. The failure mode of too
	-- slow is boredom, which is visible in a playtest; the failure mode of too
	-- fast is a child who never learns their truck got heavy, which is not.
	SecondsPerCrate = 0.8,

	-- ...but a whole load never takes longer than this, no matter how many
	-- crates. CargoCapacity is an upgrade, so the crate count grows over the
	-- life of an account and a fixed per-crate gap would quietly turn into a
	-- twenty-second wait on the biggest truck in the game. The interval
	-- shrinks to fit instead, which keeps the sequence feeling like a reward
	-- for having a big bed rather than a tax on it.
	--
	-- At the numbers above this only starts biting past ten crates, so an
	-- ordinary load runs at the full, deliberate 0.8 per crate and only a
	-- genuinely enormous bed gets compressed.
	MaxTotalSeconds = 8,

	-- Picked at random per crate, so a six-crate load is six different thuds
	-- rather than the same sample stuttering. One entry today; add more ids
	-- here and nothing else has to change.
	SoundIds = {
		"rbxassetid://9113527923",
	},
	-- The load stays "in progress" for a beat after the last crate lands, so
	-- the overlay gets to say "Cargo Added!" instead of vanishing on the same
	-- frame it fills up. The truck stays held for that beat too, which is the
	-- one moment the player is guaranteed to be reading the screen - and so
	-- the only place worth putting "brake early, it's heavy now".
	--
	-- Long enough to READ, which is the whole job: two short lines at a
	-- child's reading speed, not an acknowledgement flash. Held rather than
	-- dismissable because a player who could skip it would, every single run,
	-- and this is the sentence the game most needs them to have seen once.
	CompleteHoldSeconds = 2,

	SoundVolume = 0.7,
	-- Heard from outside the truck too - a depot with someone loading in it
	-- should sound like one. Roughly the length of the bay.
	SoundRollOffMaxDistance = 90,
}

--=============================================================================
-- Weight banding
--=============================================================================

-- How the board describes a load's heft. The number banded here is the load's
-- mass as a MULTIPLE OF A FULL BED OF PLAIN PARCELS in the truck being quoted
-- (CargoLoad.FullBedMassFraction) - so 1 means "as heavy as this truck's own
-- full ordinary load" and 2 means twice that.
--
-- Measured against the truck rather than in absolute mass fractions because
-- CargoCapacity is an upgrade: the mass a load can reach scales with the bed,
-- so fixed thresholds relabel the whole catalog every time the player buys a
-- crate slot. See CargoLoad.WeightBand's header for the full argument.
--
-- Banded rather than shown as a raw number because the player is choosing
-- between three jobs in a moving truck, not reading a spec sheet.
DeliveryConfig.Weight = {
	-- Below ModerateAbove is Light, above HeavyAbove is Heavy, between is
	-- Moderate. All three are multiples of a full bed of Parcels.
	--
	-- The old thresholds had a reporting bug worth recording. They were
	-- absolute mass fractions (0.25 / 0.55), and at the then-current
	-- CargoMassFractionPerUnit of 0.10 on the base capacity of 4, the range a
	-- player could actually be offered ran 0.20 to 0.84. That sliced so that
	-- "Light" needed a 2-crate load of one of the two lightest types - about
	-- one board in eight - and players reported, correctly, that Light did not
	-- exist. A band nobody ever sees is not a band; it is a word in a table.
	--
	-- Since the load is now sized against the truck's own full bed, where these
	-- land does not move when CargoCapacity is upgraded. Contract offers run
	-- from half a bed to a full one (DeliveryConfig.Contracts.MinUnitsFraction),
	-- so the reachable range is 0.5 to 2.1 - a half bed of Parcels to a full bed
	-- of Sand & Gravel - and the catalog falls out as:
	--
	--                   half   3/4   full
	--     Parcels       0.50L  0.75L  1.00M
	--     Produce       0.58L  0.86M  1.15M
	--     Glassware     0.70L  1.05M  1.40H
	--     Sand&Gravel   1.05M  1.58H  2.10H
	--
	-- Every band is reachable on every vehicle, a beginner's Parcels run reads
	-- Light most of the time (which it is), and Heavy means a big load of the
	-- genuinely heavy goods rather than "you have upgraded your bed".
	ModerateAbove = 0.8,
	HeavyAbove = 1.3,
	-- What a completely full bar means. Above this the bar simply pins.
	--
	-- The heaviest thing that can be offered is a full bed of Sand & Gravel at
	-- exactly 2.1, so the bar uses very nearly its whole length across the real
	-- range of jobs rather than spending half of it on loads that cannot exist.
	BarFullAt = 2,
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
	--
	-- Raised from 45, which was tuned before the tutorial existed and turned out
	-- to be about a second and a half of driving - the posts appeared roughly as
	-- the player was already braking, which is too late to be aimed at. The gate
	-- still does its job at this range: only ONE group is ever lit (the depot,
	-- or the single destination being delivered to), so raising it shows more of
	-- the bay the player is heading for and not one extra bay anywhere else.
	ShowWithinStuds = 120,
	-- The guide fades in across this last stretch of ShowWithinStuds rather
	-- than popping on at the boundary. Widened with the range above so the fade
	-- stays a gradual arrival rather than a flash at 120 studs.
	FadeBandStuds = 40,

	-- THE GUIDE IS FOUR CORNER POSTS AND NOTHING ELSE. It used to draw a bar
	-- along each edge as well, and the two together read as an upside-down
	-- table rather than as a bay: the floor rectangle is the part the eye
	-- takes as the object, so the posts looked like legs hanging off it. The
	-- posts alone read as what they are - four markers you drive between.
	--
	-- They are also the half that does the actual work. A floor outline is
	-- gone from a first-person camera at exactly the distance the colour
	-- matters most, sliding under the bonnet in the last few studs of a park.
	--
	-- On the CORNERS and nowhere else, because the corners are the one place a
	-- driver aiming into the bay is never looking through. A post anywhere
	-- along an edge - or a taller wall of light - would sit directly between
	-- the player and the thing they are parking next to.
	CornerPostHeight = 4, -- studs; enough to clear a bonnet without walling the bay in
	CornerPostThickness = 0.35,
	CornerPostBase = 0.08, -- how far above the space's own base a post starts, so it does not z-fight a decal

	-- Posts never go fully opaque even at full brightness. Their whole reason
	-- for existing is to be at eye height, which is also the only place a
	-- solid object could hide the bay wall the player is trying not to hit.
	CornerPostTransparency = 0.45,
}

--=============================================================================
-- Contracts
--=============================================================================

DeliveryConfig.Contracts = {
	-- HOW MANY JOBS THE BOARD HOLDS IS NOT HERE ANY MORE. It is not a constant:
	-- it grows with the player's level, and the board itself is a persisted,
	-- real-time-refilling pool rather than a set of offers rolled on arrival.
	-- See ProgressionConfig.ContractCapFor and ContractPool.luau.
	--
	-- What is still here is how a single contract is SHAPED, which has not
	-- changed and is read by both the pool that generates them and the board
	-- that draws them.

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

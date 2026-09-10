-- Suspension is tuned for this truck's own chassis (see the block above
-- SuspensionMaxLength for the derivation); everything else is still the
-- PickupTruck's numbers.
--
-- Neither suspension force nor Torque scale with mass (see
-- VehiclePhysics.Step), so every number here is tied to ONE measured value:
-- the chassis' AssemblyMass, which is 216: Chassis 170.4, the four wheel
-- models ~5.9 each, and the Engine counterweight ~22. Every body panel is
-- Massless. Read the real one in-game with `/cargo info` (CargoTestCommands)
-- - it prints "empty mass", which is AssemblyMass with no ballast aboard. It
-- is NOT the Chassis part's own Mass in Studio.
--
-- The Engine's mass is not decoration. The four wheel attachments centre on
-- z = -0.55 in chassis space, but the Chassis part (most of the mass) is a
-- uniform block centred on z = 0, so without it the weight sits behind the
-- axles and the equal springs squat the tail - the "leaning backwards" pose.
-- The Engine's density is set so its weight at z = -4.83 puts the centre of
-- mass exactly over the axle midpoint. Change the Chassis, the wheels or the
-- wheel attachment Z and the Engine's density needs recomputing, or the
-- truck will pitch again. Keep the four attachment heights (Y) EQUAL - an
-- uneven height tilts the body by design and only hides a weight problem.
--
-- Likewise any body part left non-Massless on ONE side leans the truck:
-- 0.15 studs of sideways centre-of-mass offset is already ~1.5 degrees.
--
-- If that measured mass turns out to be M rather than 170, rescale both
-- spring values by the SAME factor and nothing below changes meaning:
--     Stiffness = 120 * M / 216
--     Damper    = 7.5 * M / 216
-- Stiffness must scale with mass to hold the same ride height, and Damper
-- must scale with mass to hold the same damping ratio (zeta is Damper over
-- sqrt(Stiffness * mass), and Stiffness is already proportional to mass, so
-- zeta ends up proportional to Damper/mass). Scaling only one of them is the
-- mistake that produces either a floating truck or a shivering one.
return {
	-- The grindy per-car upgrade ladder (see VehicleUpgrades.luau for the
	-- math, and PlayerDataStore.luau for how a player's purchased levels and
	-- chosen slider values are saved).
	--
	-- There is NO Min here, on purpose. Every key in this table must also be
	-- a plain numeric field further down the file, and that field IS the
	-- ladder's Min - it's the level-0/no-upgrades-bought value a fresh
	-- BoxTruck starts with, so the two are the same number by definition.
	-- VehiclePhysics.GetUpgradeSpecs fills it in from there, which is why
	-- re-tuning a stat below automatically re-bases its ladder here. Writing
	-- it in both places made that a hand-maintained invariant, and it did
	-- drift once already - see the Torque note in StarterVehicle.luau.
	--
	-- Buying a level does NOT move the stat by itself - it only unlocks one
	-- more notch (Min + Step) on the garage terminal's slider for this stat,
	-- which the player then has to drag to actually use. That's what makes
	-- "buy Torque" and "turn the Torque slider up" two separate actions.
	--
	-- Deliberately left OFF this list (and so never shown to players as
	-- upgrades): HandbrakeGripMultiplier, HandbrakeLockFriction,
	-- SteeringWheelInvert, SteerReturnSpeed - none of those are "fun to play
	-- with" knobs, they're feel/tuning internals.
	-- Description is shown verbatim in the garage terminal's (i) info modal
	-- (PlotTerminal.client.luau) - plain-language, no stat jargon, since it's
	-- aimed at a player deciding whether to spend money, not at whoever's
	-- tuning these numbers.
	Upgrades = {
		-- Max must be a whole number of Steps above the plain field's value
		-- (Min + Step * levels), or GetUpgradeSpecs snaps it down and warns.

		-- How many hits the bodywork survives before panels start coming off.
		-- Unlike every other stat here this one changes nothing about how the
		-- car drives - damage in this game is purely cosmetic by construction
		-- (see VehicleCollision.CanDetach; nothing can ever stop a car being
		-- driveable). It is bought to keep the car LOOKING intact through a
		-- clumsy run, not to survive one.
		--
		-- A plain multiplier on incoming damage, so 2 means every panel takes
		-- twice the punishment before it detaches. Note it does NOT protect
		-- the CARGO - crates have their own condition, and that is the one
		-- that decides what a delivery pays (see CargoManager.ApplyImpact).
		-- Driving carefully is still the only thing that protects the payout.
		BodyStrength = {
			DisplayName = "Armor",
			IconId = "rbxassetid://92533250100635",
			Max = 2.5,
			Step = 0.25,
			BaseCost = 180,
			CostGrowth = 1.4,
			Description = "How much punishment the bodywork takes before panels start falling off. Higher Body Strength means more scrapes and knocks before your car starts looking wrecked. It won't protect what's in the back, though - only careful driving does that.",
		},
		Torque = {
			DisplayName = "Power",
			IconId = "rbxassetid://135577056253416",
			Max = 25,
			Step = 2.5,
			BaseCost = 150,
			CostGrowth = 1.5,
			Description = "How hard the engine pulls when you hit the gas. Higher Torque means quicker acceleration and an easier time powering up over kerbs and ramps.",
		},
		MaxSpeed = {
			DisplayName = "Top Speed",
			IconId = "rbxassetid://103985131551349",
			Max = 125,
			Step = 5,
			BaseCost = 200,
			CostGrowth = 1.5,
			Description = "The truck's top speed in a straight line. Higher Max Speed lets you go faster once you're up to full speed, but doesn't change how quickly you get there.",
		},
		SteerAngle = {
			DisplayName = "Turning",
			IconId = "rbxassetid://77987850174545",
			Max = 52,
			Step = 4,
			BaseCost = 100,
			CostGrowth = 1.4,
			Description = "How sharply the front wheels can turn. Higher Steer Angle gives you a tighter turning circle, which helps a lot for threading tight gaps and parking.",
		},
		-- Min is the plain Stiffness field below (120). Buying Springs on this
		-- truck does something visible that it does not do on the Pickup:
		-- stiffer springs sag LESS under the same weight, so an upgraded
		-- BoxTruck both leans less AND sits a little higher, and a fully
		-- loaded one stops squatting onto its bump stops. Max is held where
		-- Stiffness + 120 * Damper stays well under the integrator's
		-- divergence limit of 30 * AssemblyMass / 4 - see the Damper note.
		Stiffness = {
			DisplayName = "Springs",
			IconId = "rbxassetid://81458577246421",
			Max = 180,
			Step = 10,
			BaseCost = 120,
			CostGrowth = 1.4,
			Description = "How firm the suspension springs are. Higher Stiffness keeps the truck flatter and steadier through turns; lower feels bouncier and leans more.",
		},
		-- Max is much lower than the Pickup's 9, and it is not a feel choice.
		-- The suspension is an EXPLICITLY integrated spring-damper, so what
		-- decides whether it rings or diverges is a per-frame gain, and the
		-- damper contributes to it 120x harder than the spring does. Writing
		-- VehiclePhysics' criterion out at 60fps, a car is stable when
		--     Stiffness + 120 * Damper  <=  30 * AssemblyMass / 4
		-- and the right-hand side is 1620 here (mass 216). The cars this
		-- game already ships sit near HALF their own limit at their defaults,
		-- which is the real "known good" number, not a raw Damper value.
		--
		-- Defaults here: 120 + 120 * 7.5 = 1020, or 0.63 of the limit. The
		-- top of both ladders: 180 + 120 * 9.5 = 1320, or 0.81, the same worst
		-- case the Pickup's own top-of-ladder reaches. Raising
		-- either Max without re-doing that sum is how you get the truck
		-- shivering left-to-right at rest, and it will look like a model bug
		-- rather than a tuning one.
		Damper = {
			DisplayName = "Smooth Ride",
			IconId = "rbxassetid://113834210436142",
			Max = 9.5,
			Step = 0.5,
			BaseCost = 130,
			CostGrowth = 1.5,
			Description = "How quickly the suspension settles after a bump. Higher Damper stops the truck bouncing for as long after landing a jump or hitting a pothole.",
		},
		-- Travel is bump absorption, but on this truck it is ALSO ride
		-- height: the chassis rests at (SuspensionMaxLength - sag) above
		-- where a fully compressed strut would put it, so every extra stud
		-- of travel is an extra stud of daylight under the body and of visible
		-- droop on the wheels. That is what makes 4.5 wrong here and why the
		-- ladder tops out at 3.25 - a player buying Suspension is trading a
		-- slightly taller-looking truck for landings that don't bottom out,
		-- which is a real choice rather than a free win.
		SuspensionMaxLength = {
			DisplayName = "Suspension",
			IconId = "rbxassetid://89709264264758",
			Max = 3.25,
			Step = 0.2,
			BaseCost = 110,
			CostGrowth = 1.4,
			Description = "How much travel the suspension has to work with. More Suspension Length soaks up bigger bumps and landings before the truck bottoms out.",
		},
		TractionSlipThreshold = {
			DisplayName = "Grip",
			IconId = "rbxassetid://108082344305577",
			Max = 8.5,
			Step = 0.5,
			BaseCost = 90,
			CostGrowth = 1.3,
			Description = "How much a tire can slide before it's treated as slipping. Higher Wheel Traction lets you push harder into corners before the tires break loose.",
		},
		BrakeFriction = {
			DisplayName = "Brakes",
			IconId = "rbxassetid://91273321942687",
			Max = 0.45,
			Step = 0.05,
			BaseCost = 100,
			CostGrowth = 1.4,
			Description = "How hard the brakes bite. Higher Brake Speed stops the truck in a shorter distance when you hit the brake pedal.",
		},
		-- The one upgrade that directly raises earnings rather than making the
		-- truck nicer to drive, and deliberately the most expensive ladder
		-- here - every other stat only helps you SURVIVE a heavy load, so this
		-- is what those upgrades are ultimately bought in service of.
		--
		-- Unlike every other stat on this list, the slider is not really a
		-- choice: nobody wants to carry less than they can. It stays a slider
		-- for consistency with the rest of the terminal, and because carrying
		-- deliberately light IS occasionally right - a Glassware run over bad
		-- ground pays better half-empty and intact than full and smashed.
		CargoCapacity = {
			DisplayName = "Cargo Space",
			IconId = "rbxassetid://133569717590420",
			Max = 18,
			Step = 1,
			BaseCost = 250,
			CostGrowth = 1.45,
			Description = "How many crates fit in the bed. Every crate you carry is more money on delivery, but also more weight - a full load leans harder in turns and takes noticeably longer to stop.",
		},
	},

	-- Cargo. See docs/CargoDesign.md; CargoLoad.luau explains why the two
	-- multipliers below have to exist at all when we are also adding real mass.
	CargoCapacity = 8, -- MUST equal the Upgrades entry's Min above
	-- THE master weight dial. It is the number to move if loaded driving feels
	-- too tame or too punishing overall - the two multipliers below only shape
	-- braking and cornering, while this one drives the sag, the sluggishness
	-- off the line and how hard the truck shoves in a collision.
	--
	-- MUCH lower than the Pickup's 0.07, and lowering it is what actually
	-- buys this truck its "carries a lot without squatting" character. The
	-- number is a fraction of the truck's OWN empty mass per crate, so
	-- copying 0.07 across meant a full 18-crate BoxTruck was carrying 126% of
	-- its own weight - the springs sag in proportion to that, so it would
	-- have sat on its bump stops with the wheels tucked into the arches no
	-- matter how the springs were tuned.
	--
	-- 0.012 x 18 crates = 21.6% extra mass at a fully upgraded full load.
	-- Sag is proportional to mass, so that turns the 1.46 studs the empty
	-- truck sits at into 1.79, against 2.45 studs of travel - i.e. a loaded
	-- BoxTruck still keeps 0.66 studs of bump travel in hand, where the
	-- Pickup's numbers leave it none at all. The truck visibly settles when
	-- you load it and never bottoms out, which is exactly the late-game
	-- "this thing is built for work" read.
	--
	-- It also means weight is no longer the thing that punishes a full load
	-- here - the two multipliers below are, and they are the knobs to move if
	-- a laden BoxTruck feels too easy.
	CargoMassFractionPerUnit = 0.012,
	-- Deceleration is BrakeFriction * gravity, so 0.7 turns this truck's
	-- 102-stud stop from 100 studs/s into a 146-stud one when fully laden.
	-- That is the single biggest reason to slow down before a tight turn.
	CargoLoadedBrakeMultiplier = 0.7,
	-- Mild on purpose. The load's raised centre of mass (the ballast sits at
	-- bed height) already makes a full truck lean and feel unwilling to turn,
	-- so a big grip cut on top of that reads as ice rather than as weight.
	CargoLoadedGripMultiplier = 0.88,


	-- Where each mirror points, in degrees - see DEFAULT_MIRRORS in
	-- VehiclePhysics for what the numbers mean and how they merge (per mirror,
	-- then per field, so you can override just one value and keep the rest).
	-- Inherited from PickupTruck as a starting point - re-check by eye from
	-- the driver's seat once this truck's own cab/mirror models are in place.
	BodyStrength = 1,

	-- Tail-light/turn-signal glow. DEFAULTS' Brightness (0.5, shared with the
	-- headlights) and Range (1, i.e. the base 12 studs) are bright/far enough
	-- to wash out a short cab from the rear brake lights, so both are cut
	-- further here - TailLightBrightness overrides just the rear/turn-signal
	-- PointLights, leaving the headlights at the normal LightBrightness.
	TailLightBrightness = 0.5,
	LightRange = 0.5,

	-- Horn (H). Server-played and audible to every player in the game, from
	-- this car's position - see VehicleHorn.server.luau. Swap this id to give
	-- this car its own horn; VehiclePhysics.Defaults has the shared fallback,
	-- so a new car that says nothing here still honks.
	HonkSoundId = "rbxassetid://127513531122725",

	Mirrors = {
		-- Pitch 20 (5 more than the Pickup's) and Outboard 1: the box body is
		-- tall and wide, so the mirror looks from a stud further out and a bit
		-- further down to show road rather than the truck's own flank.
		LeftMirror = { Yaw = -15, Pitch = 20, Outboard = 1 },
		RightMirror = { Yaw = 15, Pitch = 20, Outboard = 1 },
		RearViewMirror = { Yaw = 0, Pitch = 4 },
	},

	SteerAngle = 40,

	-- Speed-sensitive steering, and the cure for the truck scrubbing off
	-- speed the moment you turn while coasting. See VehiclePhysics'
	-- OPTIONAL_KEYS comment for the full explanation - inherited unchanged
	-- from PickupTruck.
	HighSpeedSteerAngle = 12,
	SteerAngleFalloffSpeed = 55,
	DriveWheels = "Rear",

	-- BoxTruck uses two different wheel meshes - a front and a rear model -
	-- rather than one shared WheelModelName, so each axle gets its own
	-- override (see VehiclePhysics.GetWheelModelName/GetWheelRadius). These
	-- name models under ReplicatedStorage.Wheels:
	--   ReplicatedStorage.Wheels.BoxTruckFrontWheel
	--   ReplicatedStorage.Wheels.BoxTruckRearWheel
	FrontWheelModelName = "BoxTruckFrontWheel",
	RearWheelModelName = "BoxTruckRearWheel",
	-- Half of each mesh's Size.Y/Z (BoxTruckFrontWheel is 1.042, 3.653, 3.653;
	-- BoxTruckRearWheel is 2.049, 3.653, 3.653 - same 3.653 diameter as the
	-- front, just a wider tire on X, which doesn't affect radius).
	FrontWheelRadius = 1.8265,
	RearWheelRadius = 1.8265,
	-- SUSPENSION. These three are one set - changing any one of them alone
	-- will undo the other two. The whole derivation, because the inherited
	-- Pickup numbers put this truck in the air and shook it:
	--
	-- 1. WHERE THE TRUCK RESTS. At equilibrium VehiclePhysics balances the
	--    spring against gravity, which lands the strut at
	--        sag = (AssemblyMass / 4) * gravity / (Stiffness * 60)
	--            = 0.8175 * AssemblyMass / Stiffness      (studs, gravity 196.2)
	--    and the wheel then hangs (SuspensionMaxLength - sag) below its
	--    attachment, because UpdateWheelVisuals welds it at exactly the
	--    spring length. That leftover is DROOP, and it is the whole "the
	--    truck is really high" bug: the chassis floats that far above the
	--    pose the model was built in, and the wheels dangle that far under
	--    the arches.
	--
	--    Inherited (at the mass of 170 first assumed): 0.8175 * 170 / 70 =
	--    1.98 studs of sag against 3.5 of travel = 1.5 studs of droop. That is most of a wheel radius of
	--    daylight, on a truck whose wheels are only 1.83 in radius.
	--
	-- 2. DROOP IS NOT FREE TO REMOVE. Droop is also the ONLY compression
	--    headroom the truck has: loading cargo and hitting bumps both have to
	--    fit inside it. So it cannot be tuned to zero, only to the smallest
	--    value that still swallows a full load plus a kerb - which is why
	--    CargoMassFractionPerUnit above had to come down first. It is a
	--    genuine three-way trade between ride height, load capacity and bump
	--    travel, and the Pickup's numbers lose all three on this chassis.
	--
	-- 3. THE NUMBERS. Travel 2.45, sag 1.47, so 0.98 studs of droop - and
	--    none of it shows, because the wheel attachments were raised by the
	--    same amount (see 5): hanging 0.98 below a mount at Y -0.5 puts each
	--    wheel centre at -1.48, which is where the wheels are modelled. Of
	--    the 0.98, 0.32 is spent sagging under a fully upgraded full load and
	--    0.66 stays as bump travel.
	--
	--    Stiffness then follows from wanting sag = 1.47 at mass 216:
	--        Stiffness = 0.8175 * 216 / 1.47 = 120
	--
	-- 4. THE JITTER. Damper is a per-frame impulse against a spring that is
	--    integrated explicitly, so "how much bounce is left" and "how close
	--    to shaking itself apart" are the same dial - see the Damper ladder
	--    above for the arithmetic. Two things had to change together here:
	--    the stiffer spring rings at a HIGHER frequency than the Pickup's, so
	--    the same Damper 5 leaves it visibly less damped (zeta 0.31 against
	--    the Pickup's 0.36), and a long, tall, top-heavy box body is the
	--    worst possible thing to leave underdamped. Damper 7.5 puts zeta at
	--    0.36 and holds the stability sum at 120 + 900 = 1020, or 0.63 of
	--    the 1620 limit.
	--
	--    Anything left after this is NOT coming from these three numbers, and
	--    turning Damper up further will make it worse rather than better -
	--    check BodyLean below first, then the model itself.
	--
	-- 5. WHERE THE WHEEL ATTACHMENTS GO - the model rule every number above
	--    depends on. Each suspension ray STARTS at its Wheel attachment, and a
	--    Roblox raycast that starts inside a part does not hit that part. So
	--    an attachment hanging below the Chassis' bottom face (this truck's
	--    were at Y -1.47, 0.9 under it) can be pushed inside the road by any
	--    hard landing or big bump; from there every ray passes straight
	--    through the road to whatever is under it, the springs think the
	--    ground has dropped away, and the truck ends up lying on its hulls on
	--    the asphalt with the wheels dangling. That was the "wheels sit low"
	--    look AND the jitter over bumps and in turns - the hulls scraping the
	--    road while the springs fought them.
	--
	--    Keep every Wheel attachment INSIDE the Chassis (Y between -0.566 and
	--    +0.566 here). The chassis collides with the road, so it can never be
	--    below it, and neither can a ray that starts inside it. Ride height
	--    is then set here, not in the model:
	--        wheel centre at rest = attachment Y - (SuspensionMaxLength - sag)
	--    Moving the attachments means changing SuspensionMaxLength by the
	--    same amount to keep the wheels where they are.
	SuspensionMaxLength = 2.45,
	Stiffness = 120,
	Damper = 7.5,
	-- 0-1: how far down a tire's grip/drive/brake force is applied - 1 at the
	-- contact patch, 0 at the strut mount. It is a feel knob (DEFAULTS
	-- explains it in full), but on THIS chassis it is also a stability one,
	-- and it is the second half of the jitter fix.
	--
	-- The lever it acts through is much longer here than on any other car in
	-- the game: the contact patch sits about 3.3 studs below the chassis
	-- plate (0.5 to the strut mount, ~1 of spring, 1.83 of wheel radius), while
	-- the mass it is levering is a tall box body sitting ABOVE that plate. On
	-- top of which the rear track is narrow - the rear attachments are at
	-- +-2.58 against the front's +-3.83 - so the same sideways impulse rolls
	-- the back of the truck noticeably harder than the front. Roll moves the
	-- struts, the struts answer with more impulse, and at BodyLean 1 that
	-- loop is tight enough to buzz on a truck this shape.
	--
	-- 0.5 keeps half the squat/dive/lean (a box truck SHOULD wallow - it is
	-- most of what makes it feel loaded) and takes the top off that
	-- feedback: the grip impulse lands halfway between the strut mount and
	-- the patch, which roughly halves the lever it rolls the body through.
	-- Raise it toward 0.75 if the truck feels too flat in corners; lower it
	-- toward 0.3 before touching Damper if it still shivers in them.
	BodyLean = 0.5,
	-- Torque is the ROLLING acceleration knob only - the standstill shove
	-- comes from Transmission.StallTorqueMultiplier below. See PickupTruck.luau
	-- for the full derivation; inherited unchanged pending this truck's own mass.
	Torque = 10,

	-- studs/s in TOP gear, and the number every SpeedFraction below is
	-- measured against - so this is the one knob that compresses or stretches
	-- the whole gearbox at once.
	MaxSpeed = 100,

	-- Steering feel. Inherited from PickupTruck - re-tune once this truck's
	-- own cab/steering wheel prop is in place.
	SteerSpeed = 1.3,
	SteerReturnSpeed = 2,

	-- Steering wheel prop in the cab. 400 degrees at full lock: a bit past
	-- a full turn, so the rim passes its starting orientation and ends up
	-- 40 degrees around.
	SteeringWheelMaxAngle = 400,
	-- Auto-detected from the wheel part's own proportions - see DEFAULTS. If
	-- the wheel ends up spinning the right way round its column but mirrored,
	-- set SteeringWheelInvert = true rather than touching the axis.
	SteeringWheelInvert = false,
	SteeringWheelAxis = "Auto",

	-- Traction effects. A loaded truck's tires are working harder than a
	-- light car's, so they let go a little sooner, but the car-speed gate is
	-- raised: this thing spends its life creeping around at parking speeds
	-- and nudging kerbs, and none of that should ever screech.
	TractionSlipThreshold = 6.5,
	TractionMinCarSpeed = 12,

	-- Handbrake (Space). Rear-locking, which is what lets you flick the back
	-- end out mid-corner rather than just stopping in a straight line.
	HandbrakeGripMultiplier = 0.16,
	HandbrakeLockFriction = 0.4,

	-- Foot brake (S). See PickupTruck.luau for the stopping-distance
	-- derivation this was copied from.
	BrakeFriction = 0.25,
	BrakeRampTime = 0.45, -- pedal travel. Longer than DEFAULTS: heavy truck, soft pedal, so a tap is genuinely a tap rather than a stab

	-- Gas pedal travel, and the main cure for the lurch out of reverse.
	ThrottleRampTime = 0.5,

	-- Lifting off W should let the truck cruise, not brake. At 0.05 it sheds
	-- about 5% of its speed per second, so momentum carries a long way and
	-- you coast between throttle inputs instead of having to feather W.
	CoastDrag = 0.05,

	-- 6-speed automatic. See VehiclePhysics.DefaultTransmission for what every
	-- key means; only the keys listed here override it, so the timing values
	-- not mentioned (IdleRpm, RpmSmoothing, pitch range) come from there.
	-- Gear ratios/speed fractions copied from PickupTruck unchanged - re-derive
	-- once this truck's own MaxSpeed/Torque are tuned (see the Gears comment
	-- in PickupTruck.luau for the formula that keeps shift points lined up).
	Transmission = {
		StartingGear = "D", -- sit down and press W. There is no neutral any more, and no lever to move
		ShiftTime = 0.55, -- a truck's box is slow and deliberate; drive is fully cut for this whole window
		ShiftUpAt = 0.75,
		ShiftDownAt = 0.42,

		StallTorqueMultiplier = 2.4,
		StallSpeed = 3,

		-- A loaded truck should take a beat to commit to changing direction,
		-- and it stops the car flipping into reverse the moment a player
		-- brakes a fraction too long at a drop-off.
		AutoReverseDelay = 0.55,

		IdlePitch = 0.55, -- lower than DEFAULTS' 0.7 - a loaded diesel idles with a deeper, lower-revving note than a car engine
		MaxPitch = 1.15, -- a diesel truck should never sound like it is screaming; well below DEFAULTS' 1.45

		Gears = {
			{ Ratio = 3.20, SpeedFraction = 0.24 }, -- 1st: the kerb-climbing, pulling-away gear
			{ Ratio = 2.27, SpeedFraction = 0.36 },
			{ Ratio = 1.69, SpeedFraction = 0.50 },
			{ Ratio = 1.32, SpeedFraction = 0.65 },
			{ Ratio = 1.05, SpeedFraction = 0.82 },
			{ Ratio = 0.86, SpeedFraction = 1.00 }, -- 6th: overdrive, and the only gear that reaches MaxSpeed
		},

		Reverse = { Ratio = 2.6, SpeedFraction = 0.45 },
	},
}

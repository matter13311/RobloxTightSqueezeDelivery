-- Starting point - copied from PickupTruck.luau and not yet tuned for this
-- truck's own chassis. Neither suspension force nor Torque scale with mass
-- (see VehiclePhysics.Step), so a heavier/lighter chassis than the Pickup's
-- will want proportionally different values than what's inherited here -
-- tune by feel once the model and wheels are in.
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
		Stiffness = {
			DisplayName = "Springs",
			IconId = "rbxassetid://81458577246421",
			Max = 110,
			Step = 10,
			BaseCost = 120,
			CostGrowth = 1.4,
			Description = "How firm the suspension springs are. Higher Stiffness keeps the truck flatter and steadier through turns; lower feels bouncier and leans more.",
		},
		-- Max is held well under the point where the suspension goes
		-- unstable (around 15 on this chassis - see the Damper note in
		-- VehiclePhysics.Defaults). Do not raise it without re-testing for
		-- the car shivering left-to-right at rest or after a landing.
		Damper = {
			DisplayName = "Smooth Ride",
			IconId = "rbxassetid://113834210436142",
			Max = 9,
			Step = 1,
			BaseCost = 130,
			CostGrowth = 1.5,
			Description = "How quickly the suspension settles after a bump. Higher Damper stops the truck bouncing for as long after landing a jump or hitting a pothole.",
		},
		SuspensionMaxLength = {
			DisplayName = "Suspension",
			IconId = "rbxassetid://89709264264758",
			Max = 4.5,
			Step = 0.25,
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
			Max = 10,
			Step = 1,
			BaseCost = 250,
			CostGrowth = 1.45,
			Description = "How many crates fit in the bed. Every crate you carry is more money on delivery, but also more weight - a full load leans harder in turns and takes noticeably longer to stop.",
		},
	},

	-- Cargo. See docs/CargoDesign.md; CargoLoad.luau explains why the two
	-- multipliers below have to exist at all when we are also adding real mass.
	CargoCapacity = 4, -- MUST equal the Upgrades entry's Min above
	-- THE master weight dial. It is the number to move if loaded driving feels
	-- too tame or too punishing overall - the two multipliers below only shape
	-- braking and cornering, while this one drives the sag, the sluggishness
	-- off the line and how hard the truck shoves in a collision.
	CargoMassFractionPerUnit = 0.07,
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
		LeftMirror = { Yaw = -15, Pitch = 15 },
		RightMirror = { Yaw = 15, Pitch = 15 },
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
	SuspensionMaxLength = 3.5, -- DEFAULTS is 2 - more travel to compress into, so accel/brake squat and bumps have room to show instead of instantly maxing out the spring
	Stiffness = 70, -- softened back down now that SuspensionMaxLength gives it more room - still enough to hold the truck's weight without bottoming out at rest
	Damper = 5, -- lowered relative to Stiffness (was matched 1:1-ish) so it's underdamped enough to actually bounce instead of just clamping to ride height
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

		MaxPitch = 1.35, -- a diesel truck should never sound like it is screaming; below DEFAULTS' 1.45

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

-- Starting point - tune by feel. Neither suspension force nor Torque scale
-- with mass (see VehiclePhysics.Step), so a heavier car chassis needs
-- proportionally more of both than DEFAULTS just to hold ride height and
-- accelerate at a normal rate - bumped up from DEFAULTS accordingly.
return {
	-- The grindy per-car upgrade ladder (see VehicleUpgrades.luau for the
	-- math, and PlayerDataStore.luau for how a player's purchased levels and
	-- chosen slider values are saved).
	--
	-- There is NO Min here, on purpose. Every key in this table must also be
	-- a plain numeric field further down the file, and that field IS the
	-- ladder's Min - it's the level-0/no-upgrades-bought value a fresh
	-- StarterVehicle starts with, so the two are the same number by definition.
	-- VehiclePhysics.GetUpgradeSpecs fills it in from there, which is why
	-- re-tuning a stat below automatically re-bases its ladder here. Writing
	-- it in both places is what let this car's Torque ladder go on claiming
	-- a level-0 of 25 after the car itself had been tuned down to 15.
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
		Torque = {
			Min = 25,
			Max = 50,
			Step = 5,
			BaseCost = 150,
			CostGrowth = 1.5,
			Description = "How hard the engine pulls when you hit the gas. Higher Torque means quicker acceleration and an easier time powering up over kerbs and ramps.",
		},
		MaxSpeed = {
			Max = 70,
			Step = 5,
			BaseCost = 200,
			CostGrowth = 1.5,
			Description = "The cars's top speed in a straight line. Higher Max Speed lets you go faster once you're up to full speed, but doesn't change how quickly you get there.",
		},
		SteerAngle = {
			Max = 52,
			Step = 4,
			BaseCost = 100,
			CostGrowth = 1.4,
			Description = "How sharply the front wheels can turn. Higher Steer Angle gives you a tighter turning circle, which helps a lot for threading tight gaps and parking.",
		},
		Stiffness = {
			-- 115, not the 110 this said before: Min is 55 and Step is 10, so
			-- 110 was half a notch short of a level boundary and the top
			-- buyable notch was really 115 anyway (VehicleUpgrades.MaxLevel
			-- rounds 5.5 up to 6). Only the number written here changes -
			-- what a player can actually buy is exactly what it was.
			Max = 115,
			Step = 10,
			BaseCost = 120,
			CostGrowth = 1.4,
			Description = "How firm the suspension springs are. Higher Stiffness keeps the car flatter and steadier through turns; lower feels bouncier and leans more.",
		},
		Damper = {
			Max = 9,
			Step = 1,
			BaseCost = 130,
			CostGrowth = 1.5,
			Description = "How quickly the suspension settles after a bump. Higher Damper stops the car bouncing for as long after landing a jump or hitting a pothole.",
		},
		SuspensionMaxLength = {
			Max = 4.5,
			Step = 0.25,
			BaseCost = 110,
			CostGrowth = 1.4,
			Description = "How much travel the suspension has to work with. More Suspension Length soaks up bigger bumps and landings before the car bottoms out.",
		},
		TractionSlipThreshold = {
			Max = 8.5,
			Step = 0.5,
			BaseCost = 90,
			CostGrowth = 1.3,
			Description = "How much a tire can slide before it's treated as slipping. Higher Wheel Traction lets you push harder into corners before the tires break loose.",
		},
		BrakeFriction = {
			Max = 0.45,
			Step = 0.05,
			BaseCost = 100,
			CostGrowth = 1.4,
			Description = "How hard the brakes bite. Higher Brake Speed stops the car in a shorter distance when you hit the brake pedal.",
		},
		-- The one upgrade that directly raises earnings rather than making the
		-- car nicer to drive, and deliberately the most expensive ladder
		-- here - every other stat only helps you SURVIVE a heavy load, so this
		-- is what those upgrades are ultimately bought in service of.
		--
		-- Unlike every other stat on this list, the slider is not really a
		-- choice: nobody wants to carry less than they can. It stays a slider
		-- for consistency with the rest of the terminal, and because carrying
		-- deliberately light IS occasionally right - a Glassware run over bad
		-- ground pays better half-empty and intact than full and smashed.
		CargoCapacity = {
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
	-- At capacity 10 and this fraction, a full load of ordinary Parcels very
	-- nearly doubles the car's mass. That is the number to move if loaded
	-- driving feels too tame or too punishing overall - the two multipliers
	-- below only shape braking and cornering, while this one drives the sag,
	-- the sluggishness off the line and how hard it shoves in a collision.
	CargoMassFractionPerUnit = 0.10,
	-- Deceleration is BrakeFriction * gravity, so 0.7 turns this car's
	-- 102-stud stop from 100 studs/s into a 146-stud one when fully laden.
	-- That is the single biggest reason to slow down before a tight turn.
	CargoLoadedBrakeMultiplier = 0.7,
	-- Mild on purpose. The load's raised centre of mass (the ballast sits at
	-- bed height) already makes a full car lean and feel unwilling to turn,
	-- so a big grip cut on top of that reads as ice rather than as weight.
	CargoLoadedGripMultiplier = 0.88,


	-- Where each mirror points, in degrees - see DEFAULT_MIRRORS in
	-- VehiclePhysics for what the numbers mean and how they merge (per mirror,
	-- then per field, so you can override just one value and keep the rest).
	--
	-- Yaw swings the view outward from straight-back; the sign that means
	-- "outward" depends on the chassis' forward axis, and on this truck that
	-- works out to negative on the left and positive on the right. Pitch tilts
	-- it down toward the road. Tuned by eye from the driver's seat: enough yaw
	-- to get the truck's own flank out of the way, enough pitch to see kerbs
	-- rather than sky.
	Mirrors = {
		LeftMirror = { Yaw = -15, Pitch = 15 },
		RightMirror = { Yaw = 15, Pitch = 15 },
		RearViewMirror = { Yaw = 0, Pitch = 4 },
	},

	SteerAngle = 40,

	-- Speed-sensitive steering, and the cure for the car scrubbing off
	-- speed the moment you turn while coasting. A steered tire's grip force
	-- is perpendicular to the WHEEL, so sin(steer) of it points backwards
	-- along the car - at 40 degrees that is 64% of a cornering force the tires
	-- are allowed to make 1.5g of, which is more deceleration than the brake
	-- pedal produces. Full lock stays available where this car actually
	-- needs it (threading gaps and backing onto driveways at walking pace) and
	-- tapers to a cruising amount by 55 studs/s.
	--
	-- TUNING: still losing too much speed mid-corner? Lower HighSpeedSteerAngle
	-- or SteerAngleFalloffSpeed. Turning circle at speed feel too lazy? Raise
	-- them. Setting HighSpeedSteerAngle = nil restores the old behaviour.
	HighSpeedSteerAngle = 12,
	SteerAngleFalloffSpeed = 55,
	DriveWheels = "Rear",
	WheelModelName = "StarterVehicleWheel",
	WheelRadius = 1.25, -- half of StarterVehicleWheel's 2.5-stud Size.Y/Z - must track that mesh's actual size, not DEFAULTS' 1.5
	SuspensionMaxLength = 3, -- DEFAULTS is 2 - more travel to compress into, so accel/brake squat and bumps have room to show instead of instantly maxing out the spring
	Stiffness = 55, -- softened back down now that SuspensionMaxLength gives it more room - still enough to hold the car's weight without bottoming out at rest
	Damper = 5, -- lowered relative to Stiffness (was matched 1:1-ish) so it's underdamped enough to actually bounce instead of just clamping to ride height
	-- Torque is the ROLLING acceleration knob only. It used to be both that
	-- and the standstill shove, which is why 50 made the car leap off the
	-- line and blow through the first five gears in a couple of seconds. The
	-- standstill shove now comes from Transmission.StallTorqueMultiplier
	-- below, so this can be low for slow, deliberate driving in tight spaces
	-- without leaving the car unable to pull itself up a kerb.
	--
	-- TUNING: how long a gear lasts is proportional to
	--     chassis mass * (that gear's top speed) / (Torque * that gear's Ratio)
	-- and a gear's top speed is SpeedFraction * MaxSpeed. So MaxSpeed and
	-- Torque pull on gear duration in exactly opposite directions, and that is
	-- the whole reason this is 7.5 rather than 15: dropping MaxSpeed from 100
	-- to 50 halved every gear's top speed, which halved how long each one
	-- lasts, which is what turned ordinary acceleration into a machine-gun of
	-- shifts. Halving Torque with it puts the timing back exactly where it
	-- was. Change MaxSpeed again and move this by the same factor.
	--
	-- The standstill shove is NOT lost with it, because it was compensated
	-- for in StallTorqueMultiplier below (doubled to 4.8 when this halved) -
	-- launch force is Torque * 1st Ratio * StallTorqueMultiplier, and
	-- 7.5 * 3.2 * 4.8 is the same 115 it was at 15 * 3.2 * 2.4, so
	-- kerb-climbing is untouched. Move one of those two, move the other the
	-- opposite way.
	Torque = 7.5,

	-- studs/s in TOP gear, and the number every SpeedFraction below is
	-- measured against - so this is the one knob that compresses or stretches
	-- the whole gearbox at once. 50 studs/s is ~31 mph: deliberately slow,
	-- this being the cheap starter car in a game about threading gaps rather
	-- than about speed.
	--
	-- Two things have to move WITH it, or the car shifts constantly: Torque
	-- above (gear duration scales with MaxSpeed - see the note there) and the
	-- number of Gears below (50 studs/s sliced six ways is an 8-studs/s gear).
	-- Note also that drive force fades to zero AT MaxSpeed, so the last
	-- stretch of any MaxSpeed always crawls.
	MaxSpeed = 50,

	-- Steering feel. DEFAULTS' 5 reaches full lock in a fifth of a second,
	-- which on a car reads as the front axle snapping sideways. 2 takes
	-- half a second to wind on full lock, so threading a gap becomes a
	-- deliberate input rather than a twitch. Re-centring stays quicker than
	-- turning in, which is what a real car's castor does on its own.
	--
	-- This is separate from SteerAngle (how far the wheels actually point) -
	-- turn this down for heavier steering, that one down for a wider circle.
	SteerSpeed = 2,
	SteerReturnSpeed = 3.5,

	-- Steering wheel prop in the cab. 180 degrees at full lock: clearly a
	-- wheel being turned rather than the token 30-degree nudge most games
	-- use, but nowhere near the ~450 a real car does, which in first person
	-- would have the wheel whirling every time a player taps A.
	SteeringWheelMaxAngle = 180,
	-- Auto-detected from the wheel part's own proportions - see DEFAULTS. If
	-- the wheel ends up spinning the right way round its column but mirrored,
	-- set SteeringWheelInvert = true rather than touching the axis.
	SteeringWheelInvert = false,
	SteeringWheelAxis = "Auto",

	-- Traction effects. A loaded car's tires are working harder than a
	-- light car's, so they let go a little sooner, but the car-speed gate is
	-- raised: this thing spends its life creeping around at parking speeds
	-- and nudging kerbs, and none of that should ever screech.
	TractionSlipThreshold = 6.5,
	TractionMinCarSpeed = 12,

	-- Handbrake (Space). Rear-locking, which is what lets you flick the back
	-- end out mid-corner rather than just stopping in a straight line.
	HandbrakeGripMultiplier = 0.16, -- a heavy car on locked rears should slide a long way once it goes - lower than DEFAULTS' 0.18. THIS is the number that controls the skid; the one below only controls how fast the handbrake slows you down
	-- Dropped from 0.75 alongside BrakeFriction below. The handbrake locks
	-- one axle, so the deceleration it produces is half this (0.20) - it has
	-- to stay under BrakeFriction (0.25) or yanking the handbrake would stop
	-- the car quicker than the brake pedal, which feels wrong to drive.
	-- The slide itself is unchanged: that comes from the grip multiplier.
	HandbrakeLockFriction = 0.4,

	-- Foot brake (S). The progression here: 1.7 stopped the car from 100
	-- studs/s in 0.30s over 15 studs (a wall), 0.45 gave 1.13s over 57 studs
	-- (still abrupt), 0.25 gives 2.04s over 102 studs - a loaded car you
	-- have to plan a stop for. Formula is in VehiclePhysics' BrakeFriction
	-- comment if you want to dial an exact stopping distance.
	BrakeFriction = 0.25,
	BrakeRampTime = 0.45, -- pedal travel. Longer than DEFAULTS: heavy car, soft pedal, so a tap is genuinely a tap rather than a stab

	-- Gas pedal travel, and the main cure for the lurch out of reverse. Longer
	-- than DEFAULTS' 0.35: a loaded car leans into its power, it doesn't
	-- snap into it. Full torque still arrives - it just takes half a second,
	-- by which time the car is already rolling and the stall multiplier has
	-- faded, so the spike never lands. Pushing against a kerb you hold W for
	-- far longer than this, so kerb-climbing is untouched.
	ThrottleRampTime = 0.5,

	-- Lifting off W should let the car cruise, not brake. At 0.05 it sheds
	-- about 5% of its speed per second, so momentum carries a long way and
	-- you coast between throttle inputs instead of having to feather W.
	CoastDrag = 0.05,

	-- 6-speed automatic. See VehiclePhysics.DefaultTransmission for what every
	-- key means; only the keys listed here override it, so the timing values
	-- not mentioned (IdleRpm, RpmSmoothing, pitch range) come from there.
	--
	-- Reading the gear list: Ratio multiplies Torque, SpeedFraction is the
	-- share of MaxSpeed that gear tops out at. They move in opposite
	-- directions on purpose - 1st has over 3x the shove but runs out of pull
	-- by 16 studs/s, top gear pulls softly but is the only one that can reach
	-- MaxSpeed. That trade is what makes a gearbox feel like one instead of a
	-- free power boost, and it's why the last gear MUST be SpeedFraction 1.0.
	Transmission = {
		StartingGear = "D", -- sit down and press W. There is no neutral any more, and no lever to move
		ShiftTime = 0.55, -- a car's box is slow and deliberate; drive is fully cut for this whole window
		-- Shift points, as a fraction of each gear's own top speed. Raised
		-- from 0.62 so every gear is held noticeably longer before handing
		-- over: shifts now land at 18.0 / 27.0 / 37.5 / 48.8 / 61.5 studs/s
		-- instead of 14.9 / 22.3 / 31.0 / 40.3 / 50.8.
		--
		-- 0.75 is past the point where the next gear would out-pull this one
		-- (~0.55), and that's deliberate - it's what makes the engine strain
		-- and the revs climb near the top of a gear before the shift, rather
		-- than swapping over the instant it becomes mathematically optimal.
		-- The outgoing gear still has 25% of its torque left at that point,
		-- so it never bogs. Don't push much past 0.85: torque fades to zero
		-- AT a gear's top speed, so a very late shift means crawling the last
		-- stretch of every gear on almost no power.
		ShiftUpAt = 0.75,
		ShiftDownAt = 0.42,


		-- Strong shove from rest, gentle once rolling. See the Torque comment
		-- above - these two numbers are what let that be a low number.
		--
		-- StallSpeed matters as much as the multiplier: at 6 the boost was
		-- still helping at 6 studs/s, which is nearly half of 1st gear, so 1st
		-- got shoved through before you noticed it. At 3 the boost is spent
		-- almost immediately and 1st does its own work for the rest of it.
		-- Dropped from 3.5. Combined with ThrottleRampTime below, this is what
		-- stops the car leaping forward the moment it drops into D with W
		-- already held - the flip happens at a dead standstill, which is
		-- exactly where the stall multiplier peaks, so it was the single
		-- biggest force spike in the drivetrain landing at the worst moment.
		-- Doubled from 2.4 when Torque halved to 7.5, so the shove out of a
		-- standstill is unchanged: 7.5 * 3.2 * 4.8 = 115, the same as the old
		-- 15 * 3.2 * 2.4. This is the number that stops a low Torque costing
		-- the car its ability to pull itself up a kerb from rest.
		StallTorqueMultiplier = 4.8,
		StallSpeed = 3,

		-- A loaded car should take a beat to commit to changing direction,
		-- and it stops the car flipping into reverse the moment a player
		-- brakes a fraction too long at a drop-off.
		AutoReverseDelay = 0.55,

		MaxPitch = 1.35, -- a diesel car should never sound like it is screaming; below DEFAULTS' 1.45

		-- FOUR gears, down from six. Halving Torque above fixes how FAST the
		-- shifts come; this fixes how MANY of them there are. A gear covers
		-- SpeedFraction * MaxSpeed studs/s, so six gears over a 50 studs/s
		-- range is an 8-studs/s gear - the box was running out of ratios
		-- before the car was out of a car park. Four gives 15 / 25 / 36.5 / 50
		-- studs/s, so the shifts land at 11.3, 18.8 and 27.4 studs/s and top
		-- gear covers the whole upper half of the car's speed range.
		--
		-- Every ratio after 1st is derived so the next gear starts out-pulling
		-- the current one at 0.55 of its top speed - just under ShiftUpAt, so
		-- each shift hands over to a gear that pulls HARDER, never one that
		-- bogs. Change a SpeedFraction and the ratios need re-deriving with
		-- it, or the shift points stop lining up with where the next gear
		-- actually takes over:
		--     0.45 * Ratio[i] = Ratio[i+1] * (1 - 0.55 * Frac[i] / Frac[i+1])
		--
		-- 1st is left at 3.20 rather than derived: it is the kerb-climbing
		-- gear, and how hard it pulls from rest is a feel decision.
		Gears = {
			{ Ratio = 3.20, SpeedFraction = 0.30 }, -- 1st: the kerb-climbing, pulling-away gear. Tops out at 15 studs/s
			{ Ratio = 2.15, SpeedFraction = 0.50 }, -- 2nd: 25 studs/s
			{ Ratio = 1.55, SpeedFraction = 0.73 }, -- 3rd: 36.5 studs/s
			{ Ratio = 1.17, SpeedFraction = 1.00 }, -- 4th: the only gear that reaches MaxSpeed
		},

		-- Reverse, and the ONLY two numbers that set how fast this car backs
		-- up - there is no separate reverse speed setting anywhere else:
		--   SpeedFraction  top reverse speed as a share of MaxSpeed. THIS is
		--                  the knob to raise. 0.70 * 50 = 35 studs/s.
		--   Ratio          how hard it pulls on the way there, on top of
		--                  Torque. Kept just under 1st gear's 3.20 so pulling
		--                  away forwards is still the strongest launch in the
		--                  car.
		-- Reverse has no gearbox of its own, so unlike D this single ratio
		-- covers its whole speed range, and its revs are measured against that
		-- full range rather than against a shift point.
		Reverse = { Ratio = 2.6, SpeedFraction = 0.70 },
	},
}

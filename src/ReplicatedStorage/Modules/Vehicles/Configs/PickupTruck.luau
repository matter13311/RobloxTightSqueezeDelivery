-- Starting point - tune by feel. Neither suspension force nor Torque scale
-- with mass (see VehiclePhysics.Step), so a heavier truck chassis needs
-- proportionally more of both than DEFAULTS just to hold ride height and
-- accelerate at a normal rate - bumped up from DEFAULTS accordingly.
return {
	WheelModelName = "PickupTruckWheel",
	WheelRadius = 1.8485, -- half of PickupTruckWheel's 3.697-stud Size.Y/Z - must track that mesh's actual size, not DEFAULTS' 1.5
	SuspensionMaxLength = 3.5, -- DEFAULTS is 2 - more travel to compress into, so accel/brake squat and bumps have room to show instead of instantly maxing out the spring
	Stiffness = 70, -- softened back down now that SuspensionMaxLength gives it more room - still enough to hold the truck's weight without bottoming out at rest
	Damper = 5, -- lowered relative to Stiffness (was matched 1:1-ish) so it's underdamped enough to actually bounce instead of just clamping to ride height
	-- Torque is now the ROLLING acceleration knob only. It used to be both
	-- that and the standstill shove, which is why 50 made the truck leap off
	-- the line and blow through the first five gears in a couple of seconds.
	-- The standstill shove now comes from Transmission.StallTorqueMultiplier
	-- below, so this can be low for slow, deliberate driving in tight spaces
	-- without leaving the truck unable to pull itself up a kerb.
	-- 14 * 3.2 (1st) * 3.5 (stall) = 157 at a dead stop, on par with the
	-- original 50 * 3.2 = 160, so kerb-climbing is untouched; once rolling
	-- past StallSpeed it is 14 * 3.2 = 45, well under a third of the original.
	--
	-- TUNING: how long each gear lasts scales as (chassis mass / Torque), and
	-- nothing else here changes it. Still shifting too eagerly? Halve Torque.
	-- Too sluggish? Raise it. The standstill shove stays put either way as
	-- long as you move StallTorqueMultiplier the opposite way.
	Torque = 14,

	-- studs/s in TOP gear, and the number every SpeedFraction below is
	-- measured against - so this is the one knob that compresses or stretches
	-- the whole gearbox at once. 100 studs/s is ~63 mph; for a game about
	-- threading a truck through tight gaps, 60-70 is probably closer to what
	-- you want, and it also makes top gear reachable in a sensible time
	-- (drive force fades to zero AT MaxSpeed, so the last stretch of any
	-- MaxSpeed always crawls - the higher this is, the longer that crawl).
	MaxSpeed = 100,

	-- Handbrake (Space). Rear-locking, which is what lets you flick the back
	-- end out mid-corner rather than just stopping in a straight line.
	HandbrakeGripMultiplier = 0.16, -- a heavy truck on locked rears should slide a long way once it goes - lower than DEFAULTS' 0.18. THIS is the number that controls the skid; the one below only controls how fast the handbrake slows you down
	-- Dropped from 0.75 alongside BrakeFriction below. The handbrake locks
	-- one axle, so the deceleration it produces is half this (0.20) - it has
	-- to stay under BrakeFriction (0.25) or yanking the handbrake would stop
	-- the truck quicker than the brake pedal, which feels wrong to drive.
	-- The slide itself is unchanged: that comes from the grip multiplier.
	HandbrakeLockFriction = 0.4,

	-- Foot brake (S). The progression here: 1.7 stopped the truck from 100
	-- studs/s in 0.30s over 15 studs (a wall), 0.45 gave 1.13s over 57 studs
	-- (still abrupt), 0.25 gives 2.04s over 102 studs - a loaded truck you
	-- have to plan a stop for. Formula is in VehiclePhysics' BrakeFriction
	-- comment if you want to dial an exact stopping distance.
	BrakeFriction = 0.25,
	BrakeRampTime = 0.45, -- pedal travel. Longer than DEFAULTS: heavy truck, soft pedal, so a tap is genuinely a tap rather than a stab

	-- Lifting off W should let the truck cruise, not brake. At 0.05 it sheds
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
		StartingGear = "N", -- you start in neutral and shift to D with E, like getting into a real truck. Change to "D" if you'd rather players just drive off
		ShiftTime = 0.45, -- a truck's box is slow and deliberate; drive is fully cut for this whole window
		ShiftUpAt = 0.62, -- shifts land at 14.9 / 22.3 / 31.0 / 40.3 / 50.8 studs/s
		ShiftDownAt = 0.42,

		-- Strong shove from rest, gentle once rolling. See the Torque comment
		-- above - these two numbers are what let that be a low number.
		--
		-- StallSpeed matters as much as the multiplier: at 6 the boost was
		-- still helping at 6 studs/s, which is nearly half of 1st gear, so 1st
		-- got shoved through before you noticed it. At 3 the boost is spent
		-- almost immediately and 1st does its own work for the rest of it.
		StallTorqueMultiplier = 3.5,
		StallSpeed = 3,

		NeutralMaxRpm = 0.35, -- a truck idling in neutral shouldn't sound anywhere near redline
		MaxPitch = 1.35, -- a diesel truck should never sound like it is screaming; below DEFAULTS' 1.45

		-- 1st stretched again (0.16 -> 0.20 -> 0.24) so it covers real ground:
		-- it now runs to 14.9 studs/s before handing over, instead of 9.9 when
		-- this started. Every later ratio is derived so the next gear starts
		-- out-pulling the current one at 0.55 of its top speed - just under
		-- ShiftUpAt, so each shift hands over to a gear that pulls HARDER,
		-- never one that bogs. Change a SpeedFraction and the ratios need
		-- re-deriving with it, or the shift points stop lining up with where
		-- the next gear actually takes over.
		Gears = {
			{ Ratio = 3.20, SpeedFraction = 0.24 }, -- 1st: the kerb-climbing, pulling-away gear
			{ Ratio = 2.27, SpeedFraction = 0.36 },
			{ Ratio = 1.69, SpeedFraction = 0.50 },
			{ Ratio = 1.32, SpeedFraction = 0.65 },
			{ Ratio = 1.05, SpeedFraction = 0.82 },
			{ Ratio = 0.86, SpeedFraction = 1.00 }, -- 6th: overdrive, and the only gear that reaches MaxSpeed
		},

		-- Reverse: both numbers cut. Ratio 2.8 -> 1.6 takes the shove out (it
		-- was pulling harder than 1st gear forwards), and SpeedFraction
		-- 0.25 -> 0.13 caps it at 13 studs/s, so backing up is a deliberate
		-- crawl. The stall boost still applies here, so 14 * 1.6 * 3.5 = 78
		-- from a standstill is plenty to reverse off a kerb.
		Reverse = { Ratio = 1.6, SpeedFraction = 0.13 },
	},
}

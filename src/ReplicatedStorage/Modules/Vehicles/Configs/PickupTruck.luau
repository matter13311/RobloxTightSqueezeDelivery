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
	Torque = 50, -- DEFAULTS is 10 - was accelerating far too slowly for the truck's weight
	MaxSpeed = 100, -- studs/s in TOP gear. Every gear's SpeedFraction below is measured against this, so raising it stretches the whole gearbox rather than just the last ratio

	-- Handbrake (Space). Rear-locking, which is what lets you flick the back
	-- end out mid-corner rather than just stopping in a straight line.
	HandbrakeGripMultiplier = 0.16, -- a heavy truck on locked rears should slide a long way once it goes - lower than DEFAULTS' 0.18
	HandbrakeLockFriction = 0.75,

	BrakeFriction = 1.7, -- foot brake (S). Slightly under DEFAULTS: a loaded truck doesn't stop like a sports car

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
		ShiftUpAt = 0.62, -- shifts land at roughly 10 / 19 / 29 / 40 / 51 studs/s
		ShiftDownAt = 0.42,
		Gears = {
			{ Ratio = 3.2, SpeedFraction = 0.16 }, -- 1st: hauling gear, gone almost immediately
			{ Ratio = 2.1, SpeedFraction = 0.30 },
			{ Ratio = 1.55, SpeedFraction = 0.46 },
			{ Ratio = 1.2, SpeedFraction = 0.64 },
			{ Ratio = 1.0, SpeedFraction = 0.82 },
			{ Ratio = 0.85, SpeedFraction = 1.00 }, -- 6th: overdrive, and the only gear that reaches MaxSpeed
		},
		Reverse = { Ratio = 2.8, SpeedFraction = 0.25 }, -- geared short: plenty of torque to back out of somewhere, but capped at a crawl
	},
}

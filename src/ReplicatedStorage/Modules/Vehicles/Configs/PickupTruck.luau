-- Starting point - tune by feel. Neither suspension force nor Torque scale
-- with mass (see VehiclePhysics.Step), so a heavier truck chassis needs
-- proportionally more of both than DEFAULTS just to hold ride height and
-- accelerate at a normal rate - bumped up from DEFAULTS accordingly.
return {
	WheelModelName = "PickupTruckWheel",
	WheelRadius = 1.8485, -- half of PickupTruckWheel's 3.697-stud Size.Y/Z - must track that mesh's actual size, not DEFAULTS' 1.5
	SuspensionMaxLength = 3.5, -- DEFAULTS is 2 - more travel to compress into, so accel/brake squat and bumps have room to show instead of instantly maxing out the spring
	Stiffness = 70, -- softened back down now that SuspensionMaxLength gives it more room - still enough to hold the truck's weight without bottoming out at rest
	Damper = 3, -- lowered relative to Stiffness (was matched 1:1-ish) so it's underdamped enough to actually bounce instead of just clamping to ride height
	Torque = 50, -- DEFAULTS is 10 - was accelerating far too slowly for the truck's weight
	MaxSpeed= 100
}

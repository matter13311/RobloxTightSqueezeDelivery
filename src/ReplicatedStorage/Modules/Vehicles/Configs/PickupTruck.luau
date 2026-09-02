-- Starting point - tune by feel. Neither suspension force nor Torque scale
-- with mass (see VehiclePhysics.Step), so a heavier truck chassis needs
-- proportionally more of both than DEFAULTS just to hold ride height and
-- accelerate at a normal rate - bumped up from DEFAULTS accordingly.
return {
	WheelModelName = "PickupTruckWheel",
	WheelRadius = 1.8485, -- half of PickupTruckWheel's 3.697-stud Size.Y/Z - must track that mesh's actual size, not DEFAULTS' 1.5
	Stiffness = 150, -- DEFAULTS is 100 - was bottoming out at the rear under the truck's weight
	Damper = 10, -- scaled up alongside Stiffness so it stays similarly damped, not bouncier
	Torque = 50, -- DEFAULTS is 10 - was accelerating far too slowly for the truck's weight
}

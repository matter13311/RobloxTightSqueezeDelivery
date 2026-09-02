-- Only values that differ from VehiclePhysics.Defaults need to be listed here.
-- LateralGripStrength values are friction coefficients now (like a real
-- tire), not a 0-1 "% of velocity cancelled" fraction - a much lower number
-- goes a lot further than it used to at holding SOME grip.
return {
	DriveWheels = "Rear", -- rear-wheel-drive: power goes to the back axle only
	FrontLateralGripStrength = 1.2, -- front stays fairly planted, so steering still bites
	RearLateralGripStrength = 0.35, -- rear breaks loose under enough speed/turning - this is what actually drifts
	WheelSpinBoost = 40, -- visual burnout/wheelspin on the rear wheels under throttle
	Torque = 110, -- more power to break traction and hold a slide
	BrakeStrength = 0.2, -- 0-1: softer braking, doesn't snap straight the instant you let off
	SteerAngle = 35,
	MaxSpeed = 100,
	Stiffness = 100, -- softer suspension, allows for more body roll and weight transfer
	Damper = 5, -- softer suspension, allows for more body roll and weight transfer
	SuspensionMaxLength = 2
}

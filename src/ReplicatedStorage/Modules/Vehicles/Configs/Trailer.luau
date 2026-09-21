-- Trailer: the long three-axle box trailer (Workspace.Trailers.Trailer).
--
-- Same idea as TestTrailer.luau on the articulated-trailer-hitch branch: a
-- trailer is a car with no engine, run through the ordinary VehiclePhysics.Step
-- with Torque = 0. Read that file's header for why the four ray points are a
-- rear bogie, and why Stiffness/Damper here are only a FALLBACK (TrailerHitch's
-- tuneSuspension derives them per instance from the measured mass).
--
-- WHEELS. The body has three axles, so six wheels, but Step only knows four:
--
--     axle     z (chassis space)   what it is
--     front    -2.19               REAL   WheelFL / WheelFR
--     middle   +1.76               COSMETIC  CosmeticWheelLeft1 / CosmeticWheelRight1
--     rear     +5.71              REAL   WheelRL / WheelRR
--
-- The two real axles are the OUTER two on purpose. The bogie's effective
-- position is the mean of the real ray points, which lands exactly on the
-- middle axle (+1.76) - the load centre of a real tri-axle group - and the wide
-- spacing between the real pairs keeps the trailer's pitch stiff. The middle
-- pair rides its own visual-only ray and applies no force (see
-- VehiclePhysics.GetWheelAttachments).
--
-- All six use one mesh, ReplicatedStorage.Wheels.TrailerWheel: a dual-tyre
-- wheel, authored as a LEFT wheel (outboard face toward -X). Raycast-style
-- setup flips it 180 degrees for attachments with X > 0.
--
-- Everything else is inherited from the TestTrailer numbers; see that file.

local config = {}

-- No engine, no driver, no steering.
config.Torque = 0
config.SteerAngle = 0
config.HighSpeedSteerAngle = 0
config.MaxSpeed = 200 -- never the limiting factor; the tractor's MaxSpeed governs the rig

-- FALLBACK ONLY - overwritten per instance by tuneSuspension unless the
-- Chassis has AutoTuneSuspension = false.
config.Stiffness = 222
config.Damper = 13.9
-- 2.1 (TestTrailer's) sat the bogie a touch high once coupled to
-- AmericanHitchTruck, so the trailer leaned nose-down. Ride height at rest is
-- attachment Y - (SuspensionMaxLength - sag), so 0.2 less here is 0.2 lower at
-- the bogie, which tips the nose up by about atan(0.2 / 22.7) = 0.5 degrees.
-- It costs 0.2 of bump travel; raise it back if the bogie ever bottoms.
config.SuspensionMaxLength = 1.9

config.WheelModelName = "TrailerWheel"
-- Half the tyre's Size.Y (4.3817588 / 2), read the same way StraightTruck does.
config.WheelRadius = 2.19088
config.CosmeticWheelModelName = "TrailerWheel"
config.CosmeticWheelRadius = 2.19088

config.BrakeStrength = 0.3
config.BrakeFriction = 0.3

-- Deliberately below the tractor's, so the trailer is what lets go first.
config.LateralGripStrength = 1.1

-- The trailer is its own cargo; CargoManager never touches it.
config.CargoCapacity = 0

return config

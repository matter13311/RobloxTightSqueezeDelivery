-- PROTOTYPE: the trailer half of the articulated-vehicle test rig.
--
-- A trailer is a car with no engine. That is not a figure of speech here - it
-- is the reason this feature needed almost no new physics: the trailer is
-- stepped through the ordinary VehiclePhysics.Step with Torque = 0 and no
-- steering input, and the suspension, lateral grip and low-speed brake
-- stabiliser all do exactly what they already did.
--
-- WHY FOUR WHEEL ATTACHMENTS ON A TWO-AXLE TRAILER:
--
-- Step iterates a fixed WHEEL_NAMES of FL/FR/RL/RR and asserts all four exist.
-- Rather than generalise it to N axles (a change that touches every existing
-- car's stability maths, and the wrong thing to risk while the hitch itself is
-- unproven), the trailer's four ray points are the two axles of a rear BOGIE:
-- FL/FR are the forward axle of that bogie and RL/RR the rear one, both near
-- the back of the trailer. The front of the trailer is carried by the kingpin,
-- which is exactly how a real semi-trailer works.
--
-- SUSPENSION IS AUTO-DERIVED AT RUNTIME. The Stiffness and Damper below are a
-- FALLBACK, not what the trailer actually runs.
--
-- tuneSuspension in TrailerHitch.server.luau measures the trailer's real mass
-- and the real positions of its kingpin and bogie at setup, and writes
-- Stiffness/Damper as Chassis attributes - which beat this file in GetConfig.
-- Set AutoTuneSuspension = false on the Chassis to hand-tune instead, and the
-- numbers below take over again.
--
-- WHY IT IS AUTOMATIC, when every other vehicle here is hand-derived: a
-- trailer stands on two supports, and only one of them is its own. The kingpin
-- is pinned to the truck at whatever height the truck's hitch is, so the bogie
-- alone decides the trailer's PITCH. A wrong spring rate does not make a
-- trailer sit low or high the way it would a car - it makes it TILT:
--
--     bogie too soft  -> rear sags       -> trailer noses UP
--     bogie too stiff -> rear rides high -> trailer noses DOWN
--
-- so every edit to the trailer's mass or axle positions silently becomes a
-- lean. Those are the first two things anyone changes when a trailer looks
-- wrong, which made hand-tuning a trap. Deriving it makes both self-correcting.
--
-- The lever rule it uses, for reference: with the centre of mass between the
-- two supports, the bogie carries
--     (com - kingpin) / ((com - kingpin) + (bogie - com))
-- of the trailer and the kingpin carries the rest - and the kingpin's share is
-- the download that lands on the tractor's rear axle.
--
-- HISTORICAL, and only valid for the ORIGINAL model (chassis 199.33 at z=0,
-- four StraightTruckRearWheels at z=9.5, total 241.45, CoM z=+1.66). It is
-- kept because it shows the arithmetic the runtime version now does:
--     bogie share = 14.66 / (14.66 + 7.84)  = 0.651  -> supported 157.3
--     Stiffness   = 0.8175 * 157.3 / 1.4    = 91.9   -> 92
--     Damper      = 92 * (7.5 / 120)        = 5.75
-- Do not "fix" these to match a newer model; change the model and let
-- tuneSuspension do it.

local config = {}

-- No engine, no driver, no steering. Torque = 0 is what makes this a trailer
-- rather than a second car that fights the one towing it.
config.Torque = 0
config.SteerAngle = 0
config.HighSpeedSteerAngle = 0
config.MaxSpeed = 200 -- never the limiting factor; the tractor's MaxSpeed governs the rig

-- FALLBACK ONLY - tuneSuspension overwrites these per instance at setup unless
-- AutoTuneSuspension is false on the Chassis. See the header.
config.Stiffness = 92
config.Damper = 5.75
-- NOT auto-derived, and the one to reach for if a trailer still will not sit
-- level: travel is what the auto-tuner has to spend. If it warns that it is
-- clamping Stiffness against the stability ceiling, the trailer is too heavy
-- for 2.1 studs of travel and this wants raising rather than the mass lowering.
config.SuspensionMaxLength = 2.1

-- Wheels. Reuses the StraightTruck's rear wheel on both bogie axles, which is
-- what a trailer would run anyway, and saves modelling a new one for a
-- prototype. Radius is half the tire's Size.Y, read the same way
-- StraightTruck.luau reads its own.
config.WheelModelName = "StraightTruckRearWheel"
config.WheelRadius = 2.21025

-- Braking. The trailer has no pedal of its own - Step is called with Brake = 0
-- - so what this actually governs is the low-speed stabiliser that keeps a
-- stopped body stopped. Left at the default; a real trailer brake that follows
-- the tractor's pedal is worth adding once the coupling itself is trusted, and
-- is the single biggest thing missing from the rig's stopping distance.
config.BrakeStrength = 0.3
config.BrakeFriction = 0.3

-- Grip, and the one number here chosen for FEEL rather than derived.
--
-- Deliberately below the tractor's 1.5. When the rig is pushed past the limit
-- something has to let go first, and it should be the trailer: a trailer that
-- scrubs sideways is a recoverable slide the driver can feel building, whereas
-- a trailer with more grip than the truck levers the cab around its own bogie
-- and the first the driver knows about it is facing backwards.
config.LateralGripStrength = 1.1

-- No cargo system on the trailer yet. The pre-loaded-trailer design (the
-- trailer model IS its cargo, with mass set per contract) means CargoCapacity
-- stays 0 and CargoManager never touches this vehicle - see the discussion in
-- the hitch design notes.
config.CargoCapacity = 0

-- Nothing here has an upgrade ladder: a trailer is not owned, bought or
-- upgraded by the player, it is depot furniture they borrow. Leaving Upgrades
-- unset is what keeps it out of the garage terminal.

return config

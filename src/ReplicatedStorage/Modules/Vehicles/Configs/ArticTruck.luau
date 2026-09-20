-- PROTOTYPE: the tractor half of the articulated-vehicle test rig.
--
-- A copy of the StraightTruck in every respect that matters - this exists so
-- the hitch can be prototyped without touching the working truck, its template
-- (ServerStorage.VehicleTemplates.StraightTruck) or its tuning. The model is
-- ServerStorage.VehicleTemplates.ArticTruck, which is that template duplicated
-- with one Attachment added to its Chassis: "Hitch", at the back of the frame.
-- That attachment is the entire opt-in - see TrailerHitch.CanTow.
--
-- SUSPENSION: partly re-tuned, and the coupled ride height is a KNOWN OPEN
-- PROBLEM. Read this before changing a number here - three plausible-sounding
-- explanations were tried and MEASURED FALSE, and re-running them is waste.
--
-- Strut travel remaining, out of SuspensionMaxLength 2.1:
--     Stiffness 200, solo        FL 0.75  FR 0.73  RL 0.74  RR 0.73
--     Stiffness 260, solo        FL 1.26  FR 1.25  RL 1.26  RR 1.25
--     Stiffness 260, coupled     FL 1.35  FR 1.30  RL 0.00  RR 0.00
--
-- Stiffness 260 is kept because it is a real, measured improvement to the SOLO
-- truck - 0.74 -> 1.26 studs of travel in reserve, for free. It does NOT fix
-- the coupled case: the rear still bottoms out, and at full trailer mass the
-- rear wheels end up 0.78 studs BELOW the ground surface (raw spring length
-- goes negative) with the chassis tail half a stud off the deck.
--
-- RULED OUT, so nobody burns an afternoon re-testing them:
--
--   "Make the trailer Massless so it stops pulling on the springs." Wrong
--   trade twice over. A weightless trailer cannot change how the truck
--   handles, which is the entire point of towing one; and Step sizes every
--   suspension and grip force off AssemblyMass, so a massless trailer also
--   loses its OWN suspension and skitters. The load is the feature.
--
--   "The pin is 8.44 studs behind the rear axle, so it is a lever." The lever
--   is real - the front struts visibly EXTEND under load, 1.26 -> 1.35, which
--   is the steering axle being unloaded - but it is not the cause. Moving the
--   pin to z = 9.56, directly over the drive axle, changed the bottomed rear
--   not at all (pitch +5.05 -> +5.14).
--
--   "The two suspensions are fighting through the rigid trailer beam."
--   Softening the trailer's bogie from Stiffness 92 to 45 to 25 levelled the
--   TRAILER nicely (-5.9 deg -> +1.1 deg) and moved the truck's bottomed rear
--   by nothing at all.
--
-- WHAT IS ACTUALLY KNOWN: trailer MASS is the variable that moves it. A
-- 56-mass trailer leaves the rear healthy at +0.48; the full 241 buries it at
-- -0.77. Beyond ~127 the numbers stop responding to mass or pin position,
-- which normally means something is bottoming against a hard floor rather than
-- against a spring.
--
-- WHAT IS NOT KNOWN, and the honest reason: the sweep that produced that
-- "saturation" was invalid. The rig was quietly SLIDING across the map between
-- samples (it ended up 20+ studs from where it started, with the trailer tail
-- resting on a traffic cone), so each row was measured on different ground.
-- The drift is probably just the truck coasting after a throttle test with no
-- brake applied, but that is unconfirmed and is itself worth checking first.
--
-- NEXT STEP is a controlled harness, not more tuning: pin the truck at a fixed
-- pose on known-flat ground, handbrake on, couple, and sample once after a
-- fixed settle. Only then sweep trailer mass. Until that exists, any number
-- tuned here is being fitted to noise.
--
-- Do NOT push Stiffness much past 260 to chase this. The stability sum
-- Stiffness + 120 * Damper must clear 30 * mass / 4 at the LIGHTER (solo)
-- state, where the budget is tightest: 260 + 120 * 16.25 = 2210 against
-- 30 * 358.5 / 4 = 2689, already 0.82 of the limit. At 300 it reaches 0.95,
-- which is where the integration gets fragile on a bad frame rate.

-- Still expected to want changing once the rig is driven in anger:
--
--   Torque     - a trailer roughly doubles the mass being accelerated and
--                Torque is a raw force that does not scale with mass (see
--                BoxTruck.luau). Measured: 10.2 studs in 6 seconds from rest.
--                Raise it once the handling is settled, not before, or it will
--                mask what the suspension is doing.
--   SteerAngle - a tractor is steered in tight yards mostly in reverse, and
--                more lock makes the trailer respond faster to a correction,
--                in both the helpful and the unrecoverable directions.
--
-- Tune those here rather than in StraightTruck.luau; the whole reason this
-- file exists is that the two trucks are allowed to diverge.

local base = require(script.Parent.StraightTruck)

local config = table.clone(base)

config.Stiffness = 260
config.Damper = 16.25

return config

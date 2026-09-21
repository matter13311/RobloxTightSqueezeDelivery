-- AmericanHitchTruck: a fifth-wheel tractor. It hauls a trailer, not crates, so
-- it has no cargo bed and a CargoCapacity of 0.
--
-- Starts as a copy of StraightTruck's tuning and overrides only what is specific
-- to this truck, the same arrangement ArticTruck uses on the articulated-trailer
-- branch. Anything not listed below is StraightTruck's number until it is
-- re-tuned here.
--
-- Why StraightTruck's suspension/torque numbers are valid as they stand: they
-- are derived from an empty AssemblyMass of ~358.5 (see the block at the top of
-- StraightTruck.luau), and this truck lands on that same mass:
--     Chassis 284.47 + Engine 21.53 + wheels 52.50 (2 x 8.19 front,
--     2 x 18.06 rear) = 358.50
-- If the chassis, Engine or wheel models change, re-read the real number from
-- CargoLoad.Attributes.EmptyMass (or Chassis.AssemblyMass in Studio) and redo
-- Stiffness / Damper / Torque with StraightTruck's formulas.
--
-- WHEELS: the model has a rear tandem (two axles, 5 studs apart), but the
-- suspension only supports four wheels, so WheelRL/WheelRR sit on the tandem's
-- rear axle (z = +14.6 from the chassis centre) and carry the wide rear tire.
-- The front pair is at z = -10.6, in the arch. Both are where the model draws
-- the wheels - do not move them to fix handling; move MASS instead (below).
--
-- BALANCE. VehiclePhysics.Step supports every strut with cornerMass =
-- AssemblyMass / 4, i.e. it assumes the centre of mass sits at the CENTROID
-- of the four Wheel attachments (here z = +2.0). When it doesn't, the loaded
-- axle takes the difference out of its own bump travel. With the Engine part
-- carrying the counterweight at z = -11 the COM was at +0.33, the front axle
-- carried 56.6%, and the front struts bottomed out in ordinary turns - the
-- self-destructing jitter. So the mass was moved, not the wheels:
--     Engine.Engine          Massless (stays put, so its sounds do too)
--     Engine.Ballast         30.28 at z = +12, invisible, non-colliding,
--                            inside the chassis under the fifth wheel
--     Chassis                275.72 (density 0.9776, down from 284.47)
-- Total is still 358.50 and the COM lands exactly on +2.0. If the chassis,
-- wheel models or attachment Z change, re-solve the Ballast mass:
--     B = (M * centroidZ - sum(wheelMass * wheelZ)) / ballastZ
-- and take B back off the Chassis so the total stays put. Model edits go on
-- ServerStorage.VehicleTemplates.AmericanHitchTruck - that is what plots spawn.
--
-- ATTACHMENT HEIGHT. The Wheel attachments are at Y -0.5, INSIDE the chassis
-- (-0.565..+0.565), per BoxTruck.luau's rule 5. At the model's original -1.48
-- they hung below the front collision hull (bottom at -1.08), so a bottomed
-- corner sank until the ray origin was inside the road, the ray missed, the
-- strut dropped to zero force and the truck bounced itself apart. Ride height
-- is set by SuspensionMaxLength instead - see below.

local base = require(script.Parent.StraightTruck)

local config = table.clone(base)

-- Wheel models under ReplicatedStorage.Wheels, one per axle.
config.FrontWheelModelName = "AmericanHitchTruckFrontWheel"
config.RearWheelModelName = "AmericanHitchTruckRearWheel"

-- Half of each wheel model's tire Size.Y (== Size.Z). Front tire is 1.12 x 4.02 x
-- 4.02 and rear is 2.51 x 4.02 x 4.02: the same diameter on both axles, the rear
-- just being a wider tire on X, which doesn't affect radius.
config.FrontWheelRadius = 2.01
config.RearWheelRadius = 2.01

-- Horn, played from under the hood. The chassis is centred on the axle midpoint
-- (z = 177) and the hood is at about z = 165, hence -12.
config.HonkSoundOffsetZ = -12

-- No bed, no crates. CargoLoad.Capacity reads 0, so the truck is treated as
-- carrying nothing, and the ladder is dropped so the garage does not offer to
-- sell "Cargo Space" for a truck that has nowhere to put it. Upgrades is cloned
-- first because table.clone(base) is shallow and would otherwise edit
-- StraightTruck's ladder.
config.CargoCapacity = 0
config.Upgrades = table.clone(base.Upgrades)
config.Upgrades.CargoCapacity = nil
config.Torque = 25

-- SUSPENSION. Stiffness 200 -> 260 (Damper 12.5 -> 14, scaled by sqrt(1.3)
-- to hold the damping ratio) for less roll: sag 1.465 -> 1.13, about 4 deg
-- of lean per 0.5g of cornering.
--
-- SuspensionMaxLength puts the wheels back on the model's hubs:
--     wheel centre at rest = attachment Y - (SuspensionMaxLength - sag)
--     -0.5 - (2.1 - 1.127) = -1.47, the model's own hub height (-1.48)
-- so there is no gap between tire and body. That leaves 0.97 studs of bump
-- travel, and each strut can push 1.86x its resting load before bottoming
-- (outside struts would bottom at ~1.8g of cornering). Raise it for a taller
-- truck with more travel; lower it and the wheels tuck up into the body.
--
-- Stability sum Stiffness + 120 * Damper = 260 + 1680 = 1940 of the 2689
-- limit (30 * 358.5 / 4). If it still rocks in turns, lower BodyLean toward
-- 0.3 before touching Damper - see BoxTruck.luau's BodyLean note.
config.Stiffness = 260
config.Damper = 14
config.SuspensionMaxLength = 2.1

-- Ladders re-stated a whole number of Steps above the new Mins (StraightTruck's
-- Steps and level counts kept). Top of both suspension ladders:
-- 350 + 120 * 17 = 2390, 0.89 of the 2689 limit.
config.Upgrades.Stiffness = table.clone(base.Upgrades.Stiffness)
config.Upgrades.Stiffness.Max = 350 -- 260 + 15 * 6 levels
config.Upgrades.Damper = table.clone(base.Upgrades.Damper)
config.Upgrades.Damper.Max = 17 -- 14 + 0.75 * 4 levels
config.Upgrades.SuspensionMaxLength = table.clone(base.Upgrades.SuspensionMaxLength)
config.Upgrades.SuspensionMaxLength.Max = 2.9 -- 2.1 + 0.2 * 4 levels
return config

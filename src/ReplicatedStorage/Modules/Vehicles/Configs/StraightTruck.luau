-- StraightTruck: a longer, heavier box truck than the BoxTruck.
--
-- Starts as a copy of BoxTruck's tuning and overrides only what is specific to
-- this truck, so anything not listed below (upgrade ladder, cargo, gearbox,
-- mirrors, lights, sounds) is BoxTruck's number until it is re-tuned here.
-- To re-tune a key, add it to the overrides below rather than editing
-- BoxTruck.luau. Once most of the file has been overridden, it is worth
-- flattening this into a standalone table like the other configs.
--
-- BoxTruck's suspension numbers are derived from its own chassis mass (see the
-- block at the top of BoxTruck.luau). This truck's Stiffness, Damper and Torque
-- are re-scaled below from a computed empty mass of ~358.5, and should be
-- checked against the real AssemblyMass in-game (CargoLoad.Attributes.EmptyMass):
--     Stiffness = 120 * M / 216
--     Damper    = 7.5 * M / 216
--     Torque    = 10 * M / 216
-- The Engine counterweight's density needs recomputing if the wheel
-- attachments move along Z.

local base = require(script.Parent.BoxTruck)

local config = table.clone(base)

-- Wheel models under ReplicatedStorage.Wheels (one per axle, like BoxTruck).
config.FrontWheelModelName = "StraightTruckFrontWheel"
config.RearWheelModelName = "StraightTruckRearWheel"

-- Half of each wheel model's tire Size.Y (== Size.Z), the way BoxTruck.luau
-- reads them: StraightTruckFrontWheel's Tire is 1.261, 4.4205, 4.4205 and
-- StraightTruckRearWheel's is 2.480, 4.4205, 4.4205 - the same 4.4205 diameter
-- on both axles, the rear just being a wider tire on X, which doesn't affect
-- radius. A wrong radius puts the wheels visibly too high/low against the
-- arches.
config.FrontWheelRadius = 2.21025
config.RearWheelRadius = 2.21025

-- Horn. Its own sound, played from the front of the truck: the chassis is 37.5
-- studs long and the horn would otherwise sound from its centre, ~9 studs
-- behind the driver's seat (DriverSeat is at z = -9.25 in chassis space).
-- -14 puts it under the hood, just ahead of the cab.
config.HonkSoundId = "rbxassetid://86051083118541"
config.HonkSoundOffsetZ = -14

-- Steering. More lock than BoxTruck's 40 at a standstill, and a little more
-- at speed (BoxTruck: 12) so the extra angle is felt while driving and not
-- only when parking.
config.SteerAngle = 50
config.HighSpeedSteerAngle = 15

-- Body strength. BoxTruck's is 1 (see its Upgrades entry for what it does -
-- cosmetic panel durability only). Starting at 3 makes this truck shrug off
-- three times the punishment before panels come off.
config.BodyStrength = 3

-- An upgrade ladder's Min is the plain field above, and its Max has to sit a
-- whole number of Steps above that - so raising the base values means
-- re-stating the Max for these two, or the ladder would top out below (or
-- barely above) the truck's free level. Upgrades is cloned first because
-- table.clone(base) above is shallow and would otherwise edit BoxTruck's.
config.Upgrades = table.clone(base.Upgrades)
config.Upgrades.SteerAngle = table.clone(base.Upgrades.SteerAngle)
config.Upgrades.SteerAngle.Max = 62 -- 50 + 4 * 3 levels
config.Upgrades.BodyStrength = table.clone(base.Upgrades.BodyStrength)
config.Upgrades.BodyStrength.Max = 4.5 -- 3 + 0.25 * 6 levels

-- SUSPENSION and TORQUE, re-scaled from BoxTruck's mass of 216 to this truck's.
--
-- Empty AssemblyMass is ~358.5: Chassis 266.96, Engine 49.6 (weighted so the
-- centre of mass sits over the axle midpoint), and the four wheel models
-- (2 x 10.46 front, 2 x 10.53 rear). Every body panel is Massless. Re-read the
-- real number from CargoLoad.Attributes.EmptyMass if the chassis or engine
-- changes and redo the three lines below with it.
--
-- Neither the spring nor the drive force scales with mass (see BoxTruck.luau),
-- so left at BoxTruck's values this truck was both under-sprung and underpowered:
--   sag = 0.8175 * mass / Stiffness = 0.8175 * 358.5 / 120 = 2.44 studs,
--   against 2.45 of travel - the struts were fully bottomed out before the
--   truck even moved, so any steering input rolled it straight onto the bump
--   stops and it wobbled. Stiffness and Damper scale by mass / 216 (= 1.66) so
--   sag stays at BoxTruck's 1.47 (0.32 studs of droop is used by a full load;
--   see SuspensionMaxLength below for how much is left) and the damping ratio and the stability sum
--   Stiffness + 120 * Damper <= 30 * mass / 4 keep BoxTruck's 0.63 of the
--   limit: 200 + 120 * 12.5 = 1700 against 2689.
config.Stiffness = 200
config.Damper = 12.5
-- Ride height. With sag held at 1.47, BoxTruck's 2.45 of travel left 0.98
-- studs of droop, which rode this truck higher than wanted (the chassis floats
-- exactly as far above its modelled pose as there is droop). 2.1 leaves 0.63:
-- ~0.35 studs lower, still 0.31 more than a full load sags by. Raise it toward
-- 2.45 for a taller truck; below ~1.9 a loaded truck starts bottoming out
-- again, which is the wobble this was re-tuned to remove.
config.SuspensionMaxLength = 2.1
-- Torque is a raw drive force, so acceleration falls as mass rises. Scaling it
-- by the same 1.66 (10 -> 16.5) gives the BoxTruck's power-to-weight, i.e. the
-- same pull-away and hill-climb feel despite the extra weight. Drop it toward
-- 14 for a truck that feels heavier than the BoxTruck.
config.Torque = 16.5

-- Ladder Mins follow the plain fields above; Maxes are re-stated a whole
-- number of Steps above them, scaled by the same 1.66 so each ladder buys the
-- same proportion it does on BoxTruck (Springs 120 -> 180 becomes 200 -> 290,
-- Smooth Ride 7.5 -> 9.5 becomes 12.5 -> 15.5, Power 10 -> 25 becomes 16.5 ->
-- 34.5). The top of both suspension ladders is 290 + 120 * 15.5 = 2150, or 0.80
-- of the 2689 stability limit against BoxTruck's 0.81.
config.Upgrades.Stiffness = table.clone(base.Upgrades.Stiffness)
config.Upgrades.Stiffness.Step = 15
config.Upgrades.Stiffness.Max = 290 -- 200 + 15 * 6 levels
config.Upgrades.Damper = table.clone(base.Upgrades.Damper)
config.Upgrades.Damper.Step = 0.75
config.Upgrades.Damper.Max = 15.5 -- 12.5 + 0.75 * 4 levels
config.Upgrades.Torque = table.clone(base.Upgrades.Torque)
config.Upgrades.Torque.Step = 3
config.Upgrades.Torque.Max = 34.5 -- 16.5 + 3 * 6 levels
config.Upgrades.SuspensionMaxLength = table.clone(base.Upgrades.SuspensionMaxLength)
config.Upgrades.SuspensionMaxLength.Max = 2.9 -- 2.1 + 0.2 * 4 levels (BoxTruck: 2.45 -> 3.25)

-- Steering feel. BoxTruck's 2.2 / 3.2 (full lock in 0.45s) felt too snappy on
-- this truck, made worse by its bigger SteerAngle. Lower = slower, heavier
-- turn-in; 1.5 takes 0.67s to reach full lock and 2.4 re-centres in 0.42s.
config.SteerSpeed = 1.5
config.SteerReturnSpeed = 2.4

return config

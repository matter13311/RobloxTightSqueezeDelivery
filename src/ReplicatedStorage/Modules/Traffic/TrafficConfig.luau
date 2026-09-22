-- Moving NPC traffic (see TrafficController.client.luau). Everything here is
-- data: tuning numbers and the routes cars drive.
--
-- Traffic runs on closed circuits, so it flows: a player held up by NPC cars
-- is held up by cars that will move, never by a permanent wall.
--
-- Right-hand traffic on the three-zone city built by tools/mapgen. Each zone
-- has its own circuits; none crosses a permit gate. In a zone's local frame:
--
--   Market Ave   x -32 / -20 southbound, 20 / 32 northbound (a 28-wide centre
--                strip carries the elevated express deck and its ramps)
--   West St      x -294 southbound, -284 northbound, parked cars at -303
--   East St      x 284 southbound, 294 northbound, parked cars at 303
--   Cross roads  centre -/+ 6: westbound on the north half, eastbound south
--
-- Old Town's busiest stretch is the MIDDLE of Market Ave (Brick St to the
-- canal); the stretch by the Terminal gate is kept light so players can get
-- out of the yard.

-- A route is a list of {x, z} points. Corners are rounded automatically
-- (TrafficPath.Build): a right turn gets RightTurnRadius, a left turn
-- LeftTurnRadius, anything gentler GentleTurnRadius - each capped at what
-- the neighbouring straights allow. The LAST point is where the front car of
-- the queue stops, measured car centre, ~1.5 studs short of the jam - unless
-- that is inside a KeepClear box, in which case the queue stops short of the
-- box instead.

local TrafficConfig = {}

TrafficConfig.MaxCars = 140

-- Studs per second. Player cars top out around 50.
TrafficConfig.CruiseSpeed = 30
TrafficConfig.TurnSpeed = 11
TrafficConfig.Acceleration = 12
TrafficConfig.Braking = 28

-- Bumper-to-bumper gap a car stops at behind whatever is in front of it.
TrafficConfig.StopGap = 4
-- How far ahead a car looks for traffic, players and pedestrians.
TrafficConfig.LookAhead = 45
-- Lateral slack added to the two half-widths when deciding whether something
-- is in a car's path. Adjacent lanes are 11-12 studs apart centre to centre.
TrafficConfig.LateralSlack = 0.6

-- How long a car waits for a gap in crossing traffic before it pushes in
-- anyway (the through traffic then brakes for it). Without this, a car turning
-- out of a side street can sit at a busy junction indefinitely, which reads as
-- a broken-down car rather than traffic.
TrafficConfig.MergePatience = 8

TrafficConfig.RightTurnRadius = 8
TrafficConfig.LeftTurnRadius = 14
-- Bends between 30 and 60 degrees - the loop's diagonal corners - get this
-- radius and speed. Shallower bends (lane changes) keep cruising.
TrafficConfig.GentleTurnRadius = 40
TrafficConfig.GentleTurnSpeed = 20

-- Recycling. A car is only ever created or removed where the local camera
-- cannot see it: off screen, or further than this.
TrafficConfig.HiddenDistance = 260
-- How long a car sits in a queue (at the end of its route, or stopped behind
-- another traffic car) before it may be recycled - random in this range, and
-- only once hidden.
TrafficConfig.QueueWaitMin = 6
TrafficConfig.QueueWaitMax = 20
-- A car stuck anywhere for this long is recycled once hidden - the safety net
-- for a player parked across a lane, or a gridlocked junction.
TrafficConfig.StuckRecycleSeconds = 60
TrafficConfig.SpawnInterval = 0.4
-- A route start must be at least this clear before a car appears there.
TrafficConfig.SpawnClearance = 30

-- Mesh centre height above the road (mesh Size.Y / 2 puts the tyres on Y = 0).
TrafficConfig.RoadY = 0

-- Brake lights.
TrafficConfig.BrakeLightOnColor = Color3.fromRGB(255, 40, 30)
TrafficConfig.BrakeLightOffColor = Color3.fromRGB(90, 12, 12)

-- Horn. Reuses the player horn recording (VehiclePhysics.Defaults.HonkSoundId),
-- tapped rather than held. Each car gets its own pitch so a street full of
-- them doesn't sound like one horn.
TrafficConfig.HornSoundId = "rbxassetid://127513531122725"
TrafficConfig.HornVolume = 0.7
TrafficConfig.HornRollOffMaxDistance = 220
TrafficConfig.HornPitchMin = 0.85
TrafficConfig.HornPitchMax = 1.15
-- Only cars this close to the camera ever honk, at most this many at once,
-- and never two honks closer together than HornGlobalGap.
TrafficConfig.HornAudibleDistance = 200
TrafficConfig.HornGlobalGap = 1.3
-- Blocked by a player: honk after this many seconds (random in range)...
TrafficConfig.HonkAtPlayerDelayMin = 1.5
TrafficConfig.HonkAtPlayerDelayMax = 4
-- ...stuck in a queue: much more patient, and only sometimes.
TrafficConfig.HonkInQueueDelayMin = 8
TrafficConfig.HonkInQueueDelayMax = 25
TrafficConfig.HonkInQueueChance = 0.35
-- Per-car cooldown after any honk.
TrafficConfig.HonkCooldownMin = 7
TrafficConfig.HonkCooldownMax = 18

-- Bump reaction (a player's vehicle hitting a traffic car). The car is
-- anchored and never really moves; it rocks away from the hit and settles.
TrafficConfig.BumpMinSpeed = 5 -- relative studs/s below which a touch is ignored
TrafficConfig.BumpMaxShove = 1.4 -- studs, at full strength
TrafficConfig.BumpMaxYaw = 6 -- degrees of wobble, at full strength
TrafficConfig.BumpSettleSeconds = 0.9
TrafficConfig.BumpHoldMin = 1.5 -- seconds the car stays stopped afterwards
TrafficConfig.BumpHoldMax = 3

-- The routes themselves (closed circuits per zone, lane-change boxes, keep-
-- clear boxes at junctions / alley mouths / driveways, and permanent obstacles
-- like roadworks) are GENERATED from the map layout, so they always match the
-- roads: see TrafficRoutes.luau and tools/mapgen/Traffic.luau.
local TrafficRoutes = require(script.Parent.TrafficRoutes)

-- {x1, z1, x2, z2, name}: a traffic car never comes to rest inside one of
-- these - it stops short instead - so a queue never walls off an alley exit,
-- a driveway or a junction ("don't block the box").
TrafficConfig.KeepClear = TrafficRoutes.KeepClear

-- Closed circuits (the last point repeats the first, mid-straight). Cap is how
-- many cars a circuit holds. `Lanes` = { Offset, Boxes }: inside Boxes a car
-- may move Offset studs sideways (+ = to its left) into the neighbouring lane
-- when it is held up - see TrafficSim's lane logic.
TrafficConfig.Routes = TrafficRoutes.Routes

-- {x1, z1, x2, z2}: permanent obstacles in a lane (roadworks).
TrafficConfig.Static = TrafficRoutes.Static

return TrafficConfig

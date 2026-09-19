-- Moving NPC traffic (see TrafficController.client.luau). Everything here is
-- data: tuning numbers and the routes cars drive.
--
-- Traffic runs on closed circuits, so it flows: a player held up by NPC cars
-- is held up by cars that will move, never by a permanent wall. The static
-- obstacles that do block a lane are rare, deliberate, and always passable
-- (see below).
--
-- Right-hand traffic. Lane centres were measured off the stalled cars (a car
-- mesh is 8.4 wide x ~19 long, front = -Z), so a route that follows them
-- clears the jams by construction. Coordinates are world X/Z; the ground top
-- is Y = 0 on every road.
--
--   Loop West   X -463.5 southbound, -451.5 northbound
--   Loop East   X  451.5 southbound,  463.5 northbound
--   Depot Rd    Z    3.5 eastbound,    -8.5 westbound
--   Market Ave  X  -25.5 / -15.5 southbound, 14.5 / 24.5 northbound (circuits
--               use the outer -25.5: the inner one passes close to the toll
--               barrier and the north ramp wall)
--   Canal St    Z -299.5 eastbound, -331.5 westbound (-288.5 / -341.5 kerbs)
--   Foundry St  Z -629.5 eastbound, -660.5 westbound (-617.5 / -672.5 kerbs)
--
-- Kerb lanes (Loop West -472.5, Loop East 472.5, Depot Rd 12.5, Northside
-- -962.5, and the Canal/Foundry kerbs above) are for PARKED cars only. Driving
-- lanes stay empty apart from a handful of stalled cars (Map.Traffic.Stalled,
-- all with flashing hazards), the Canal St crash scene and the Foundry St
-- roadworks - and each of those leaves a lane or the kerb open to squeeze past.
--
-- The four corners of the outer loop are NOT square: the corner buildings cut
-- them into 45-degree diagonals about 34 studs wide, so routes take two
-- 45-degree bends there. Outer (building-side) diagonal lane: x - z = -404.2
-- in the west, x + z = 404.2 in the east; inner lane: x - z = -388 (the inner
-- corner building bulges further out on this side) and x + z = 377.4.
--
-- A route is a list of {x, z} points. Corners are rounded automatically
-- (TrafficPath.Build): a right turn gets RightTurnRadius, a left turn
-- LeftTurnRadius, anything gentler GentleTurnRadius - each capped at what
-- the neighbouring straights allow. The LAST point is where the front car of
-- the queue stops, measured car centre, ~1.5 studs short of the jam - unless
-- that is inside a KeepClear box, in which case the queue stops short of the
-- box instead.
--
-- No jam may sit within ~110 studs of an alley exit (either direction), so an
-- alley shortcut never ends in a wall of cars. Stalled cars removed for that
-- are kept in ServerStorage.RemovedStalledCars.

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

-- Alley exits and busy junctions. A traffic car never stops anywhere inside
-- one of these boxes:
-- if the space it would stop in overlaps an exit, it stops short of the exit
-- instead, so a queue can never wall off an alley shortcut. Each box spans the
-- full width of the road across the alley mouth, plus 3 studs either side.
-- {x1, z1, x2, z2, name}. Generated from MapKit's LayoutJSON corridors.
TrafficConfig.KeepClear = {
	-- The Market Ave junctions. Market is the busiest road and the shuttle
	-- circuits turn round at its ends, so without "don't block the box" a car
	-- stopping mid-junction deadlocks the crossing stream.
	{ -30, -17, 30, 17, "Market x Depot Rd" },
	{ -30, -347, 30, -283, "Market x Canal St" },
	{ -30, -677, 30, -613, "Market x Foundry St" },
	{ -30, -967, 30, -933, "Market x Northside Rd" },
	{ -75, -17, -45, 17, "Rat Run (Depot Rd)" },
	{ -345, -347, -315, -283, "Rat Run (Canal St)" },
	{ -314, -17, -286, 17, "Bin Juice Row" },
	{ -30, -135, 30, -105, "Pigeon Pass" },
	{ -30, -185, 30, -155, "Laundry Row (Market Ave)" },
	{ 443, -215, 477, -185, "Laundry Row (Loop East)" },
	{ 305, -17, 335, 17, "The Wiggle (Depot Rd)" },
	{ 265, -347, 295, -283, "The Wiggle (Canal St)" },
	{ -30, -535, 30, -505, "Noodle Row (Market Ave)" },
	{ -477, -490, -443, -460, "Noodle Row (Loop West)" },
	{ -59, -347, -31, -283, "Mirror Snapper" },
	{ 35, -347, 65, -283, "Scrape Street (Canal St)" },
	{ 345, -677, 375, -613, "Scrape Street (Foundry St)" },
	{ -30, -415, 30, -385, "Tin Can Alley (Market Ave)" },
	{ 443, -440, 477, -410, "Tin Can Alley (Loop East)" },
	{ -30, -846, 30, -814, "Rattle Row (Market Ave)" },
	{ -477, -846, -443, -814, "Rattle Row (Loop West)" },
	{ -60, -677, -30, -613, "Close Shave" },
	{ -477, -889, -443, -861, "Paper Cut" },
	{ -30, -810, 30, -780, "Knuckle Lane" },
	{ 210, -677, 240, -613, "Stinky Pete's (Foundry St)" },
	{ 270, -967, 300, -933, "Stinky Pete's (Northside Rd)" },
	{ 443, -854, 477, -826, "Dock Hop" },
}

-- Circuits. Every route is a closed loop (the last point repeats the first,
-- placed mid-straight so the wrap is invisible), so traffic circulates instead
-- of queuing at a dead end - the jams a player meets are other moving cars,
-- which clear, rather than a permanent wall.
--
-- Cap is how many cars this circuit holds, and that is where the traffic goes.
-- Market Ave is the city's spine, running beside the express deck, so it gets
-- the lion's share: three "shuttle" circuits run up one side of it and back
-- down the other, crossing over on Depot Rd, Canal St, Foundry St or Northside
-- Rd. They are short and densely capped, which keeps Market busy end to end -
-- the traffic a player is paying the express toll to skip, and the reason to
-- duck into an alley. The ring and block circuits keep the rest of the city
-- alive at a lighter density.
--
-- Where a circuit passes one of the stalled cars in Map.Traffic.Stalled, or one
-- of the Market Ave lane closures (Map.Traffic.RoadWorks_Market_*), the points
-- step into the neighbouring lane and back - the same squeeze a player
-- makes. The kerb parking is cleared either side of each stalled car so the
-- detour fits; keep it that way if you move one.
TrafficConfig.Routes = {
	{
		-- Market Ave end to end: up the outer northbound lane, across on
		-- Northside Rd, back down the outer southbound lane, across on Depot Rd.
		Name = "MarketShuttleFull",
		Cap = 34,
		Closed = true,
		Points = {
			{ 24.5, -200 },
			{ 24.5, -415 },
			{ 14.5, -440 }, -- round the Market_460 lane closure
			{ 14.5, -510 },
			{ 24.5, -535 },
			{ 24.5, -953.5 },
			{ -25.5, -953.5 },
			{ -25.5, -625 },
			{ -15.5, -600 }, -- round the Market_575 lane closure
			{ -15.5, -530 },
			{ -25.5, -505 },
			{ -25.5, 3.5 },
			{ 24.5, 3.5 },
			{ 24.5, -200 },
		},
	},
	{
		-- The depot end of Market Ave, turning back at Canal St: the stretch a
		-- player sees first, and the one the express deck runs straight over.
		Name = "MarketShuttleSouth",
		Cap = 22,
		Closed = true,
		Points = {
			{ 14.5, -150 },
			{ 14.5, -331.5 },
			{ -25.5, -331.5 },
			{ -25.5, 3.5 },
			{ 14.5, 3.5 },
			{ 14.5, -150 },
		},
	},
	{
		-- The far end of Market Ave, turning back at Foundry St and Northside Rd.
		Name = "MarketShuttleNorth",
		Cap = 16,
		Closed = true,
		Points = {
			{ 14.5, -800 },
			{ 14.5, -845 },
			{ 24.5, -870 }, -- round the Market_890 lane closure
			{ 24.5, -953.5 },
			{ -25.5, -953.5 },
			{ -25.5, -629.5 },
			{ 14.5, -629.5 },
			{ 14.5, -800 },
		},
	},
	{
		-- Inner ring, clockwise: Loop West up, Northside across, Loop East
		-- down, Depot Rd back.
		Name = "InnerRing",
		Cap = 12,
		Closed = true,
		Points = {
			{ -451.5, -500 },
			{ -451.5, -882.5 },
			{ -392.5, -941.5 },
			{ 398.5, -941.5 },
			{ 451.5, -888.5 },
			{ 451.5, -74.1 },
			{ 385.9, -8.5 },
			{ -396.5, -8.5 },
			{ -451.5, -63.5 },
			{ -451.5, -500 },
		},
	},
	{
		-- Outer ring, the other way round, with kerb detours past the stalled
		-- cars on Loop East, Northside and Loop West.
		Name = "OuterRing",
		Cap = 12,
		Closed = true,
		Points = {
			{ -463.5, -300 },
			{ -463.5, -59.3 },
			{ -400.7, 3.5 },
			{ 400.7, 3.5 },
			{ 463.5, -59.3 },
			{ 463.5, -505 },
			{ 472.5, -520 },
			{ 472.5, -570 },
			{ 463.5, -585 },
			{ 463.5, -890.5 },
			{ 400.5, -953.5 },
			{ -60, -953.5 },
			{ -85, -962.5 },
			{ -155, -962.5 },
			{ -180, -953.5 },
			{ -398.5, -953.5 },
			{ -463.5, -888.5 },
			{ -463.5, -610 },
			{ -472.5, -595 },
			{ -472.5, -545 },
			{ -463.5, -530 },
			{ -463.5, -300 },
		},
	},
	{
		-- Canal St block: up Loop West, east along Canal (kerb detour past the
		-- stalled car), down Loop East, back along Depot Rd.
		Name = "CanalBlock",
		Cap = 10,
		Closed = true,
		Points = {
			{ -451.5, -200 },
			{ -451.5, -299.5 },
			{ 140, -299.5 },
			{ 160, -288.5 },
			{ 195, -288.5 },
			{ 215, -299.5 },
			{ 451.5, -299.5 },
			{ 451.5, -74.1 },
			{ 385.9, -8.5 },
			{ -396.5, -8.5 },
			{ -451.5, -63.5 },
			{ -451.5, -200 },
		},
	},
	{
		-- Foundry/Canal block: past the roadworks, then the squeeze past the
		-- crash scene on Canal St.
		Name = "FoundryCanalBlock",
		Cap = 12,
		Closed = true,
		Points = {
			{ -451.5, -450 },
			{ -451.5, -629.5 },
			{ 451.5, -629.5 },
			{ 451.5, -331.5 },
			{ -160, -331.5 },
			{ -180, -341.5 },
			{ -275, -341.5 },
			{ -295, -331.5 },
			{ -451.5, -331.5 },
			{ -451.5, -450 },
		},
	},
	{
		-- The north end: Market Ave to Northside Rd, down Loop East, back along
		-- Foundry St.
		Name = "NorthDeep",
		Cap = 12,
		Closed = true,
		Points = {
			{ 24.5, -800 },
			{ 24.5, -941.5 },
			{ 398.5, -941.5 },
			{ 451.5, -888.5 },
			{ 451.5, -660.5 },
			{ 24.5, -660.5 },
			{ 24.5, -800 },
		},
	},
	{
		-- North-west: up Loop West, east along Northside, down Market Ave, west
		-- along Canal past the crash scene.
		Name = "NorthWestDeep",
		Cap = 10,
		Closed = true,
		Points = {
			{ -451.5, -700 },
			{ -451.5, -882.5 },
			{ -392.5, -941.5 },
			{ -25.5, -941.5 },
			{ -25.5, -625 },
			{ -15.5, -600 }, -- round the Market_575 lane closure
			{ -15.5, -530 },
			{ -25.5, -505 },
			{ -25.5, -331.5 },
			{ -160, -331.5 },
			{ -180, -341.5 },
			{ -275, -341.5 },
			{ -295, -331.5 },
			{ -451.5, -331.5 },
			{ -451.5, -700 },
		},
	},
}

return TrafficConfig

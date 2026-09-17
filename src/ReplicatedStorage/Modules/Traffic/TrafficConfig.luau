-- Moving NPC traffic (see TrafficController.client.luau). Everything here is
-- data: tuning numbers and the routes cars drive.
--
-- The city's streets are deliberately jammed - the stalled cars in
-- workspace.Map.Traffic ARE the squeeze sections - so almost no road is clear
-- end to end in either direction. Traffic therefore does not loop. Each route
-- starts just past the front of one jam (a car "getting out" of it) and ends
-- at the tail of another, where cars queue with their brake lights on until
-- the controller quietly recycles the front car while nobody is looking.
--
-- Right-hand traffic. Lane centres were measured off the stalled cars (a car
-- mesh is 8.4 wide x ~19 long, front = -Z), so a route that follows them
-- clears the jams by construction. Coordinates are world X/Z; the ground top
-- is Y = 0 on every road.
--
--   Loop West   X -463.5 southbound, -451.5 northbound
--   Loop East   X  451.5 southbound,  463.5 northbound
--   Depot Rd    Z    3.5 eastbound,    -8.5 westbound
--   Market Ave  X  -25.5 / -13.5 southbound, 14.5 / 24.5 northbound
--   Canal St    Z -299.5 / -288.5 eastbound, -341.5 westbound
--   Foundry St  Z -629.5 eastbound, -660.5 westbound
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
-- the queue stops, measured car centre, ~1.5 studs short of the jam.

local TrafficConfig = {}

TrafficConfig.MaxCars = 42

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

-- Weight = relative chance a new car picks this route (roughly its length).
TrafficConfig.Routes = {
	{
		-- Out of the Loop West jam, down to Depot Rd, across town, up Loop
		-- East into the jam there.
		Name = "LoopWest_Depot_LoopEast",
		Weight = 3,
		Points = {
			{ -463.5, -490 },
			{ -463.5, -59.3 },
			{ -400.7, 3.5 },
			{ 400.7, 3.5 },
			{ 463.5, -59.3 },
			{ 463.5, -120 },
		},
	},
	{
		-- Same start, but turns up Market Ave into the jam past the toll plaza.
		Name = "LoopWest_Depot_Market",
		Weight = 2,
		Points = {
			{ -463.5, -490 },
			{ -463.5, -59.3 },
			{ -400.7, 3.5 },
			{ 14.5, 3.5 },
			{ 14.5, -178 },
		},
	},
	{
		-- Out of the Loop East jam, along Depot Rd westbound, up Loop West.
		Name = "LoopEast_Depot_LoopWest",
		Weight = 3,
		Points = {
			{ 451.5, -131 },
			{ 451.5, -74.1 },
			{ 385.9, -8.5 },
			{ -396.5, -8.5 },
			{ -451.5, -63.5 },
			{ -451.5, -493 },
		},
	},
	{
		-- Same start, but turns onto Canal St and queues behind the crash scene.
		Name = "LoopEast_Depot_Canal",
		Weight = 3,
		Points = {
			{ 451.5, -131 },
			{ 451.5, -74.1 },
			{ 385.9, -8.5 },
			{ -396.5, -8.5 },
			{ -451.5, -63.5 },
			{ -451.5, -288.5 },
			{ -269.5, -288.5 },
		},
	},
	{
		-- Down Loop East, right onto Canal St westbound, rubbernecking queue
		-- behind the crash scene's police car.
		Name = "LoopEast_Canal_Crash",
		Weight = 2,
		Points = {
			{ 451.5, -498 },
			{ 451.5, -341.5 },
			{ -175, -341.5 },
		},
	},
	{
		Name = "LoopEast_South",
		Weight = 1,
		Points = {
			{ 451.5, -498 },
			{ 451.5, -261 },
		},
	},
	{
		-- Out of the front of the crash-scene jam, east along Canal St, a lane
		-- change past the parked run, right onto Loop East.
		Name = "Canal_East_LoopEast",
		Weight = 2,
		Points = {
			{ -135, -299.5 },
			{ 170, -299.5 },
			{ 200, -288.5 },
			{ 451.5, -288.5 },
			{ 451.5, -261 },
		},
	},
	{
		Name = "LoopEast_Foundry",
		Weight = 1,
		Points = {
			{ 451.5, -679 },
			{ 451.5, -660.5 },
			{ 342.5, -660.5 },
		},
	},
	{
		Name = "LoopWest_Foundry",
		Weight = 2,
		Points = {
			{ -451.5, -577 },
			{ -451.5, -629.5 },
			{ 40.5, -629.5 },
		},
	},
	{
		Name = "Market_South_Canal",
		Weight = 1,
		Points = {
			{ -13.5, -393 },
			{ -13.5, -341.5 },
			{ -175, -341.5 },
		},
	},
	{
		Name = "Market_North",
		Weight = 1,
		Points = {
			{ 24.5, -151 },
			{ 24.5, -412 },
		},
	},
	{
		Name = "Market_South",
		Weight = 1,
		Points = {
			{ -25.5, -534 },
			{ -25.5, -295 },
		},
	},
}

return TrafficConfig

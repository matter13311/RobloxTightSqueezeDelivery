-- The city, as data. Everything the builders place comes from here, so the
-- layout can be tuned (and the city regenerated) without touching geometry
-- code. Ground top at Y = 0.
--
-- THE SHAPE (v4). Three zones strung together like a snake, each one narrow
-- and long, joined by curving "connectors" (see the user's sketch):
--
--     Harbour  <-  (hairpin + rail tunnels)  <-  Mill District
--                                                     ^
--                                   (bridges, then turn left)
--                                                     |
--                                                 Old Town
--                                                     |
--                                                 Terminal
--
-- Every zone is built in its own LOCAL frame, identical in shape: local
-- north = -Z, Market Ave down the middle (x = 0), West St at x = -290, East St
-- at x = +290, alley blocks between, the zone entered at local z = 0 and
-- exited at its far end. The zone's Frame then rotates/moves the whole thing
-- into the world. Old Town's frame is the identity, so its local coordinates
-- ARE world coordinates (and the Terminal is south of it, at +Z).
--
-- The world outside the zones and connectors is sea, so nothing can drive
-- around a permit crossing: the only ways between zones are the connector
-- roads, and each crosses one gated bridge or tunnel.
--
-- WIDTHS (measured vehicles: starter 8.2, pickup 10.3, box 11.3, straight
-- 11.6, hitch truck ~12 x 34, +trailer ~75 long):
--   Market Ave 76 = 4 x 12 lanes + a 28-wide centre strip that carries the
--   elevated express deck (and its ramps, which split the road). Streets 34.
--   Alleys: 13.5 tight (starter/pickup), 15.5 snug (box/straight squeeze),
--   20-24 standard and 26-32 wide (with clutter/parked-car bands that keep a
--   13-16 stud channel). No alley is designed for the rig. (v4.2: tight was
--   11.5 and snug 14 - play testers kept scraping, and a pickup had 0.6 studs
--   a side.)
--   Angled legs ("curves") run WIDER than their alley (AlleyCurve) and the
--   straight legs flare out to meet them, and every one is shallow (~25-30
--   degrees): at 45 degrees and alley width a truck could not make the turn
--   without banging both walls.
--
-- ZONE IDENTITY. The grid is shared (it has to be: the connectors join at
-- Market), so a zone gets its own feel from what is built ON it: Style (facades,
-- and `sidewalk` - cobbles / flagstones / boardwalk, the roadside a driver sees),
-- and `Roundabouts` (Old Town: the plain signalled grid; Mill: two mini-
-- roundabouts round a cog; Harbour: one round an anchor).
--
-- DESTINATIONS: most sit INSIDE the alleys (access facing an alley leg), so
-- that the alleys are where the work is - play testers who stuck to the main
-- roads never found them. The rig destinations stay on the open roads.

local L = {}

L.Version = 4

L.HalfWidth = 380 -- zone land, local x -380..380
L.SidewalkWidth = 6
L.WestSt = { x = -290, x1 = -307, x2 = -273, w = 34 }
L.Market = { x = 0, x1 = -38, x2 = 38, w = 76 }
L.EastSt = { x = 290, x1 = 273, x2 = 307, w = 34 }
L.Strip = 14 -- Market centre strip half-width (x -14..14)

-- Market lanes (local x): southbound on the west half, northbound on the east.
L.MarketLanes = { SBOuter = -32, SBInner = -20, NBInner = 20, NBOuter = 32 }
L.StreetLanes = { WestSB = -294, WestNB = -284, EastSB = 284, EastNB = 294, WestPark = -303, EastPark = 303 }

-- Elevated express: a 2-lane deck over Market's centre strip in every zone,
-- with a two-way ramp at each end of the zone that drops into the strip.
L.Express = { deckTop = 24, deckThick = 2, width = 28, rampLength = 200, pillarEvery = 44 }
-- The express LINK between zones: branches off the deck at a zone's connector
-- end, runs over Market's west (local -x) lanes to the zone edge, then over
-- the connector's Market road to the next zone. Centre line at local x
-- LinkX inside a zone; high walls all the way; it climbs to LinkFlyoverTop to
-- clear the railway. LinkMerge = length of the S-curve taper that peels the
-- link off the deck (max ~16 deg of heading change; the shortest deck, Harbour's,
-- is 166 long, so keep it under that).
L.LinkX = -28.5
L.LinkWallHeight = 12
L.LinkFlyoverTop = 34
L.LinkMerge = 150
-- Straight pieces the taper is cut into. Each one costs 4 wedges of deck plus
-- a wall box, so this is the knob for part count vs smoothness (16 looked
-- silky; 5 is visibly faceted but still turns in gentle ~9 deg steps).
L.LinkTaperSteps = 5
-- Market narrows to a tight local street once it leaves a zone.
L.ConnectorWidths = { Market = 36 }

-- How far the terrace beside a connector road reaches out from the kerb:
-- SidewalkWidth of footpath, then the buildings. Zone needs it too, to know
-- how wide a mouth to leave in its end wall for the connector to pass.
L.ConnectorBand = L.SidewalkWidth + 30

-- How finely a connector is sampled, and so how many parts it costs. Every
-- surface on a connector - road, pavements, express deck - is tiled from the
-- SAME sample points, so these two numbers set the part count of the whole
-- thing almost on their own.
--
-- v4.3 raised them a long way (both were effectively 16). The curves used to
-- be tiled so finely that a connector ran to thousands of triangles, and the
-- door mirrors - which can only rank and draw so many parts before the
-- spatial query stops returning a stable set - dropped triangles out of the
-- road behind you as you drove. The turns now read as polygons rather than
-- smooth arcs, which is the trade that was wanted: the samples still share
-- their edges exactly, so a blockier curve has no gaps, no overlaps and
-- nothing to flicker.
L.ConnectorSample = { Straight = 40, Curve = 56, MinCurve = 5 }

-- Angled alley legs: perpendicular width = max(alley w + Extra, Min), and the
-- straight legs either side widen to the angled leg's horizontal width for
-- Flare studs before the bend, so a vehicle can start and finish the turn.
L.AlleyCurve = { Extra = 4, Min = 17, Flare = 14 }

-- Roadworks (each zone's `Roadworks` list; override per entry with `half`).
-- Half-width of the closed-off works in the inner Market lane, and so also
-- half the Static obstacle the NPC traffic changes lanes around.
--
-- 4.3, not the 6 this used to be: at 6 the escape lane past the works was too
-- narrow for a wide vehicle (a Box Truck is 11.3) and NPC cars queued in it
-- instead of getting by. Narrowed by hand in Studio at Old Town first - and
-- in TrafficRoutes.luau, which carried a warning that regenerating would
-- revert it; regenerating now reproduces 15.7/24.3 exactly, so it will not.
L.RoadworksHalf = 4.3

-- Mini-roundabouts on Market Ave (a zone's `Roundabouts` list, see
-- Junctions.luau). Drivable: the kerbed island tops out at pavement height.
--   Radius   default island radius
--   Kerb     kerb ring around it
--   CarHalf  half the widest NPC car; the detour that steers NPC traffic round
--            the island passes at Radius + Kerb + CarHalf from its centre, which
--            has to stay inside the 34-deep cross road (so Radius <= ~6)
L.Roundabout = { Radius = 6, Kerb = 0.9, CarHalf = 5.4 }

L.SpaceSize = Vector2.new(16, 42)
L.RigSpaceSize = Vector2.new(18, 82)
L.WarehouseDepth = 30

L.SeaY = -6 -- water surface
L.LandBottom = -9 -- land slabs reach down past the water, so their sides read as quay walls
L.World = { x1 = -2400, z1 = -3900, x2 = 900, z2 = 800 } -- the sea

-- The city seen from inside (see Backdrop.luau): the sea outside the walls is
-- covered by ground and a low-poly skyline, EXCEPT these rects, which stay
-- open water. Harbour's quay faces east, so its sea is the one that is kept.
L.Backdrop = {
	WaterRects = { { x1 = -700, z1 = -3900, x2 = 900, z2 = -2450 } },
	EdgeBand = 320, -- skyline kept along the world edge even beside open water
}

--=============================================================================
-- Zones
--=============================================================================

-- Alley spec: { Name, Theme, w, Path = { {x=, z=?}, ... } from the south end
-- of the segment to the north end (first/last z default to the segment ends),
-- Branches = { { z, w, to = "market"|"street", Name, Theme } } }.
-- Path legs: same x = straight north-south; same z = a sharp dog-leg; both
-- differ = an angled "curve".
-- An alley's north end x must EQUAL the next segment's south end x on the
-- same side, so the two mouths face each other across the cross road and a
-- driver coming out can see straight down the next alley (play testers who
-- came out of Bin Juice Row missed Mirror Snapper 44 studs to the left).

L.Zones = {
	{
		Id = 1,
		Key = "OldTown",
		Name = "Old Town",
		Style = "OldTown",
		Permit = nil,
		Frame = CFrame.new(),
		Entry = 20, -- local z of the south edge (Terminal Rd's south edge)
		Exit = -990, -- local z of the north edge (Canal Walk's north edge)
		CrossRoads = {
			{ Name = "Terminal Rd", zc = 0, w = 40 },
			{ Name = "Brick St", zc = -313, w = 34 },
			{ Name = "Ropewalk", zc = -633, w = 34 },
			{ Name = "Canal Walk", zc = -973, w = 34 },
		},
		Segments = {
			{
				z1 = -296, z2 = -20,
				West = { Name = "Pigeon Pass", Theme = "pigeon", w = 13.5,
					Path = { { x = -160 }, { x = -160, z = -140 }, { x = -140, z = -190 }, { x = -140 } },
					Branches = { { z = -90, w = 13.5, to = "street", Name = "Whisker Way", Theme = "tight" },
						{ z = -250, w = 18, to = "market", Name = "Soup Spoon Slip", Theme = "market" } } },
				East = { Name = "Bin Juice Row", Theme = "garbage", w = 24,
					Path = { { x = 150 }, { x = 150, z = -120 }, { x = 176, z = -120 }, { x = 176 } },
					Branches = { { z = -70, w = 18, to = "market", Name = "Gutter Run", Theme = "garbage" },
						{ z = -230, w = 15.5, to = "street", Name = "Elbow Room", Theme = "junk" } } },
			},
			{
				z1 = -616, z2 = -330,
				West = { Name = "Laundry Row", Theme = "laundry", w = 22,
					Path = { { x = -140 }, { x = -140, z = -440 }, { x = -150, z = -440 }, { x = -150 } },
					Branches = { { z = -500, w = 16, to = "market", Name = "Tangle Alley", Theme = "laundry" },
						{ z = -600, w = 13.5, to = "street", Name = "Bottleneck", Theme = "tight" } } },
				East = { Name = "Mirror Snapper", Theme = "tight", w = 13.5,
					Path = { { x = 176 }, { x = 176, z = -455 }, { x = 150, z = -515 }, { x = 150 } },
					Branches = { { z = -380, w = 13.5, to = "market", Name = "Paper Doll Pass", Theme = "tight" },
						{ z = -575, w = 20, to = "street", Name = "Grease Trap", Theme = "garbage" } } },
			},
			{
				z1 = -956, z2 = -650,
				West = { Name = "Rat Run", Theme = "rats", w = 20,
					Path = { { x = -150 }, { x = -150, z = -750 }, { x = -122, z = -805 }, { x = -122 } },
					Branches = { { z = -700, w = 16, to = "market", Name = "Crooked Mile", Theme = "junk" },
						{ z = -830, w = 15.5, to = "street", Name = "Puddle Jump", Theme = "cardboard" },
						{ z = -940, w = 13.5, to = "street", Name = "Hairpin Hollow", Theme = "tight" } } },
				East = { Name = "Noodle Row", Theme = "noodle", w = 30,
					Path = { { x = 150 }, { x = 150 } },
					Branches = { { z = -680, w = 18, to = "market", Name = "Lantern Lane", Theme = "noodle" },
						{ z = -900, w = 15.5, to = "street", Name = "Chopstick Cut", Theme = "noodle" } } },
			},
		},
		Destinations = {
			{ Name = "Textile Works", rect = { 188, -216, 267, -138 }, access = "W", spaces = 2 }, -- off Bin Juice Row
			{ Name = "Lumber Yard", rect = { -267, -560, -184, -380 }, access = "W", spaces = 2, rig = true },
			{ Name = "Night Market", rect = { 58, -820, 135, -740 }, access = "E", spaces = 2 },
			{ Name = "Brick Lane Supply", rect = { -110, -930, -44, -850 }, access = "W", spaces = 2, depth = 20 },
			{ Name = "Cold Storage", rect = { -248, -732, -160, -662 }, access = "E", spaces = 2, depth = 24 }, -- off Rat Run
		},
		Landmarks = {
			{ Kind = "ClockTower", x = 75, z = -262, Label = "Clock Tower" },
			{ Kind = "Theatre", x = -80, z = -560, Label = "Grand Theatre" },
			{ Kind = "Paifang", x = 150, z = -656, Label = "Noodle Row Gate" },
			{ Kind = "Church", x = 215, z = -780, Label = "Canal Church" },
		},
		-- ExtraCones: a cone at the works' south mouth, added by hand in Studio
		Roadworks = { { lane = "NBInner", z1 = -480, z2 = -440, ExtraCones = { { 20, -440.5 } } } },
		-- Hand moves the generator can't derive, applied after the zone is
		-- built (local frame). Any part in `Folder` named in `Names` within 2.5
		-- studs (XZ) of `From` is shifted by `Delta`. This blade sat where the
		-- express deck blocked it, so it was slid up the street.
		Nudges = {
			{ Folder = "Signs", Names = { "AlleyNeonBlade", "AlleyNeonEdge" }, From = Vector3.new(41, 12.1, -58.4), Delta = Vector3.new(0, 0, -21.5) },
		},
		-- Street incidents in the inner lanes of West/East St (see Incidents.luau
		-- for where they are allowed: never on a stretch a Block circuit drives).
		Incidents = {
			{ kind = "crash", side = "East", z = -760 },
			{ kind = "breakdown", side = "West", z = -895 },
		},
		Ramps = { South = -40, North = -950 },
	},
	{
		Id = 2,
		Key = "Mill",
		Name = "Mill District",
		Style = "Mill",
		Permit = "CanalBridge",
		-- local north -> world west
		Frame = CFrame.new(-420, 0, -1840) * CFrame.Angles(0, math.rad(90), 0),
		Entry = 0,
		Exit = -1000,
		CrossRoads = {
			{ Name = "Mill Rd", zc = -17, w = 34 },
			{ Name = "Foundry St", zc = -337, w = 34 },
			{ Name = "Tannery Rd", zc = -667, w = 34 },
			{ Name = "Sidings Rd", zc = -983, w = 34 },
		},
		Segments = {
			{
				z1 = -320, z2 = -34,
				West = { Name = "Close Shave", Theme = "tight", w = 13.5,
					Path = { { x = -150 }, { x = -150, z = -190 }, { x = -126, z = -245 }, { x = -126 } },
					Branches = { { z = -90, w = 13.5, to = "market", Name = "Sparky's Squeeze", Theme = "tight" },
						{ z = -290, w = 13.5, to = "street", Name = "Paper Cut", Theme = "tight" } } },
				East = { Name = "Tin Can Alley", Theme = "recycling", w = 24,
					Path = { { x = 160 }, { x = 160, z = -150 }, { x = 130, z = -150 }, { x = 130 } },
					Branches = { { z = -80, w = 16, to = "market", Name = "Cog Lane", Theme = "scrap" },
						{ z = -290, w = 15.5, to = "street", Name = "Bucket Row", Theme = "recycling" } } },
			},
			{
				z1 = -650, z2 = -354,
				West = { Name = "Fishbone Cut", Theme = "scrap", w = 22,
					Path = { { x = -126 }, { x = -126, z = -492 }, { x = -150, z = -548 }, { x = -150 } },
					Branches = { { z = -400, w = 16, to = "market", Name = "Smokestack Slip", Theme = "scrap" },
						{ z = -620, w = 18, to = "market", Name = "Rust Bucket Row", Theme = "junk" },
						{ z = -470, w = 15.5, to = "street", Name = "Wonky Way", Theme = "cardboard" } } },
				East = { Name = "Scrape Street", Theme = "scrap", w = 16,
					Path = { { x = 130 }, { x = 130 } },
					Branches = { { z = -420, w = 15.5, to = "street", Name = "Knuckle Lane", Theme = "junk" },
						{ z = -600, w = 20, to = "market", Name = "Soot Row", Theme = "garbage" } } },
			},
			{
				z1 = -966, z2 = -684,
				West = { Name = "Muddy Boots", Theme = "cardboard", w = 26,
					Path = { { x = -150 }, { x = -150 } },
					Branches = { { z = -740, w = 13.5, to = "street", Name = "Tight Spot", Theme = "tight" },
						{ z = -900, w = 13.5, to = "market", Name = "Squeaky Gap", Theme = "tight" } } },
				East = { Name = "Rattle Row", Theme = "scrap", w = 20,
					Path = { { x = 130 }, { x = 130, z = -805 }, { x = 166, z = -862 }, { x = 166 } },
					Branches = { { z = -720, w = 18, to = "market", Name = "Anvil Alley", Theme = "junk" },
						{ z = -930, w = 16, to = "street", Name = "Clatter Cut", Theme = "recycling" } } },
			},
		},
		Destinations = {
			{ Name = "Paper Mill", rect = { 185, -260, 267, -60 }, access = "E", spaces = 2, rig = true },
			{ Name = "Foundry Supply", rect = { -112, -474, -44, -414 }, access = "W", spaces = 2, depth = 20 }, -- off Fishbone Cut
			{ Name = "Tire Depot", rect = { 140, -783, 245, -697 }, access = "W", spaces = 2 }, -- off Rattle Row
			{ Name = "Scrap Yard", rect = { -252, -948, -163, -858 }, access = "E", spaces = 2 }, -- off Muddy Boots
		},
		Landmarks = {
			{ Kind = "WaterTower", x = -80, z = -200, Label = "Water Tower" },
			{ Kind = "Chimneys", x = 200, z = -170, Label = "Twin Chimneys", OnRoof = true },
			{ Kind = "GasHolder", x = 90, z = -760, Label = "Gas Holder" },
		},
		Roadworks = { { lane = "NBInner", z1 = -520, z2 = -480 } },
		-- Mini-roundabouts on Market: `road` indexes CrossRoads. No traffic
		-- lights at these junctions; NPC crossings are steered round the island.
		Roundabouts = { { road = 2 }, { road = 3 } },
		-- A lamp on the express link that was deleted by hand in Studio (local
		-- frame). Delete = true removes the matching part instead of moving it.
		Nudges = {
			{ Folder = "Express", Names = { "DeckLight" }, From = Vector3.new(-15.7, 33, -304), Delete = true },
		},
		-- Street incidents in the inner lanes of West/East St (see Incidents.luau
		-- for where they are allowed: never on a stretch a Block circuit drives).
		Incidents = {
			{ kind = "delivery", side = "West", z = -150 },
			{ kind = "roadblock", side = "East", z = -800 },
			{ kind = "breakdown", side = "West", z = -812 },
		},
		Ramps = { South = -54, North = -946 },
	},
	{
		Id = 3,
		Key = "Harbour",
		Name = "Harbour",
		Style = "Harbour",
		Permit = "HarbourTunnel",
		-- local north -> world east
		Frame = CFrame.new(-1440, 0, -3110) * CFrame.Angles(0, math.rad(-90), 0),
		Entry = 0,
		Exit = -760, -- quay edge
		QuayFrom = -674, -- apron starts north of Quay Rd
		CrossRoads = {
			{ Name = "Harbour Rd", zc = -17, w = 34 },
			{ Name = "Chandler St", zc = -337, w = 34, Dirt = true },
			{ Name = "Quay Rd", zc = -657, w = 34 },
		},
		DirtStreets = { West = true }, -- West St is a gravel road in the Harbour
		Segments = {
			{
				z1 = -320, z2 = -34,
				West = { Name = "Soggy Box Lane", Theme = "cardboard", w = 24,
					Path = { { x = -150 }, { x = -150, z = -160 }, { x = -124, z = -215 }, { x = -124 } },
					Branches = { { z = -260, w = 16, to = "street", Name = "Barnacle Bend", Theme = "docks" },
						{ z = -110, w = 18, to = "market", Name = "Net Mender's Walk", Theme = "fish" } } },
				East = { Name = "Dock Hop", Theme = "docks", w = 28,
					Path = { { x = 155 }, { x = 155 } },
					Branches = { { z = -140, w = 18, to = "market", Name = "Chowder Chute", Theme = "fish" },
						{ z = -250, w = 18, to = "street", Name = "Rope Walk", Theme = "docks" } } },
			},
			{
				z1 = -640, z2 = -354,
				West = { Name = "Stinky Pete's", Theme = "fish", w = 26,
					Path = { { x = -124 }, { x = -124, z = -470 }, { x = -150, z = -470 }, { x = -150 } },
					Branches = { { z = -420, w = 20, to = "market", Name = "Gull Alley", Theme = "fish" },
						{ z = -600, w = 13.5, to = "street", Name = "Eel Squeeze", Theme = "tight" } } },
				East = { Name = "Salt Lane", Theme = "docks", w = 22,
					Path = { { x = 155 }, { x = 155, z = -485 }, { x = 166, z = -545 }, { x = 166 } },
					Branches = { { z = -400, w = 18, to = "market", Name = "Tide Cut", Theme = "docks" },
						{ z = -600, w = 18, to = "street", Name = "Anchor Row", Theme = "junk" } } },
			},
		},
		Destinations = {
			{ Name = "Rail Depot", rect = { -250, -144, -162, -46 }, access = "E", spaces = 2 }, -- off Soggy Box Lane
			{ Name = "Fish Market", rect = { 166, -466, 250, -362 }, access = "W", spaces = 2 }, -- off Salt Lane
			{ Name = "North Docks", rect = { 150, -760, 300, -674 }, access = "S", spaces = 3 },
			{ Name = "Container Terminal", rect = { -140, -760, 130, -674 }, access = "S", spaces = 3, rig = true },
		},
		Landmarks = {
			{ Kind = "BigFish", x = -86, z = -230, Label = "Big Fish" },
			{ Kind = "Lighthouse", x = 340, z = -735, Label = "Lighthouse" },
			{ Kind = "Cranes", x = -250, z = -720, Label = "Quay Cranes" },
		},
		Roadworks = { { lane = "NBInner", z1 = -470, z2 = -430 } },
		-- Chandler St is the one Harbour junction no NPC circuit crosses.
		Roundabouts = { { road = 2 } },
		-- Street incidents in the inner lanes of West/East St (see Incidents.luau
		-- for where they are allowed: never on a stretch a Block circuit drives).
		Incidents = {
			{ kind = "crash", side = "East", z = -120 },
			{ kind = "breakdown", side = "West", z = -195 },
			{ kind = "delivery", side = "West", z = -470 },
			{ kind = "roadblock", side = "East", z = -470 },
		},
		Ramps = { South = -54, North = -620 },
	},
}

--=============================================================================
-- Connectors
--=============================================================================

-- Each connector carries ONE local road - Market, under the express link -
-- from the end of one zone to the start of the next, along a smooth curve
-- through a straight "bundle" section where it crosses a gated bridge or
-- tunnel.
--
-- v4.3: there used to be FOUR local roads here (West St, Market, East St and
-- a tight lane) plus the express link. Four parallel ways between two zones
-- meant none of them was ever busy, so the slow local route was no slower
-- than the toll road and the permit bought nothing. One local road carries
-- all of it, and the Hazards below make sure it earns its reputation. West St
-- and East St now stop at the water's edge at each zone end (Zone rails them
-- off), and traffic for the next zone turns onto Market at the last cross
-- road, which every zone already has within ~20 studs of its edge.
L.Bundle = { Market = 0 }

-- What is parked on the one local road, as a fraction of the way along it
-- (0 = leaving the first zone, 1 = arriving at the second). `side` is which
-- half of the road it takes: -1 is the driver's left leaving the first zone.
-- Anything landing on the bridge/tunnel span is skipped by the builder, and
-- every piece leaves the other half of the 36-wide road open.
--
--   works      a dug-up lane: trench, plates, barriers, cones, ROADWORKS
--   breakdown  a car with hazards, a warning triangle and a cone
--   roadblock  barriers across one half, SINGLE FILE, a taper of cones
--   rubbish    a skip, bins and bags spilling off the kerb into the lane
local HAZARDS_CANAL = {
	{ at = 0.14, kind = "rubbish", side = 1 },
	{ at = 0.58, kind = "works", side = -1 }, -- the Canal bundle IS the bridge: nothing fits between 0.17 and 0.38
	{ at = 0.44, kind = "breakdown", side = 1 },
	{ at = 0.72, kind = "roadblock", side = -1 },
	{ at = 0.86, kind = "rubbish", side = -1 },
}
local HAZARDS_RAIL = {
	{ at = 0.1, kind = "breakdown", side = -1 },
	{ at = 0.22, kind = "works", side = 1 },
	{ at = 0.34, kind = "rubbish", side = -1 },
	{ at = 0.62, kind = "roadblock", side = 1 },
	{ at = 0.76, kind = "works", side = -1 },
	{ at = 0.9, kind = "rubbish", side = 1 },
}

L.Connectors = {
	{
		Key = "Canal",
		From = 1,
		To = 2,
		Permit = "CanalBridge",
		Crossing = "Bridge",
		Hazards = HAZARDS_CANAL,
		-- bundle centre line: heading north along x = 0
		Bundle = { origin = Vector3.new(0, 0, -1240), dir = Vector3.new(0, 0, -1), length = 80 },
		ConvergeLength = 250, -- zone exit -> bundle start
		Gap = { from = 0, to = 80 }, -- the water gap, along the bundle
	},
	{
		Key = "Rail",
		From = 2,
		To = 3,
		Permit = "HarbourTunnel",
		Crossing = "Tunnel",
		Hazards = HAZARDS_RAIL,
		-- bundle heading north along x = -1760
		Bundle = { origin = Vector3.new(-1760, 0, -2360), dir = Vector3.new(0, 0, -1), length = 240 },
		Gap = { from = 80, to = 160 }, -- the embankment, along the bundle
	},
}

L.Permits = {
	CanalBridge = { DisplayName = "Canal Bridge Permit", ZoneName = "Mill District" },
	HarbourTunnel = { DisplayName = "Harbour Tunnel Permit", ZoneName = "Harbour" },
}

--=============================================================================
-- Terminal (Old Town frame = world)
--=============================================================================

L.Terminal = {
	Yard = { x1 = -300, z1 = 20, x2 = 300, z2 = 330 },
	-- 16 workshops in one row, all facing north onto the yard
	Garage = { bays = 16, pitch = 26, doorZ = 248, backZ = 312, height = 26 }, -- pulled 70 closer to the gate (2026-09-21)
	Dock = { x1 = -300, x2 = -262, z1 = 60, z2 = 270, spaces = 8 },
	Freight = { x1 = 262, x2 = 300, z1 = 120, z2 = 270, bays = 3 },
	TrailerStalls = { x1 = 190, x2 = 252, firstZ = 50, pitch = 22, count = 3 },
	Gate = { x1 = -70, x2 = 70 }, -- the main exit onto Terminal Rd
}

return L

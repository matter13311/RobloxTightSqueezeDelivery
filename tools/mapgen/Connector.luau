-- The road between two zones, in WORLD space. It runs:
--
--   zone exit --(smooth curve)--> bundle start --(straight)--> bundle end
--   --(smooth curve)--> next zone's entry
--
-- The straight "bundle" section is where it crosses: a water gap it bridges
-- (Canal) or a rail embankment it tunnels through (Rail), gated by permit
-- where the crossing starts.
--
-- Between the zones the city carries on: Market narrows to a tight local
-- street (36) lined with buildings, no verges.
--
-- Above it runs the EXPRESS LINK: a walled elevated road that branches off
-- one zone's express deck (Zone builds that end of it) and joins the next
-- zone's. It is part of the toll road, and has its own permit gate.
--
-- ONE LOCAL ROAD (v4.3). There used to be four down here - West St, Market,
-- East St and a tight lane - and the trouble with four was that none of them
-- was ever busy: the local route cost nothing but distance, so the express
-- permit bought nothing. Now everything not paying the toll shares Market,
-- and the Hazards in Layout park roadworks, breakdowns, roadblocks and
-- rubbish on it so the slow way round is genuinely slow. The buildings that
-- lined the other three roads went with them.
--
-- PART COUNT. Every surface here - road, pavements, express deck - is tiled
-- from the SAME sample points, so a surface's neighbour shares its edge
-- exactly and nothing overlaps or flickers. A straight segment is ONE box
-- part (U.slab); only the curves spend exact triangles (U.tri), and they are
-- sampled coarsely enough (L.ConnectorSample) to read as polygons. That
-- matters because the door mirrors can only rank and draw so many parts
-- before their spatial query stops returning a stable set, and the old
-- finely-tiled connectors were dense enough to drop triangles out of the
-- road behind you.

local CollectionService = game:GetService("CollectionService")

local U = require(script.Parent.Util)
local L = require(script.Parent.Layout)
local Style = require(script.Parent.Style)

local Connector = {}

local SAMPLE = L.ConnectorSample
local STEP = SAMPLE.Straight
local SW = L.SidewalkWidth
local OUTER = L.ConnectorBand -- footpath + terrace outside the road
local METAL = Color3.fromRGB(70, 72, 78)
local BRICK = Color3.fromRGB(125, 72, 56)
local YELLOW = Color3.fromRGB(230, 185, 40)
local CONCRETE = Color3.fromRGB(170, 166, 158)
local ORANGE = Color3.fromRGB(240, 110, 20)
local HAZARD_OFF = Color3.fromRGB(120, 60, 10) -- StalledCarHazards.client blinks these
local BOARD = Color3.fromRGB(235, 235, 230)
local BOARD_RED = Color3.fromRGB(190, 45, 40)
local DECO = { CanCollide = false, CanQuery = false, CastShadow = false }

local function rightOf(d)
	return Vector3.new(-d.Z, 0, d.X)
end

local function smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- points + per-point { inGap, blend } for one road. `blend` runs 0 at a zone
-- edge to 1 in the bundle (road width and link offset ease with it).
local function sampleRoad(p0, d0, b0, b1, dir, p1, d1, n1, n3, gap, length)
	local pts, inGap, blend = {}, {}, {}
	local turn1 = d0:Dot(dir) < 0.9
	local turn3 = d1:Dot(dir) < 0.9
	for i, p in U.hermite(p0, d0, b0, dir, n1, turn1 and 1.05 or 0.6, turn1 and 1.05 or 0.6) do
		if i <= n1 then
			table.insert(pts, p)
			table.insert(inGap, false)
			table.insert(blend, smooth(((i - 1) / n1) / 0.55))
		end
	end
	-- straight: stations at every STEP plus the gap edges (the far end comes
	-- from the second curve)
	local stations = { 0, gap.from, gap.to }
	local s = STEP
	while s < length do
		table.insert(stations, s)
		s += STEP
	end
	table.sort(stations)
	local dedup = {}
	for _, v in stations do
		if v < length - 0.5 and (#dedup == 0 or math.abs(dedup[#dedup] - v) > 0.5) then
			table.insert(dedup, v)
		end
	end
	for _, v in dedup do
		table.insert(pts, b0 + dir * v)
		table.insert(inGap, v >= gap.from - 0.01 and v < gap.to - 0.01)
		table.insert(blend, 1)
	end
	for i, p in U.hermite(b1, dir, p1, d1, n3, turn3 and 1.05 or 0.6, turn3 and 1.05 or 0.6) do
		table.insert(pts, p)
		table.insert(inGap, false)
		table.insert(blend, smooth((1 - (i - 1) / n3) / 0.55))
	end
	return pts, inGap, blend, dedup
end

--=============================================================================
-- Hazards: what makes the one local road the slow way round
--=============================================================================
-- With a single local road between zones, this is where the "inconvenient
-- route" actually lives. Each piece takes ONE half of the 36-wide road and
-- leaves the other open, so the road is always passable - just slow, blind
-- and awkward in a long vehicle - and each is built around a sample point on
-- the curve, in world space.
--
-- `x` is the frame a piece is built in: x.c the road centre at that sample,
-- x.rgt across it, x.fwd along it (towards the second zone), x.half the road
-- half-width there, x.side which half the piece takes.

local function hzAt(x, lat, along, y)
	return x.c + x.rgt * lat + x.fwd * (along or 0) + Vector3.new(0, y or 0, 0)
end

local function hzCone(x, lat, along)
	local p = hzAt(x, lat, along, 1.2)
	U.part(x.parent, "Cone", Vector3.new(1.2, 2.4, 1.2), CFrame.new(p), { Material = Enum.Material.SmoothPlastic, Color = ORANGE })
	U.part(x.parent, "ConeStripe", Vector3.new(1.3, 0.35, 1.3), CFrame.new(p + Vector3.new(0, 0.3, 0)), {
		Material = Enum.Material.SmoothPlastic, Color = Color3.new(1, 1, 1), CanCollide = false, CanQuery = false, CastShadow = false,
	})
end

-- a red-and-white board on legs. `face` is the way it looks; its width runs
-- across that, so pass x.fwd for a board ACROSS the road and x.rgt for one
-- running ALONG it.
local function hzBarrier(x, lat, along, width, face)
	local p = hzAt(x, lat, along, 3.1)
	local cf = CFrame.lookAt(p, p + face)
	U.part(x.parent, "Barrier", Vector3.new(width, 1.1, 0.8), cf, { Material = Enum.Material.SmoothPlastic, Color = BOARD })
	for k = -1, 1 do
		U.part(x.parent, "BarrierStripe", Vector3.new(width / 5, 1.16, 0.9), cf * CFrame.new(k * width / 3, 0, 0), {
			Material = Enum.Material.SmoothPlastic, Color = BOARD_RED, CanCollide = false, CanQuery = false, CastShadow = false,
		})
	end
	for _, sx in { -1, 1 } do
		U.part(x.parent, "BarrierLeg", Vector3.new(0.5, 3.4, 0.5), cf * CFrame.new(sx * (width / 2 - 0.6), -1.4, 0), {
			Material = Enum.Material.Metal, Color = METAL,
		})
	end
end

local function hzSign(x, text, lat, along, colour)
	local p = hzAt(x, lat, along, 3.6)
	local cf = CFrame.lookAt(p, p + x.fwd)
	local sign = U.part(x.parent, "HazardSign", Vector3.new(7, 2.6, 0.25), cf, {
		Material = Enum.Material.SmoothPlastic, Color = colour, CanCollide = false, CanQuery = false,
	})
	for _, fc in { Enum.NormalId.Front, Enum.NormalId.Back } do
		U.label(sign, fc, text, { PixelsPerStud = 20, TextColor3 = Color3.new(0, 0, 0) })
	end
	for _, dx in { -2.9, 2.9 } do
		U.part(x.parent, "HazardSignLeg", Vector3.new(0.25, 2.3, 0.25), cf * CFrame.new(dx, -2.45, 0), {
			Material = Enum.Material.Metal, Color = METAL, CanCollide = false, CanQuery = false,
		})
	end
end

-- Cones closing a half of the road off, narrowing from the centre line out
-- to `outer`, starting `from` studs away and walking in. Called once per
-- direction: the road is two-way, and a taper facing one way only leaves the
-- other lot meeting a barrier with no warning at all.
local function hzTaper(x, outer, from, count, step)
	local dir = from < 0 and 1 or -1
	for k = 0, count - 1 do
		hzCone(x, x.side * (1.5 + (math.abs(outer) - 1.5) * k / (count - 1)), from + dir * k * step)
	end
end

local CIVILIAN = { "Blue Sedan", "Green Station Wagon", "Red Hatchback", "Blue Pickup", "Taxi" }

local function hzCar(x, lat, along, yawDeg)
	local p = hzAt(x, lat, along, 0)
	local look = x.fwd
	if yawDeg and yawDeg ~= 0 then
		look = CFrame.Angles(0, math.rad(yawDeg), 0):VectorToWorldSpace(look)
	end
	local t = x.kit.Cars and x.kit.Cars:FindFirstChild(U.pick(CIVILIAN))
	if not t then
		-- no kit car: a car-sized block still reads as something in the way
		local cf = CFrame.lookAt(p + Vector3.new(0, 2.6, 0), p + Vector3.new(0, 2.6, 0) + look)
		return U.part(x.parent, "StalledCar", Vector3.new(8, 5.2, 17), cf, { Material = Enum.Material.Metal, Color = Color3.fromRGB(110, 115, 120) })
	end
	local m = U.place(t, x.parent, p.X, 0, p.Z, look)
	local cf, size = m:GetBoundingBox()
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			U.part(m, "HazardLight", Vector3.new(0.9, 0.5, 0.25),
				cf * CFrame.new(sx * (size.X / 2 - 0.9), -size.Y * 0.12, sz * (size.Z / 2 + 0.02)), {
					Material = Enum.Material.SmoothPlastic, Color = HAZARD_OFF, CanCollide = false, CanQuery = false, CastShadow = false,
				})
		end
	end
	CollectionService:AddTag(m, "StalledCar")
	return m
end

-- a MapKit prop if the kit has one, otherwise a rough box of the same size
local function hzProp(x, names, lat, along, y, fallback)
	local p = hzAt(x, lat, along, y or 0)
	local t
	for _, n in names do
		t = x.kit.Props and x.kit.Props:FindFirstChild(n)
		if t then
			break
		end
	end
	if t then
		local look = CFrame.Angles(0, U.range(0, 6.28), 0):VectorToWorldSpace(x.fwd)
		local c = U.place(t, x.parent, p.X, p.Y, p.Z, look)
		if fallback.loose then
			for _, d in (c:IsA("Model") and c:GetDescendants() or { c }) do
				if d:IsA("BasePart") then
					d.CanCollide = false
					d.CanTouch = false
				end
			end
		end
		return c
	end
	return U.part(x.parent, fallback.name, fallback.size, CFrame.new(p + Vector3.new(0, fallback.size.Y / 2, 0)) * CFrame.Angles(0, U.range(0, 6.28), 0), {
		Material = fallback.material or Enum.Material.SmoothPlastic,
		Color = fallback.color,
		CanCollide = not fallback.loose,
	})
end

local HAZ = {}

-- a dug-up half: trench, spoil, a plate, barriers all round and a taper in
function HAZ.works(x)
	local sd = x.side
	local inner, outer = sd * 2.5, sd * (x.half - 0.5)
	local mid = (inner + outer) / 2
	local wide = math.abs(outer - inner)
	U.part(x.parent, "Excavation", Vector3.new(wide - 2.5, 0.1, 26), CFrame.lookAt(hzAt(x, mid, 0, 0.06), hzAt(x, mid, 1, 0.06)), {
		Material = Enum.Material.Ground, Color = Color3.fromRGB(58, 48, 38), CanCollide = false, CanQuery = false, CastShadow = false,
	})
	U.part(x.parent, "SteelPlate", Vector3.new(wide - 4, 0.3, 7), CFrame.lookAt(hzAt(x, mid, 4, 0.15), hzAt(x, mid, 5, 0.15)), {
		Material = Enum.Material.DiamondPlate, Color = Color3.fromRGB(105, 105, 110),
	})
	for _, along in { -11, 11 } do
		U.part(x.parent, "Spoil", Vector3.new(wide - 4, 2.2, 5), CFrame.lookAt(hzAt(x, mid, along, 1.1), hzAt(x, mid, along + 1, 1.1)), {
			Material = Enum.Material.Ground, Color = Color3.fromRGB(78, 64, 50),
		})
	end
	for _, along in { -15, 15 } do
		hzBarrier(x, mid, along, wide, x.fwd)
	end
	for _, along in { -7.5, 7.5 } do
		hzBarrier(x, inner, along, 15, x.rgt * -sd)
	end
	hzTaper(x, outer, -34, 4, 5)
	hzTaper(x, outer, 34, 4, 5)
	for _, along in { -42, 42 } do
		hzSign(x, "ROADWORKS", mid, along, Color3.fromRGB(240, 150, 20))
	end
end

-- one car with its hazards on, a triangle behind it and a cone
function HAZ.breakdown(x)
	local sd = x.side
	local lane = sd * x.half * 0.55
	hzCar(x, lane, 0, 5 * sd)
	local p = hzAt(x, lane, -16, 1)
	local tri = U.part(x.parent, "WarningTriangle", Vector3.new(1.8, 1.6, 0.1), CFrame.lookAt(p, p + x.fwd), {
		Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false,
	})
	for _, fc in { Enum.NormalId.Front, Enum.NormalId.Back } do
		U.label(tri, fc, "\u{25B2}", { PixelsPerStud = 30, TextColor3 = Color3.fromRGB(230, 30, 30) })
	end
	hzCone(x, lane, -23)
end

-- half the road boarded off, with a long taper you have to read early
function HAZ.roadblock(x)
	local sd = x.side
	local inner, outer = sd * 2.5, sd * (x.half - 0.5)
	local mid = (inner + outer) / 2
	local wide = math.abs(outer - inner)
	hzBarrier(x, mid, 0, wide, x.fwd)
	hzBarrier(x, mid, 3.5, wide, x.fwd)
	hzSign(x, "SINGLE FILE", mid, -6, BOARD)
	hzTaper(x, outer, -32, 5, 5.5)
	hzCar(x, mid, 16, -4 * sd)
	-- the stalled car is 16 up the closed half, so the far taper starts past it
	hzTaper(x, outer, 40, 4, 5)
	hzSign(x, "SINGLE FILE", mid, 48, BOARD)
end

-- a skip and the bins around it, spilling off the kerb into the lane
function HAZ.rubbish(x)
	local sd = x.side
	local kerb = sd * (x.half - 4)
	U.part(x.parent, "Skip", Vector3.new(9, 5.5, 16), CFrame.lookAt(hzAt(x, kerb, 0, 2.75), hzAt(x, kerb, 1, 2.75)), {
		Material = Enum.Material.CorrodedMetal, Color = Color3.fromRGB(150, 95, 40),
	})
	local bins = { Color3.fromRGB(40, 90, 50), Color3.fromRGB(60, 60, 64), Color3.fromRGB(40, 70, 130) }
	for k, col in bins do
		local p = hzAt(x, sd * (x.half + 3), -12 + k * 3.4, 0)
		U.part(x.parent, "WheelieBin", Vector3.new(2.9, 3.1, 3), CFrame.lookAt(p + Vector3.new(0, 2.05, 0), p + Vector3.new(0, 2.05, 0) + x.rgt * sd), {
			Material = Enum.Material.SmoothPlastic, Color = col,
		})
	end
	for k = 0, 4 do
		hzProp(x, { "garbage_bag001a", "trashcluster01a_cluster", "garbage_carboard001a" },
			sd * U.range(x.half * 0.35, x.half - 1), U.range(-16, 16), 0,
			{ name = "GarbageBag", size = Vector3.new(2.6, 1.8, 2.6), color = Color3.fromRGB(35, 35, 38), loose = true })
	end
	hzProp(x, { "garbage128_composite001a", "garbage128_composite001b", "food_pile01" }, sd * (x.half - 2), -19, 0,
		{ name = "GarbagePile", size = Vector3.new(5, 1.6, 4), color = Color3.fromRGB(70, 62, 52), loose = true })
	hzCone(x, sd * x.half * 0.35, -21)
end

-- `road` is the built Market road: pts, right, ws and inGap per sample.
local function buildHazards(f, kit, spec, road, count, gapFromI, gapToI)
	local list = spec.Hazards
	if not list or #list == 0 then
		return
	end
	local hz = U.folder(f, "Hazards")
	-- arc length, so `at` is a fraction of the DRIVE rather than of the sample
	-- count (the curves are sampled coarser than the straight)
	local cum, total = { 0 }, 0
	for i = 2, count do
		total += (road.pts[i] - road.pts[i - 1]).Magnitude
		cum[i] = total
	end
	local sFrom, sTo = cum[gapFromI], cum[gapToI]
	for _, h in list do
		local target = h.at * total
		local i = count - 1
		for k = 2, count - 1 do
			if cum[k] >= target then
				i = k
				break
			end
		end
		-- never on the bridge/tunnel span, and never close enough to the
		-- permit gate to be mistaken for part of it
		local clear = not road.inGap[i] and not road.inGap[i - 1]
			and math.abs(cum[i] - sFrom) > 70 and math.abs(cum[i] - sTo) > 70
		if clear and HAZ[h.kind] then
			local rgt = road.right[i]
			HAZ[h.kind]({
				parent = U.model(hz, h.kind .. "_" .. math.floor(h.at * 100)),
				kit = kit,
				c = road.pts[i],
				rgt = rgt,
				fwd = Vector3.new(rgt.Z, 0, -rgt.X),
				half = road.ws[i] / 2,
				side = h.side,
			})
		end
	end
end

function Connector.Build(parent, kit, spec, fromZone, toZone, ctx)
	local f = U.folder(parent, "Connector_" .. spec.Key)
	local roadsF = U.folder(f, "Roads")
	local ground = U.folder(f, "Pavement")
	local blds = U.folder(f, "Buildings")
	local marks = U.folder(f, "Markings")
	local deco = U.folder(f, "Decor")
	local linkF = U.folder(f, "ExpressLink")
	local b = spec.Bundle
	local dir = b.dir.Unit
	local right = rightOf(dir)
	local gap = spec.Gap
	local ffr, tfr = fromZone.spec.Frame, toZone.spec.Frame
	local d0 = ffr.LookVector
	local d1 = tfr.LookVector
	local CW = L.ConnectorWidths
	-- the one local road the connector carries, kept as a list: the crossing,
	-- the pavements and the permit gates are all written per road
	local roads = {
		{ key = "Market", zw = L.Market.w, cw = CW.Market, fromX = 0, toX = 0, off = L.Bundle.Market },
	}
	local mStart = ffr * Vector3.new(0, 0, fromZone.result.exitEdge)
	local mEnd = tfr * Vector3.new(0, 0, toZone.result.entryEdge)
	local bm0 = b.origin
	local bm1 = b.origin + dir * b.length
	-- 1.3 is roughly how much longer the hermite arc is than its chord
	local n1 = math.max(SAMPLE.MinCurve, math.ceil((bm0 - mStart).Magnitude * 1.3 / SAMPLE.Curve))
	local n3 = math.max(SAMPLE.MinCurve, math.ceil((mEnd - bm1).Magnitude * 1.3 / SAMPLE.Curve))
	local market
	local stations
	for _, r in roads do
		local p0 = ffr * Vector3.new(r.fromX, 0, fromZone.result.exitEdge)
		local p1 = tfr * Vector3.new(r.toX, 0, toZone.result.entryEdge)
		local b0 = b.origin + right * r.off
		local b1 = b0 + dir * b.length
		r.pts, r.inGap, r.blend, stations = sampleRoad(p0, d0, b0, b1, dir, p1, d1, n1, n3, gap, b.length)
		r.b0 = b0
		r.w = r.cw
		r.ws = {}
		for i, bl in r.blend do
			r.ws[i] = r.zw + (r.cw - r.zw) * bl
		end
		r.front = SW -- kerb-to-building setback
		r.edge = 0
		if r.key == "Market" then
			market = r
		end
	end
	local count = #roads[1].pts
	-- index of the first bundle station, so a bundle distance maps to a point
	local iBundle = n1 + 1
	local function stationIndex(v)
		if math.abs(v - b.length) < 0.5 then
			return iBundle + #stations -- the first point of the second curve
		end
		for k, sv in stations do
			if math.abs(sv - v) < 0.01 then
				return iBundle + k - 1
			end
		end
		error("no station at " .. v)
	end
	local gapFromI = stationIndex(gap.from)

	local function rightAt(pts, i)
		local a = pts[math.max(1, i - 1)]
		local c = pts[math.min(#pts, i + 1)]
		local d = Vector3.new(c.X - a.X, 0, c.Z - a.Z)
		return rightOf(d.Unit)
	end
	for _, r in roads do
		r.right = {}
		for i = 1, count do
			r.right[i] = rightAt(r.pts, i)
		end
		-- exact cross-sections where the strips meet other geometry: the zone
		-- edges and every straight bundle station (gap edges, tunnel faces)
		r.right[1] = rightOf(d0)
		r.right[count] = rightOf(d1)
		for i = iBundle, iBundle + #stations do
			r.right[i] = right
		end
	end
	-- the road's edge (wall face for the lane) on `side` at sample i
	local function edge(r, i, side)
		return r.pts[i] + r.right[i] * side * (r.ws[i] / 2 + r.edge)
	end

	-- zone land (so connector buildings never spill into a zone)
	local function inZone(p)
		local a = ffr:PointToObjectSpace(p)
		if math.abs(a.X) < L.HalfWidth + 4 and a.Z > fromZone.result.exitEdge - 1 then
			return true
		end
		local c = tfr:PointToObjectSpace(p)
		if math.abs(c.X) < L.HalfWidth + 4 and c.Z < toZone.result.entryEdge + 1 then
			return true
		end
		return false
	end

	------------------------------------------------------------ roads (exact strips)
	local asphalt = { Material = Enum.Material.Asphalt, Color = Style.Asphalt }
	local depthRoad = -L.LandBottom
	for _, r in roads do
		for i = 1, count - 1 do
			local bridge = r.inGap[i] and spec.Crossing == "Bridge"
			U.slab(roadsF, "Road", edge(r, i, -1), edge(r, i, 1), edge(r, i + 1, 1), edge(r, i + 1, -1), bridge and 3 or depthRoad, asphalt)
		end
		-- parapets along the bridge span, as one continuous run per side
		if spec.Crossing == "Bridge" then
			local from
			for i = 1, count do
				local on = i < count and r.inGap[i]
				if on and not from then
					from = i
				elseif not on and from then
					for _, side in { -1, 1 } do
						local pts = {}
						for k = from, i do
							table.insert(pts, r.pts[k] + r.right[k] * side * (r.ws[k] / 2 + 0.6))
						end
						U.wallRun(roadsF, "BridgeParapet", pts, 1.2, 3.6, { Material = Enum.Material.Brick, Color = BRICK })
					end
					from = nil
				end
			end
		end
		-- a pier under each road bridge
		if spec.Crossing == "Bridge" then
			local c = r.b0 + dir * ((gap.from + gap.to) / 2)
			U.part(roadsF, "BridgePier", Vector3.new(r.w * 0.6, 12, 8), CFrame.lookAt(c + Vector3.new(0, -9, 0), c + Vector3.new(0, -9, 0) + dir), { Material = Enum.Material.Brick, Color = BRICK })
		end
		-- centre line
		for _, o in { -0.3, 0.3 } do
			for i = 1, count - 1 do
				local a = r.pts[i] + r.right[i] * o
				local c = r.pts[i + 1] + r.right[i + 1] * o
				U.segment(marks, "Line", a, c, 0.25, 0.005, 0.055, {
					Material = Enum.Material.SmoothPlastic, Color = YELLOW, CanCollide = false, CanQuery = false, CastShadow = false,
				}, 0)
			end
		end
	end

	------------------------------------------------------------ the terrace: footpath, buildings, and the land they stand on
	-- Outside the road the connector is a solid TERRACE, one box per frontage,
	-- standing on its own footing down to L.LandBottom. It is the land as much
	-- as the scenery, and that is the point three ways over:
	--
	--   * you cannot see the water past a terrace, let alone drive into it.
	--     The band used to be open paving with buildings dotted along it
	--     wherever a placement happened to succeed, so most of the connector
	--     looked out over open sea.
	--   * nothing is hidden. There used to be a 36-wide paving quad running the
	--     whole length - four triangles a segment - with a building standing on
	--     top of it, so every one of those triangles was buried. The terrace
	--     reaches the ground itself, so the only paving left is the footpath.
	--   * the footpath is a wall run (one BOX a segment) rather than a tiled
	--     quad (four WEDGES a segment), because a strip of constant width is
	--     exactly what U.wallRun already builds, joints closed and all.
	--
	-- The quay wall and the railings along the outside went with it: they were
	-- guarding an edge that no longer exists.
	--
	-- Within one sampled segment the frontage line is STRAIGHT, so the blocks
	-- along it are collinear and abut exactly - no overlap, so no coplanar
	-- facades to flicker. Only at a segment joint do two blocks turn against
	-- each other, and there each is run on past the joint by depth * tan(turn/2)
	-- so the outside of the bend closes up.
	local zoneStyle = Style.Zones[toZone.spec.Style]
	local paving = { Material = Enum.Material.Concrete, Color = Style.Sidewalk }
	local BLOCK = 26 -- target frontage for one building
	local DEPTH = OUTER - SW -- facade line to the outer face of the terrace
	local footY = L.LandBottom

	local lastH = 0
	local function height()
		-- not whole studs: overlapping neighbours on a bend never share a roof plane
		local h
		repeat
			h = U.range(zoneStyle.minH, zoneStyle.maxH + 8)
		until math.abs(h - lastH) >= 2
		lastH = h
		return h
	end
	local lamp = kit.Furniture:FindFirstChild("lamp")

	for _, r in roads do
		for _, side in { -1, 1 } do
			local function kerb(i)
				return edge(r, i, side)
			end
			local function frontAt(i)
				return kerb(i) + r.right[i] * side * SW
			end
			-- how far a block runs past a joint to close the outside of the bend
			local function jointExtra(i)
				if i <= 1 or i >= count then
					return 0
				end
				local d0, d1 = frontAt(i) - frontAt(i - 1), frontAt(i + 1) - frontAt(i)
				if d0.Magnitude < 0.05 or d1.Magnitude < 0.05 then
					return 0
				end
				local theta = math.acos(math.clamp(d0.Unit:Dot(d1.Unit), -1, 1))
				if theta < 0.004 then
					return 0
				end
				return math.min(DEPTH, DEPTH * math.tan(theta / 2))
			end

			-- the footpath, as continuous runs broken only by the crossing
			local walk = {}
			local function flushWalk()
				if #walk > 1 then
					U.wallRun(ground, "Pavement", walk, SW, 0.5 - footY, paving)
				end
				walk = {}
			end
			for i = 1, count do
				if (i < count and r.inGap[i]) or inZone(kerb(i)) then
					flushWalk()
				else
					table.insert(walk, kerb(i) + r.right[i] * side * (SW / 2) + Vector3.new(0, footY, 0))
				end
			end
			flushWalk()

			-- the terrace
			for i = 1, count - 1 do
				if r.inGap[i] then
					continue
				end
				local f0, f1 = frontAt(i), frontAt(i + 1)
				local run = Vector3.new(f1.X - f0.X, 0, f1.Z - f0.Z)
				local segLen = run.Magnitude
				if segLen < 1 then
					continue
				end
				local u = run.Unit
				local n = rightOf(u) * side -- outward, away from the road
				local nBlocks = math.max(1, math.round(segLen / BLOCK))
				local e0, e1 = jointExtra(i), jointExtra(i + 1)
				for k = 0, nBlocks - 1 do
					local a = f0 + u * (segLen * k / nBlocks) - (k == 0 and u * e0 or Vector3.zero)
					local c = f0 + u * (segLen * (k + 1) / nBlocks) + (k == nBlocks - 1 and u * e1 or Vector3.zero)
					local chord = c - a
					local len = chord.Magnitude
					if len < 1 then
						continue
					end
					local mid = a + chord / 2 + n * (DEPTH / 2)
					-- The zone test is taken 1.5 studs INSIDE each corner. The
					-- terrace's first block starts exactly on the zone edge,
					-- and inZone counts a point on the edge as inside, so an
					-- un-inset corner rejected the one block that closes the
					-- join - leaving a hole straight out to the water.
					local blocked = false
					for _, q in { a, c, a + n * DEPTH, c + n * DEPTH } do
						if inZone(q + (mid - q).Unit * 1.5) then
							blocked = true
							break
						end
					end
					if blocked then
						continue -- the zone has its own ground and frontage here
					end
					local top = height()
					local centre = Vector3.new(mid.X, (footY + top) / 2, mid.Z)
					local cf = CFrame.lookAt(centre, centre + chord)
					local metal = zoneStyle.metalChance and U.chance(zoneStyle.metalChance)
					local bp = U.part(blds, "Building", Vector3.new(DEPTH, top - footY, len), cf, {
						Material = metal and Enum.Material.CorrodedMetal or Enum.Material.Concrete,
						Color = U.pick(zoneStyle.colors),
					})
					-- only the two long faces are ever seen - the facade, and the
					-- back from across the water. The narrow ends are buried in the
					-- neighbouring block, so they used to carry a texture for nothing.
					local t = U.pick(zoneStyle.textures)
					for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
						local tx = Instance.new("Texture")
						tx.Texture = t.id
						tx.StudsPerTileU = t.u
						tx.StudsPerTileV = t.v
						tx.Color3 = t.color
						tx.Face = face
						tx.Parent = bp
					end
				end
			end

			-- a street lamp now and then on the kerb
			for i = 2, count - 1, 3 do
				if lamp and not r.inGap[i] then
					local lp = kerb(i) + r.right[i] * side * 1.2
					if not inZone(lp) then
						U.place(lamp, deco, lp.X, 0.5, lp.Z, -r.right[i] * side)
					end
				end
			end
		end
	end

	------------------------------------------------------------ the rail embankment the roads tunnel through
	local H = 26
	if spec.Crossing == "Tunnel" then
		local bundleCF = CFrame.lookAt(b.origin, b.origin + dir)
		local W = 190
		local function bbox(name, x1, x2, s1, s2, y1, y2, props)
			local cx, cs = (x1 + x2) / 2, (s1 + s2) / 2
			return U.part(f, name, Vector3.new(x2 - x1, y2 - y1, s2 - s1), bundleCF * CFrame.new(cx, (y1 + y2) / 2, -cs), props)
		end
		local brick = { Material = Enum.Material.Brick, Color = BRICK }
		local openings = {}
		for _, r in roads do
			table.insert(openings, { a = r.off - r.w / 2 - r.edge, b = r.off + r.w / 2 + r.edge, clear = 20 })
		end
		table.sort(openings, function(a, c)
			return a.a < c.a
		end)
		local x = -W
		for _, o in openings do
			if o.a > x then
				bbox("Embankment", x, o.a, gap.from, gap.to, L.LandBottom, H, brick)
			end
			bbox("Lintel", o.a, o.b, gap.from, gap.to, o.clear, H, brick)
			for _, sEnd in { gap.from - 0.5, gap.to + 0.5 } do
				bbox("Portal", o.a - 2, o.b + 2, sEnd - 0.5, sEnd + 0.5, o.clear, o.clear + 2, { Material = Enum.Material.Concrete, Color = Color3.fromRGB(165, 162, 155) })
			end
			local lt = bbox("TunnelLight", (o.a + o.b) / 2 - 3, (o.a + o.b) / 2 + 3, (gap.from + gap.to) / 2 - 1, (gap.from + gap.to) / 2 + 1, o.clear - 0.4, o.clear - 0.1, {
				Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 225, 170), CanCollide = false,
			})
			local pl = Instance.new("PointLight")
			pl.Range = 30
			pl.Brightness = 1.2
			pl.Parent = lt
			x = o.b
		end
		bbox("Embankment", x, W, gap.from, gap.to, L.LandBottom, H, brick)
		-- tracks on top, running out over the sea on a viaduct
		for _, off in { -10, 10 } do
			local sMid = (gap.from + gap.to) / 2 + off
			bbox("Ballast", -W - 500, W + 500, sMid - 6, sMid + 6, H, H + 0.6, { Material = Enum.Material.Slate, Color = Color3.fromRGB(95, 90, 85) })
			for _, ro in { -2.4, 2.4 } do
				bbox("Rail", -W - 500, W + 500, sMid + ro - 0.2, sMid + ro + 0.2, H + 0.6, H + 1.1, { Material = Enum.Material.Metal, Color = Color3.fromRGB(120, 115, 110) })
			end
		end
		for _, side in { -1, 1 } do
			bbox("Viaduct", side < 0 and -W - 500 or W, side < 0 and -W or W + 500, gap.from + 4, gap.to - 4, H - 4, H, brick)
			for k = 0, 6 do
				local px = side * (W + 40 + k * 70)
				bbox("ViaductPier", px - 5, px + 5, gap.from + 10, gap.to - 10, L.SeaY - 6, H - 4, brick)
			end
		end
		-- a parked freight train (well clear of the express flyover)
		local sTrain = (gap.from + gap.to) / 2 - 10
		local x0 = -W - 120
		for k = 0, 9 do
			local len = k == 0 and 26 or 24
			bbox(k == 0 and "Locomotive" or "Wagon", x0, x0 + len, sTrain - 4.5, sTrain + 4.5, H + 1.1, H + (k == 0 and 13 or 11), {
				Material = k == 0 and Enum.Material.Metal or Enum.Material.CorrodedMetal,
				Color = k == 0 and Color3.fromRGB(200, 150, 30) or U.pick({ Color3.fromRGB(150, 50, 40), Color3.fromRGB(40, 70, 120), Color3.fromRGB(60, 110, 60) }),
			})
			x0 += len + 2
		end
		local banner = bbox("ZoneBanner", -70, -20, gap.from - 0.9, gap.from - 0.5, 20, 25, { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(20, 60, 120), CanCollide = false })
		U.label(banner, Enum.NormalId.Back, string.upper(toZone.spec.Name) .. "  -  PERMIT HOLDERS ONLY", { PixelsPerStud = 20 })
	end

	------------------------------------------------------------ the express link over Market
	local EX = L.Express
	local LW = EX.width
	local concrete = { Material = Enum.Material.Concrete, Color = CONCRETE }
	-- centre line of the deck (top surface) at every sample
	local link = {}
	local cum = { 0 }
	for i = 1, count do
		local o = L.LinkX * (1 - market.blend[i])
		link[i] = market.pts[i] + market.right[i] * o
		if i > 1 then
			cum[i] = cum[i - 1] + (link[i] - link[i - 1]).Magnitude
		end
	end
	-- rise over the railway (deck clears the rails), flat elsewhere
	local tops = {}
	local sF, sT = cum[stationIndex(gap.from)], cum[stationIndex(gap.to)]
	for i = 1, count do
		local top = EX.deckTop
		if spec.Crossing == "Tunnel" then
			local s = cum[i]
			local up = smooth((s - (sF - 170)) / 160) * smooth(((sT + 170) - s) / 160)
			top += (L.LinkFlyoverTop - EX.deckTop) * up
		end
		tops[i] = top
		link[i] = Vector3.new(link[i].X, top, link[i].Z)
	end
	local function linkEdge(i, side, inset)
		return link[i] + market.right[i] * side * (LW / 2 - (inset or 0))
	end
	for i = 1, count - 1 do
		U.slab(linkF, "Deck", linkEdge(i, -1), linkEdge(i, 1), linkEdge(i + 1, 1), linkEdge(i + 1, -1), EX.deckThick, concrete)
	end
	-- high walls, NYC-style: you drive in a concrete canyon over the city
	for _, side in { -1, 1 } do
		local pts = {}
		for i = 1, count do
			table.insert(pts, linkEdge(i, side, 0.5))
		end
		U.wallRun(linkF, "LinkWall", pts, 1, L.LinkWallHeight, concrete)
	end
	-- centre line + wall lights
	for _, o in { -0.3, 0.3 } do
		for i = 1, count - 1 do
			local a = link[i] + market.right[i] * o + Vector3.new(0, 0.03, 0)
			local c = link[i + 1] + market.right[i + 1] * o + Vector3.new(0, 0.03, 0)
			if (c - a).Magnitude > 0.05 then
				U.part(marks, "Line", Vector3.new(0.25, 0.05, (c - a).Magnitude), CFrame.lookAt((a + c) / 2, c), {
					Material = Enum.Material.SmoothPlastic, Color = YELLOW, CanCollide = false, CanQuery = false, CastShadow = false,
				})
			end
		end
	end
	local nextLight = 0
	for i = 2, count - 1 do
		if cum[i] < nextLight then
			continue
		end
		nextLight = cum[i] + 64
		for _, side in { -1, 1 } do
			local p = linkEdge(i, side, 1.2) + Vector3.new(0, 9, 0)
			U.part(linkF, "DeckLight", Vector3.new(0.4, 0.4, 5), CFrame.lookAt(p, p + (link[i + 1] - link[i])), {
				Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 230, 180), CanCollide = false, CanQuery = false,
			})
		end
	end
	-- supports: portal frames straddling Market, columns on the pavements
	-- (in the water on the canal, on the embankment over the railway)
	local nextPier = 0
	for i = 2, count - 1 do
		if cum[i] < nextPier then
			continue
		end
		nextPier = cum[i] + 48
		local bottom = tops[i] - EX.deckThick
		local rgt = market.right[i]
		local reach = market.ws[i] / 2 + SW / 2
		local water = market.inGap[i] and spec.Crossing == "Bridge"
		local foot = water and L.SeaY - 8 or 0.5
		if market.inGap[i] and spec.Crossing == "Tunnel" then
			foot = H
		end
		local look = market.pts[i] + (market.pts[i + 1] - market.pts[i - 1])
		for _, side in { -1, 1 } do
			local p = market.pts[i] + rgt * side * reach
			if inZone(p) then
				continue
			end
			local colTop = bottom - 0.8 -- ends inside the cross beam
			U.part(linkF, "LinkColumn", Vector3.new(2.4, colTop - foot, 2.4), CFrame.lookAt(Vector3.new(p.X, (colTop + foot) / 2, p.Z), Vector3.new(look.X, (colTop + foot) / 2, look.Z)), {
				Material = Enum.Material.Metal, Color = Color3.fromRGB(62, 78, 70),
			})
		end
		local a = market.pts[i] - rgt * (reach + 1.2)
		local c = market.pts[i] + rgt * (reach + 1.2)
		if not inZone(a) and not inZone(c) then
			local mid = (a + c) / 2
			U.part(linkF, "LinkBeam", Vector3.new((c - a).Magnitude, 1.6, 2), CFrame.lookAt(Vector3.new(mid.X, bottom - 0.8, mid.Z), Vector3.new(mid.X, bottom - 0.8, mid.Z) + (market.pts[i + 1] - market.pts[i - 1]) * Vector3.new(1, 0, 1)), {
				Material = Enum.Material.Metal, Color = Color3.fromRGB(62, 78, 70),
			})
		end
	end

	------------------------------------------------------------ permit gates where each road starts to cross
	local gatesModel = ctx.permitGates
	local titles = { CanalBridge = "CANAL BRIDGE", HarbourTunnel = "HARBOUR TUNNEL" }
	local function permitGate(name, base, w, tight, high)
		-- base = centre of the road surface at the gate line
		local c = base - dir * 1
		local cf = CFrame.lookAt(c + Vector3.new(0, 9, 0), c + Vector3.new(0, 9, 0) + dir)
		local g = U.part(gatesModel, name, Vector3.new(w, 18, 2), cf, {
			Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false,
		})
		g:SetAttribute("Permit", spec.Permit)
		g:SetAttribute("Outward", -dir)
		local pc = base - dir * 9
		local pz = U.part(gatesModel, "PermitPayZone", Vector3.new(w, 10, 14), CFrame.lookAt(pc + Vector3.new(0, 5, 0), pc + Vector3.new(0, 5, 0) + dir), {
			Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false,
		})
		pz:SetAttribute("Permit", spec.Permit)
		local function boom(edgeOff, armDir, length)
			local pos = c + edgeOff + Vector3.new(0, 3.5, 0) - dir * 1.5
			local p = U.part(gatesModel, "PermitBoomPivot", Vector3.new(0.5, 0.5, 0.5), CFrame.fromMatrix(pos, armDir, Vector3.yAxis), {
				Transparency = 1, CanCollide = false, CanQuery = false,
			})
			p:SetAttribute("Permit", spec.Permit)
			p:SetAttribute("BoomLength", length)
			U.part(deco, "BoomPost", Vector3.new(1.4, 4, 1.4), CFrame.new(pos - armDir * 0.8 - Vector3.new(0, 1.5, 0)), { Material = Enum.Material.Metal, Color = YELLOW })
		end
		if w > 20 then
			boom(-right * (w / 2), right, w / 2)
			boom(right * (w / 2), -right, w / 2)
		else
			boom(-right * (w / 2), right, w)
		end
		-- sign over the approach
		local sc = base - dir * 4
		-- (ground gantries stay under the express link's deck)
		local beamY = high and L.LinkWallHeight + 4 or 19
		for _, s in { -1, 1 } do
			local pp = sc + right * s * (w / 2 + 1.5)
			U.part(deco, "GantryPost", Vector3.new(1.2, beamY + 0.2, 1.2), CFrame.new(pp + Vector3.new(0, (beamY + 0.2) / 2, 0)), { Material = Enum.Material.Metal, Color = METAL })
		end
		U.part(deco, "GantryBeam", Vector3.new(w + 4, 1, 1), CFrame.lookAt(sc + Vector3.new(0, beamY, 0), sc + Vector3.new(0, beamY, 0) + dir), { Material = Enum.Material.Metal, Color = METAL })
		local sw = math.min(w, 40)
		local sy = beamY - 2.5
		local sign = U.part(deco, "PermitSign", Vector3.new(sw, tight and 3 or 4, 0.4), CFrame.lookAt(sc + Vector3.new(0, sy, 0), sc + Vector3.new(0, sy, 0) + dir), {
			Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(150, 30, 30), CanCollide = false,
		})
		for _, fc in { Enum.NormalId.Front, Enum.NormalId.Back } do
			U.label(sign, fc, titles[spec.Permit] .. (tight and "" or "  -  PERMIT HOLDERS ONLY"), { PixelsPerStud = 20 })
		end
	end
	for _, r in roads do
		permitGate(spec.Key .. r.key .. "Gate", r.b0 + dir * gap.from, r.w, r.tight, false)
	end
	-- and on the express link, at the same line
	permitGate(spec.Key .. "ExpressGate", link[gapFromI], LW - 2, false, true)

	buildHazards(f, kit, spec, market, count, gapFromI, stationIndex(gap.to))

	return f
end

return Connector

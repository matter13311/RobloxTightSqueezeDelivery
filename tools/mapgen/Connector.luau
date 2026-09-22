-- The roads between two zones, in WORLD space. Each road runs:
--
--   zone exit --(smooth curve)--> bundle start --(straight)--> bundle end
--   --(smooth curve)--> next zone's entry
--
-- The roads pinch together into a "bundle" (100 apart) for the crossing: a
-- water gap bridged road by road (Canal), or a rail embankment each road
-- tunnels through (Rail). Every road - including the tight lane - is gated by
-- permit where it starts to cross.
--
-- Between the zones the city carries on: the roads narrow to tight local
-- streets (Market 36, the streets 26) lined with buildings, no verges. Every
-- surface on the curves - roads, pavements, the express deck - is tiled from
-- exact triangles (U.tri), so nothing overlaps and nothing flickers.
--
-- Above Market runs the EXPRESS LINK: a walled elevated road that branches
-- off one zone's express deck (Zone builds that end of it) and joins the next
-- zone's. It is part of the toll road, and has its own permit gate.
--
-- All roads are sampled at the SAME curve parameters so point i on one road
-- sits beside point i on its neighbour; everything between them is built quad
-- by quad from those pairs.

local U = require(script.Parent.Util)
local L = require(script.Parent.Layout)
local Style = require(script.Parent.Style)

local Connector = {}

local STEP = 16
local SW = L.SidewalkWidth
local OUTER = SW + 30 -- pavement + building row outside the outermost roads
local DMAX = 40 -- deepest a building gets
local METAL = Color3.fromRGB(70, 72, 78)
local BRICK = Color3.fromRGB(125, 72, 56)
local YELLOW = Color3.fromRGB(230, 185, 40)
local CONCRETE = Color3.fromRGB(170, 166, 158)

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

local function segDist(p, a, b)
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local l2 = ab:Dot(ab)
	local t = l2 > 0 and math.clamp(ap:Dot(ab) / l2, 0, 1) or 0
	return (ap - ab * t).Magnitude
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
	-- road list in left-to-right order across the bundle
	local tl = spec.TightLane
	local roads = {
		{ key = "West", zw = L.WestSt.w, cw = CW.Street, fromX = L.WestSt.x, toX = L.WestSt.x, off = L.Bundle.West },
		{ key = "Market", zw = L.Market.w, cw = CW.Market, fromX = 0, toX = 0, off = L.Bundle.Market },
		{ key = "East", zw = L.EastSt.w, cw = CW.Street, fromX = L.EastSt.x, toX = L.EastSt.x, off = L.Bundle.East },
		{ key = "Lane", zw = tl.w, cw = tl.w, fromX = ctx.laneFromX, toX = ctx.laneToX, off = tl.bundle, tight = true, clear = tl.clear },
	}
	table.sort(roads, function(a, c)
		return a.off < c.off
	end)
	-- same sample counts for every road
	local mStart = ffr * Vector3.new(0, 0, fromZone.result.exitEdge)
	local mEnd = tfr * Vector3.new(0, 0, toZone.result.entryEdge)
	local bm0 = b.origin
	local bm1 = b.origin + dir * b.length
	local n1 = math.max(6, math.ceil((bm0 - mStart).Magnitude * 1.3 / STEP))
	local n3 = math.max(6, math.ceil((mEnd - bm1).Magnitude * 1.3 / STEP))
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
		-- kerb-to-building setback: pavement for streets, none for the walled lane
		r.front = r.tight and 1.2 or SW
		r.edge = r.tight and 1.2 or 0
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
	local function onRoad(p)
		for _, r in roads do
			for i = 1, count - 1 do
				local lim = (r.ws[i] + r.ws[i + 1]) / 4 + r.front - 0.3
				if segDist(p, r.pts[i], r.pts[i + 1]) < lim then
					return true
				end
			end
		end
		return false
	end

	------------------------------------------------------------ roads (exact strips)
	local asphalt = { Material = Enum.Material.Asphalt, Color = Style.Asphalt }
	local depthRoad = -L.LandBottom
	for _, r in roads do
		for i = 1, count - 1 do
			local bridge = r.inGap[i] and spec.Crossing == "Bridge"
			local la, ra = edge(r, i, -1), edge(r, i, 1)
			local lb, rb = edge(r, i + 1, -1), edge(r, i + 1, 1)
			if r.tight then
				-- the road surface stops at the wall faces' inner line
				la, ra = r.pts[i] - r.right[i] * r.ws[i] / 2, r.pts[i] + r.right[i] * r.ws[i] / 2
				lb, rb = r.pts[i + 1] - r.right[i + 1] * r.ws[i + 1] / 2, r.pts[i + 1] + r.right[i + 1] * r.ws[i + 1] / 2
			end
			U.quad(roadsF, r.tight and "Lane" or "Road", la, ra, rb, lb, bridge and 3 or depthRoad, asphalt)
		end
		-- walls / parapets, as continuous runs
		local runs = {}
		local cur = nil
		for i = 1, count - 1 do
			local kind = (r.inGap[i] and spec.Crossing == "Bridge") and "bridge" or (r.tight and "lane" or nil)
			if kind then
				if not cur or cur.kind ~= kind then
					cur = { kind = kind, from = i, to = i + 1 }
					table.insert(runs, cur)
				else
					cur.to = i + 1
				end
			else
				cur = nil
			end
		end
		for _, run in runs do
			for _, side in { -1, 1 } do
				local pts = {}
				for i = run.from, run.to do
					local half = r.ws[i] / 2
					table.insert(pts, r.pts[i] + r.right[i] * side * (half + 0.6))
				end
				if run.kind == "bridge" then
					U.wallRun(roadsF, "BridgeParapet", pts, 1.2, 3.6, { Material = Enum.Material.Brick, Color = BRICK })
				else
					U.wallRun(roadsF, "LaneWall", pts, 1.2, 3.2, { Material = Enum.Material.Concrete, Color = Color3.fromRGB(150, 146, 138) })
				end
			end
		end
		-- a pier under each road bridge
		if spec.Crossing == "Bridge" then
			local c = r.b0 + dir * ((gap.from + gap.to) / 2)
			U.part(roadsF, "BridgePier", Vector3.new(r.w * 0.6, 12, 8), CFrame.lookAt(c + Vector3.new(0, -9, 0), c + Vector3.new(0, -9, 0) + dir), { Material = Enum.Material.Brick, Color = BRICK })
		end
		-- centre line (two-way roads only)
		if not r.tight then
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
	end

	------------------------------------------------------------ pavements (exact) between and outside the roads
	local paving = { Material = Enum.Material.Concrete, Color = Style.Sidewalk }
	local depthPave = 0.5 - L.LandBottom
	local function paveStrip(la, ra, lb, rb)
		-- on a tight bend the far edge of a wide strip can fold back on itself
		-- (a "bow-tie"); its neighbours already cover that spot, so skip it
		local function flat(v)
			return Vector3.new(v.X, 0, v.Z)
		end
		if flat(lb - la):Dot(flat(rb - ra)) <= 0 or flat(ra - la):Dot(flat(rb - lb)) <= 0 then
			return
		end
		U.quad(ground, "Pavement", la + Vector3.new(0, 0.5, 0), ra + Vector3.new(0, 0.5, 0), rb + Vector3.new(0, 0.5, 0), lb + Vector3.new(0, 0.5, 0), depthPave, paving)
	end
	local function outerEdge(r, i, side)
		return edge(r, i, side) + r.right[i] * side * OUTER
	end
	for i = 1, count - 1 do
		if roads[1].inGap[i] then
			continue
		end
		for k = 1, #roads - 1 do
			local rl, rr = roads[k], roads[k + 1]
			paveStrip(edge(rl, i, 1), edge(rr, i, -1), edge(rl, i + 1, 1), edge(rr, i + 1, -1))
		end
		local r1, rn = roads[1], roads[#roads]
		paveStrip(outerEdge(r1, i, -1), edge(r1, i, -1), outerEdge(r1, i + 1, -1), edge(r1, i + 1, -1))
		paveStrip(edge(rn, i, 1), outerEdge(rn, i, 1), edge(rn, i + 1, 1), outerEdge(rn, i + 1, 1))
	end
	-- a low quay wall along the outer edges, above the water
	for _, side in { -1, 1 } do
		local r = side < 0 and roads[1] or roads[#roads]
		local run = {}
		local function flush()
			if #run > 1 then
				U.wallRun(ground, "EdgeWall", run, 1.2, 4.5, { Material = Enum.Material.Brick, Color = BRICK })
			end
			run = {}
		end
		for i = 1, count do
			local gapHere = i < count and r.inGap[i]
			local p = outerEdge(r, i, side) - r.right[i] * side * 0.6 + Vector3.new(0, 0.5, 0)
			if inZone(p) then
				flush()
				continue
			end
			table.insert(run, p)
			if gapHere then
				flush()
			end
		end
		flush()
	end

	------------------------------------------------------------ buildings along every road side
	local zoneStyle = Style.Zones[toZone.spec.Style]
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
	for k, r in roads do
		for _, side in { -1, 1 } do
			local nb = roads[k + side]
			-- depth available at sample i
			local function room(i)
				if nb then
					local g = (edge(nb, i, -side) - edge(r, i, side)).Magnitude
					return math.min(DMAX, g / 2 - r.front - 0.5)
				end
				return OUTER - r.front - 1.5
			end
			local function front(i)
				return edge(r, i, side) + r.right[i] * side * r.front
			end
			local i = 1
			while i < count do
				local m = U.chance(0.5) and 2 or 1
				local j = math.min(count, i + m)
				local skip = false
				for q = i, j - 1 do
					if r.inGap[q] then
						skip = true
					end
				end
				if not skip then
					local fa, fb = front(i), front(j)
					local chord = Vector3.new(fb.X - fa.X, 0, fb.Z - fa.Z)
					local len = chord.Magnitude
					if len > 4 then
						local n = rightOf(chord.Unit) * side
						-- keep the facade behind every sample's building line
						local shift = 0
						local depth = DMAX
						for q = i, j do
							shift = math.max(shift, (front(q) - fa):Dot(n))
							depth = math.min(depth, room(q))
						end
						depth -= shift
						local tries = 0
						while depth >= 6 and tries < 3 do
							local c0 = fa + n * shift
							local corners = { c0, c0 + chord, c0 + n * depth, c0 + chord + n * depth, c0 + chord / 2 + n * depth / 2 }
							local bad = false
							for _, p in corners do
								if inZone(p) or onRoad(p) then
									bad = true
									break
								end
							end
							if not bad then
								local h = height()
								local centre = c0 + chord / 2 + n * depth / 2
								local cf = CFrame.lookAt(centre, centre + chord) + Vector3.new(0, h / 2, 0)
								local metal = zoneStyle.metalChance and U.chance(zoneStyle.metalChance)
								local p = U.part(blds, "Building", Vector3.new(depth, h, len), cf, {
									Material = metal and Enum.Material.CorrodedMetal or Enum.Material.Concrete,
									Color = U.pick(zoneStyle.colors),
								})
								local t = U.pick(zoneStyle.textures)
								for _, face in { Enum.NormalId.Left, Enum.NormalId.Right, Enum.NormalId.Front, Enum.NormalId.Back } do
									local tx = Instance.new("Texture")
									tx.Texture = t.id
									tx.StudsPerTileU = t.u
									tx.StudsPerTileV = t.v
									tx.Color3 = t.color
									tx.Face = face
									tx.Parent = p
								end
								break
							end
							depth /= 2
							tries += 1
						end
					end
				end
				-- a street lamp now and then on the kerb
				if lamp and not r.tight and not r.inGap[i] and i % 6 == 2 then
					local lp = edge(r, i, side) + r.right[i] * side * 1.2
					if not inZone(lp) then
						U.place(lamp, deco, lp.X, 0.5, lp.Z, -r.right[i] * side)
					end
				end
				i = j
			end
		end
	end

	-- railings along the quay edges of the water gap
	if spec.Crossing == "Bridge" then
		for _, s in { gap.from, gap.to } do
			local cuts = {}
			for _, r in roads do
				table.insert(cuts, { a = r.off - r.w / 2 - 2, b = r.off + r.w / 2 + 2 })
			end
			local x = roads[1].off - roads[1].w / 2 - OUTER
			local xEnd = roads[#roads].off + roads[#roads].w / 2 + OUTER
			table.sort(cuts, function(a, c)
				return a.a < c.a
			end)
			local metal = { Material = Enum.Material.Metal, Color = METAL }
			for _, c in cuts do
				if c.a > x + 1 then
					U.segment(ground, "Railing", b.origin + dir * s + right * x, b.origin + dir * s + right * c.a, 0.6, 0.5, 4.4, metal, 0)
				end
				x = c.b
			end
			if xEnd > x + 1 then
				U.segment(ground, "Railing", b.origin + dir * s + right * x, b.origin + dir * s + right * xEnd, 0.6, 0.5, 4.4, metal, 0)
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
			table.insert(openings, { a = r.off - r.w / 2 - r.edge, b = r.off + r.w / 2 + r.edge, clear = r.tight and r.clear or 20, tight = r.tight })
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
			if o.tight then
				-- height bars before each portal
				for _, sb in { gap.from - 5, gap.to + 5 } do
					bbox("HeightBar", o.a - 2, o.b + 2, sb - 0.4, sb + 0.4, o.clear, o.clear + 0.8, { Material = Enum.Material.SmoothPlastic, Color = YELLOW })
					for _, px in { o.a - 1.5, o.b + 1.5 } do
						bbox("HeightBarPost", px - 0.5, px + 0.5, sb - 0.5, sb + 0.5, 0, o.clear + 0.6, { Material = Enum.Material.Metal, Color = YELLOW })
					end
					local sign = bbox("HeightSign", o.a - 2, o.b + 2, sb - 0.15, sb + 0.15, o.clear + 1, o.clear + 3, { Material = Enum.Material.SmoothPlastic, Color = YELLOW, CanCollide = false })
					for _, fc in { Enum.NormalId.Front, Enum.NormalId.Back } do
						U.label(sign, fc, "MAX HEIGHT " .. o.clear, { PixelsPerStud = 20, TextColor3 = Color3.new(0, 0, 0) })
					end
				end
			end
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
		U.quad(linkF, "Deck", linkEdge(i, -1), linkEdge(i, 1), linkEdge(i + 1, 1), linkEdge(i + 1, -1), EX.deckThick, concrete)
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
	for i = 2, count - 1, 4 do
		for _, side in { -1, 1 } do
			local p = linkEdge(i, side, 1.2) + Vector3.new(0, 9, 0)
			U.part(linkF, "DeckLight", Vector3.new(0.4, 0.4, 5), CFrame.lookAt(p, p + (link[i + 1] - link[i])), {
				Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 230, 180), CanCollide = false, CanQuery = false,
			})
		end
	end
	-- supports: portal frames straddling Market, columns on the pavements
	-- (in the water on the canal, on the embankment over the railway)
	for i = 3, count - 2, 3 do
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

	return f
end

return Connector

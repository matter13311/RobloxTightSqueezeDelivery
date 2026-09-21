-- One zone of the city, built in its LOCAL frame (see Layout's header) into
-- a Model that Main then pivots into the world. Returns the local-space data
-- the traffic generator and the connectors need.

local U = require(script.Parent.Util)
local L = require(script.Parent.Layout)
local Style = require(script.Parent.Style)
local Props = require(script.Parent.Props)
local Alleys = require(script.Parent.Alleys)
local Dock = require(script.Parent.Dock)
local Landmarks = require(script.Parent.Landmarks)

local Zone = {}

local SW = L.SidewalkWidth
local SIDEWALK_TOP = 0.5
local WHITE = Color3.fromRGB(215, 215, 208)
local YELLOW = Color3.fromRGB(230, 185, 40)
local METAL = Color3.fromRGB(70, 72, 78)

local function lineZ(parent, x, z1, z2, width, color)
	U.box(parent, "Line", U.rect(x - width / 2, z1, x + width / 2, z2), 0.005, 0.055, {
		Material = Enum.Material.SmoothPlastic, Color = color, CanCollide = false, CanQuery = false, CastShadow = false,
	})
end
local function lineX(parent, z, x1, x2, width, color)
	U.box(parent, "Line", U.rect(x1, z - width / 2, x2, z + width / 2), 0.005, 0.055, {
		Material = Enum.Material.SmoothPlastic, Color = color, CanCollide = false, CanQuery = false, CastShadow = false,
	})
end

-- Dashed line along z from z1 to z2, skipping any rect in `skip`.
local function dashedZ(parent, x, z1, z2, skip, color)
	local z = z1
	while z < z2 do
		local e = math.min(z + 10, z2)
		local ok = true
		for _, r in skip do
			if x > r.x1 - 1 and x < r.x2 + 1 and e > r.z1 and z < r.z2 then
				ok = false
				break
			end
		end
		if ok then
			lineZ(parent, x, z, e, 0.45, color or WHITE)
		end
		z += 20
	end
end

--=============================================================================
-- Buildings
--=============================================================================

local function addTexture(part, face, t)
	local x = Instance.new("Texture")
	x.Texture = t.id
	x.StudsPerTileU = t.u
	x.StudsPerTileV = t.v
	x.Color3 = t.color
	x.Face = face
	x.Parent = part
end

-- Every building's footprint + height, for this zone build: wall props
-- (balconies, fire escapes, lantern strings...) are only hung where a real
-- wall of the right height stands behind them.
local walls = {}
-- Rects (local x/z) where nothing may stick out of a facade above street
-- height: under the express link.
local overheadClear = {}

local function faceClear(x1, z1, x2, z2)
	local r = U.rect(x1, z1, x2, z2)
	for _, c in overheadClear do
		if U.overlaps(r, c) then
			return false
		end
	end
	return true
end

local CORRUGATED = { id = "rbxassetid://1396501591", u = 16, v = 16, color = Color3.fromRGB(230, 230, 230) }

local function roofExtras(parent, r, height, style, styleKey)
	local cx, cz = U.center(r)
	local w, d = U.width(r), U.depth(r)
	if style.sawtoothChance > 0 and U.chance(style.sawtoothChance) and math.min(w, d) > 16 then
		-- sawtooth factory roof: a row of wedges
		local alongX = w > d
		local n = math.max(2, math.floor((alongX and w or d) / 12))
		for i = 0, n - 1 do
			local t = (i + 0.5) / n - 0.5
			local c
			if alongX then
				c = Vector3.new(cx + t * w, height + 3, cz)
				U.ramp(parent, "Sawtooth", c - Vector3.new((w / n) / 2, 3, 0), c + Vector3.new((w / n) / 2, 3, 0), d - 1, {
					Material = Enum.Material.CorrodedMetal, Color = Color3.fromRGB(110, 100, 90), CanCollide = false,
				})
			else
				c = Vector3.new(cx, height + 3, cz + t * d)
				U.ramp(parent, "Sawtooth", c - Vector3.new(0, 3, (d / n) / 2), c + Vector3.new(0, 3, (d / n) / 2), w - 1, {
					Material = Enum.Material.CorrodedMetal, Color = Color3.fromRGB(110, 100, 90), CanCollide = false,
				})
			end
		end
	elseif style.gableChance > 0 and U.chance(style.gableChance) and math.min(w, d) > 12 then
		local alongX = w > d
		local span = alongX and d or w
		local rise = math.min(10, span * 0.3)
		local col = U.pick({ Color3.fromRGB(150, 60, 45), Color3.fromRGB(70, 90, 110), Color3.fromRGB(90, 96, 100) })
		for _, s in { -1, 1 } do
			if alongX then
				local low = Vector3.new(cx, height, cz + s * span / 2)
				local high = Vector3.new(cx, height + rise, cz)
				U.ramp(parent, "Gable", low, high, w, { Material = Enum.Material.CorrodedMetal, Color = col, CanCollide = false })
			else
				local low = Vector3.new(cx + s * span / 2, height, cz)
				local high = Vector3.new(cx, height + rise, cz)
				U.ramp(parent, "Gable", low, high, d, { Material = Enum.Material.CorrodedMetal, Color = col, CanCollide = false })
			end
		end
	elseif style.waterTankChance > 0 and U.chance(style.waterTankChance) and math.min(w, d) > 14 then
		local tx, tz = cx + U.range(-w / 5, w / 5), cz + U.range(-d / 5, d / 5)
		for _, o in { { -2.5, -2.5 }, { 2.5, -2.5 }, { -2.5, 2.5 }, { 2.5, 2.5 } } do
			U.part(parent, "TankLeg", Vector3.new(0.6, 6, 0.6), CFrame.new(tx + o[1], height + 3, tz + o[2]), { Material = Enum.Material.Metal, Color = METAL, CanCollide = false })
		end
		U.part(parent, "WaterTank", Vector3.new(9, 8, 8), CFrame.new(tx, height + 10, tz) * CFrame.Angles(0, 0, math.rad(90)), {
			Shape = Enum.PartType.Cylinder, Material = Enum.Material.WoodPlanks, Color = Color3.fromRGB(120, 86, 60), CanCollide = false,
		})
		U.part(parent, "TankRoof", Vector3.new(6.4, 2.6, 6.4), CFrame.new(tx, height + 15.3, tz), {
			Material = Enum.Material.Metal, Color = Color3.fromRGB(60, 60, 64), CanCollide = false,
		})
	elseif U.chance(0.3) and w > 14 and d > 14 then
		U.part(parent, "RoofUnit", Vector3.new(U.range(5, 9), U.range(3, 5), U.range(5, 9)),
			CFrame.new(cx + U.range(-3, 3), height + 2, cz + U.range(-3, 3)), {
				Material = Enum.Material.Metal, Color = Color3.fromRGB(150, 152, 155), CanCollide = false,
			})
	end
	if styleKey == "Mill" and U.chance(0.15) then
		U.part(parent, "Chimney", Vector3.new(24, 5, 5), CFrame.new(cx, height + 12, cz) * CFrame.Angles(0, 0, math.rad(90)), {
			Shape = Enum.PartType.Cylinder, Material = Enum.Material.Brick, Color = Color3.fromRGB(110, 60, 45), CanCollide = false,
		})
	end
end

local function makeBuilding(parent, r, styleKey, height, fronts)
	local style = Style.Zones[styleKey]
	local metal = style.metalChance and U.chance(style.metalChance)
	local color = metal and U.pick({ Color3.fromRGB(140, 146, 150), Color3.fromRGB(90, 110, 120), Color3.fromRGB(150, 100, 70), Color3.fromRGB(100, 120, 90) }) or U.pick(style.colors)
	local p = U.box(parent, "Building", r, 0, height, {
		Material = metal and Enum.Material.CorrodedMetal or Enum.Material.Concrete,
		Color = color,
	})
	table.insert(walls, { rect = r, h = height })
	local t = metal and CORRUGATED or U.pick(style.textures)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right } do
		addTexture(p, face, t)
	end
	local cx, cz = U.center(r)
	for _, f in fronts do
		local n = f.normal
		local len = (math.abs(n.X) > 0.5) and U.depth(r) or U.width(r)
		if len <= 10 then
			continue
		end
		local faceCentre = Vector3.new(cx + n.X * U.width(r) / 2, 0, cz + n.Z * U.depth(r) / 2)
		local wallCF = CFrame.lookAt(faceCentre, faceCentre + n)
		if U.chance(style.shopfrontChance) then
			local size = (math.abs(n.X) > 0.5) and Vector3.new(0.4, 9, len - 4) or Vector3.new(len - 4, 9, 0.4)
			U.part(p, "Shopfront", size, CFrame.new(faceCentre + n * 0.2 + Vector3.new(0, SIDEWALK_TOP + 4.5, 0)), {
				Material = Enum.Material.Glass, Color = Color3.fromRGB(30, 36, 44), Reflectance = 0.15, CanCollide = false, CastShadow = false,
			})
			if U.chance(style.awningChance) then
				local asize = (math.abs(n.X) > 0.5) and Vector3.new(4, 0.4, len - 6) or Vector3.new(len - 6, 0.4, 4)
				U.part(p, "Awning", asize, CFrame.new(faceCentre + n * 2 + Vector3.new(0, SIDEWALK_TOP + 10, 0)), {
					Material = Enum.Material.Fabric, Color = U.pick(Style.Awnings), CanCollide = false,
				})
			end
		end
		-- the strip just in front of this facade
		local fx1, fz1 = faceCentre.X + math.min(0, n.X * 5), faceCentre.Z + math.min(0, n.Z * 5)
		local fx2, fz2 = faceCentre.X + math.max(0, n.X * 5), faceCentre.Z + math.max(0, n.Z * 5)
		local halfLen = len / 2
		if math.abs(n.X) > 0.5 then
			fz1, fz2 = cz - halfLen, cz + halfLen
		else
			fx1, fx2 = cx - halfLen, cx + halfLen
		end
		local highOk = faceClear(fx1, fz1, fx2, fz2)
		if U.chance(style.neonChance) and height > 18 then
			Props.Neon(p, wallCF, Style.NeonWords[styleKey])
		end
		if highOk and style.balconyChance > 0 and U.chance(style.balconyChance) and height > 26 then
			local off = U.range(-len / 4, len / 4)
			Props.Balcony(p, wallCF * CFrame.new(off, 0, 0), height)
		end
		if style.pipeChance > 0 and U.chance(style.pipeChance) then
			Props.DrainPipe(p, wallCF * CFrame.new(U.range(-len / 3, len / 3), 0, 0), height)
		end
		if U.chance(0.12) then
			Props.Graffiti(p, wallCF * CFrame.new(U.range(-len / 4, len / 4), 0, 0), U.range(4, 6))
		end
	end
	roofExtras(p, r, height, style, styleKey)
	return p
end

local function containerLot(parent, r)
	local x = r.x1 + 2
	while x + 20 < r.x2 do
		local z = r.z1 + 2
		while z + 8 < r.z2 do
			if U.chance(0.8) then
				for level = 1, U.int(1, 3) do
					U.part(parent, "Container", Vector3.new(20, 8.5, 8), CFrame.new(x + 10, (level - 0.5) * 8.5, z + 4), {
						Material = Enum.Material.CorrodedMetal, Color = U.pick(Style.ContainerColors),
					})
				end
			end
			z += 9
		end
		x += 21
	end
end

local function fillLot(parent, r, styleKey, frontEdges, heightBias)
	local w, d = U.width(r), U.depth(r)
	if math.min(w, d) < 6 then
		return
	end
	local style = Style.Zones[styleKey]
	if style.containerLotChance and U.chance(style.containerLotChance) and w > 24 and d > 24 then
		containerLot(parent, r)
		return
	end
	local alongX = w > d
	local long = alongX and w or d
	local pieces = {}
	local pos = 0
	while pos < long - 0.01 do
		local len = U.range(style.minLen, style.maxLen)
		if long - pos - len < style.minLen then
			len = long - pos
		end
		table.insert(pieces, { pos, pos + len })
		pos += len
	end
	for _, piece in pieces do
		local br
		if alongX then
			br = U.rect(r.x1 + piece[1], r.z1, r.x1 + piece[2], r.z2)
		else
			br = U.rect(r.x1, r.z1 + piece[1], r.x2, r.z1 + piece[2])
		end
		local sub = { br }
		local shortSize = alongX and U.depth(br) or U.width(br)
		if shortSize > 70 then
			local t = U.range(0.42, 0.58)
			if alongX then
				local zc = br.z1 + U.depth(br) * t
				sub = { U.rect(br.x1, br.z1, br.x2, zc), U.rect(br.x1, zc, br.x2, br.z2) }
			else
				local xc = br.x1 + U.width(br) * t
				sub = { U.rect(br.x1, br.z1, xc, br.z2), U.rect(xc, br.z1, br.x2, br.z2) }
			end
		end
		for _, b in sub do
			local fronts = {}
			for _, e in frontEdges do
				if e.face == "W" and math.abs(b.x1 - e.at) < 0.1 then
					table.insert(fronts, { normal = Vector3.new(-1, 0, 0) })
				elseif e.face == "E" and math.abs(b.x2 - e.at) < 0.1 then
					table.insert(fronts, { normal = Vector3.new(1, 0, 0) })
				elseif e.face == "N" and math.abs(b.z1 - e.at) < 0.1 then
					table.insert(fronts, { normal = Vector3.new(0, 0, -1) })
				elseif e.face == "S" and math.abs(b.z2 - e.at) < 0.1 then
					table.insert(fronts, { normal = Vector3.new(0, 0, 1) })
				end
			end
			local h = U.range(style.minH, style.maxH) + (heightBias or 0)
			makeBuilding(parent, b, styleKey, math.floor(h), fronts)
		end
	end
end

--=============================================================================
-- Signs
--=============================================================================

-- A pole on a junction corner with two blades that hang out over the ROAD
-- side of the corner (never back into the buildings behind it).
-- `sx`/`sz` = which way the corner's roads lie from the pole (+1/-1).
local function streetSign(folder, x, z, ewName, nsName, sx, sz)
	local bg = Color3.fromRGB(28, 90, 56)
	local pole = U.part(folder, "SignPole", Vector3.new(13, 0.6, 0.6), CFrame.new(x, SIDEWALK_TOP + 6.5, z) * CFrame.Angles(0, 0, math.rad(90)), {
		Material = Enum.Material.Metal, Color = METAL, Shape = Enum.PartType.Cylinder,
	})
	local _ = pole
	-- E-W street name: blade along X, sticking out toward the N-S road
	local b1 = U.part(folder, "StreetBlade", Vector3.new(9, 1.6, 0.2), CFrame.new(x + sx * 4.8, SIDEWALK_TOP + 12, z), {
		Material = Enum.Material.SmoothPlastic, Color = bg, CanCollide = false,
	})
	U.label(b1, Enum.NormalId.Front, ewName, { PixelsPerStud = 40 })
	U.label(b1, Enum.NormalId.Back, ewName, { PixelsPerStud = 40 })
	-- N-S street name: blade along Z, sticking out toward the cross road
	local b2 = U.part(folder, "StreetBlade", Vector3.new(0.2, 1.6, 9), CFrame.new(x, SIDEWALK_TOP + 10.2, z + sz * 4.8), {
		Material = Enum.Material.SmoothPlastic, Color = bg, CanCollide = false,
	})
	U.label(b2, Enum.NormalId.Left, nsName, { PixelsPerStud = 40 })
	U.label(b2, Enum.NormalId.Right, nsName, { PixelsPerStud = 40 })
end

local function alleySign(folder, x, z, name, alongZ, width)
	U.part(folder, "AlleySignPost", Vector3.new(0.4, 9, 0.4), CFrame.new(x, 4.5, z), { Material = Enum.Material.Metal, Color = Color3.fromRGB(60, 60, 64) })
	local size = alongZ and Vector3.new(0.2, 2.2, 8) or Vector3.new(8, 2.2, 0.2)
	local plate = U.part(folder, "AlleySign", size, CFrame.new(x, 8.2, z), {
		Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(120, 72, 30), CanCollide = false,
	})
	local text = name .. (width <= 12 and "  (TIGHT)" or "")
	local faces = alongZ and { Enum.NormalId.Left, Enum.NormalId.Right } or { Enum.NormalId.Front, Enum.NormalId.Back }
	for _, f in faces do
		U.label(plate, f, text, { PixelsPerStud = 40, TextColor3 = Color3.fromRGB(255, 230, 150) })
	end
end

local function textSign(parent, name, size, cf, text, faces, bg, fg)
	local p = U.part(parent, name, size, cf, { Material = Enum.Material.SmoothPlastic, Color = bg or Color3.fromRGB(20, 60, 120), CanCollide = false })
	for _, f in faces do
		U.label(p, f, text, { PixelsPerStud = 20, TextColor3 = fg })
	end
	return p
end

--=============================================================================
-- Alleys: legs from a path
--=============================================================================

local function legsFor(spec, seg)
	local nodes = {}
	for i, n in spec.Path do
		local z = n.z
		if i == 1 then
			z = seg.z2
		elseif i == #spec.Path then
			z = seg.z1
		end
		table.insert(nodes, { x = n.x, z = z })
	end
	local legs = {}
	local w = spec.w
	for i = 1, #nodes - 1 do
		local a, b = nodes[i], nodes[i + 1] -- a is south of (or level with) b
		if a.x == b.x then
			table.insert(legs, { kind = "NS", rect = U.rect(a.x - w / 2, b.z, a.x + w / 2, a.z), x = a.x, z1 = b.z, z2 = a.z })
		elseif a.z == b.z then
			table.insert(legs, { kind = "EW", rect = U.rect(math.min(a.x, b.x) - w / 2, a.z - w / 2, math.max(a.x, b.x) + w / 2, a.z + w / 2) })
		else
			-- angled: the channel keeps its PERPENDICULAR width w, so its
			-- horizontal width is w / cos(angle)
			local dx, dz = b.x - a.x, a.z - b.z
			local wh = w * math.sqrt(dx * dx + dz * dz) / dz
			table.insert(legs, {
				kind = "DIAG",
				rect = U.rect(math.min(a.x, b.x) - wh / 2, b.z, math.max(a.x, b.x) + wh / 2, a.z),
				a = Vector3.new(a.x, 0, a.z), b = Vector3.new(b.x, 0, b.z), wh = wh,
			})
		end
	end
	return legs, nodes
end

local function spineXAt(legs, z)
	for _, leg in legs do
		if leg.kind == "NS" and z >= leg.z1 - 0.01 and z <= leg.z2 + 0.01 then
			return leg.x
		end
	end
	error("branch at z=" .. z .. " does not sit on a straight part of its alley")
end

--=============================================================================
-- Main
--=============================================================================

function Zone.Build(spec, kit, ctx)
	local model = Instance.new("Model")
	model.Name = spec.Key
	local f = {
		Ground = U.folder(model, "Ground"),
		Sidewalks = U.folder(model, "Sidewalks"),
		Markings = U.folder(model, "Markings"),
		Buildings = U.folder(model, "Buildings"),
		Alleys = U.folder(model, "AlleyDressing"),
		Furniture = U.folder(model, "StreetFurniture"),
		Signs = U.folder(model, "Signs"),
		Express = U.folder(model, "Express"),
		Traffic = U.folder(model, "Traffic"),
		Landmarks = U.folder(model, "Landmarks"),
		Edges = U.folder(model, "Edges"),
		Dest = U.folder(model, "Destinations"),
	}
	local styleKey = spec.Style
	local style = Style.Zones[styleKey]
	local out = {
		model = model,
		junctions = {},
		mouths = {},
		marketStretches = {},
		roadworks = {},
		spineEnds = {},
		gates = {},
	}

	local entryEdge = spec.Entry + (spec.Id == 1 and 0 or 6)
	local exitEdge = spec.QuayFrom and spec.Exit or (spec.Exit - 6)
	local roads = {} -- cross road rects
	for _, cr in spec.CrossRoads do
		table.insert(roads, { spec = cr, rect = U.rect(L.WestSt.x1, cr.zc - cr.w / 2, L.EastSt.x2, cr.zc + cr.w / 2) })
	end
	local firstRoad, lastRoad = roads[1], roads[#roads]
	local marketZ1 = lastRoad.rect.z2 -- Market runs between the first and last cross roads
	local marketZ2 = firstRoad.rect.z1
	local rampS, rampN = spec.Ramps.South, spec.Ramps.North
	local rampLen = L.Express.rampLength
	table.clear(walls)
	table.clear(overheadClear)
	-- the express link's in-zone stretches (see Layout.LinkX): from the zone
	-- edge over Market's west lanes to where it merges with the deck
	local LW = L.Express.width
	local linkX1, linkX2 = L.LinkX - LW / 2, L.LinkX + LW / 2
	local links = {}
	if ctx.linkNorth then
		local deckN = rampN + rampLen
		table.insert(links, { z1 = exitEdge, z2 = deckN + L.LinkMerge, m1 = deckN, m2 = deckN + L.LinkMerge, closedAtZ1 = false })
	end
	if ctx.linkSouth then
		local deckS = rampS - rampLen
		table.insert(links, { z1 = deckS - L.LinkMerge, z2 = entryEdge, m1 = deckS - L.LinkMerge, m2 = deckS, closedAtZ1 = true })
	end
	for _, lk in links do
		table.insert(overheadClear, U.rect(linkX1 - 3, lk.z1, linkX2, lk.z2))
	end

	------------------------------------------------------------ holes/destinations
	local holes = {}
	local dests = {}
	for _, d in spec.Destinations do
		local r = U.rect(d.rect[1], d.rect[2], d.rect[3], d.rect[4])
		local drive
		if d.access == "E" then
			drive = U.rect(r.x1, r.z1, r.x2 + SW + 1, r.z2)
		elseif d.access == "W" then
			drive = U.rect(r.x1 - SW - 1, r.z1, r.x2, r.z2)
		elseif d.access == "S" then
			drive = U.rect(r.x1, r.z1, r.x2, r.z2 + SW + 1)
		else
			drive = U.rect(r.x1, r.z1 - SW - 1, r.x2, r.z2)
		end
		table.insert(dests, { def = d, rect = r, drive = drive })
		table.insert(holes, drive)
	end
	local landmarkRects = {}
	for _, lm in spec.Landmarks or {} do
		local r = Landmarks.Footprint(lm)
		if r and not lm.OnRoof then
			table.insert(landmarkRects, r)
		end
	end

	------------------------------------------------------------ blocks
	local blocks = {}
	for si, seg in spec.Segments do
		for _, side in { "West", "East" } do
			local a = seg[side]
			local bx1, bx2 = if side == "East" then L.Market.x2 else L.WestSt.x2, if side == "East" then L.EastSt.x1 else L.Market.x1
			local legs, nodes = legsFor(a, seg)
			local branches = {}
			for _, b in a.Branches do
				local sx = spineXAt(legs, b.z)
				local toMarket = b.to == "market"
				local xa, xb
				if side == "East" then
					xa, xb = if toMarket then L.Market.x2 else sx + a.w / 2, if toMarket then sx - a.w / 2 else L.EastSt.x1
				else
					xa, xb = if toMarket then sx + a.w / 2 else L.WestSt.x2, if toMarket then L.Market.x1 else sx - a.w / 2
				end
				table.insert(branches, {
					rect = U.rect(xa, b.z - b.w / 2, xb, b.z + b.w / 2), w = b.w, z = b.z, to = b.to,
					name = b.Name or a.Name, theme = b.Theme or a.Theme,
					roadX = if toMarket then (if side == "East" then L.Market.x2 else L.Market.x1) else (if side == "East" then L.EastSt.x1 else L.WestSt.x2),
				})
			end
			local block = {
				side = side, seg = seg, index = si, alley = a, legs = legs, nodes = nodes, branches = branches,
				rect = U.rect(bx1, seg.z1, bx2, seg.z2),
				inner = U.rect(bx1 + SW, seg.z1 + SW, bx2 - SW, seg.z2 - SW),
			}
			table.insert(blocks, block)
			for _, leg in legs do
				table.insert(holes, U.expand(leg.rect, 0, SW + 0.5))
			end
			for _, br in branches do
				table.insert(holes, U.expand(br.rect, SW + 0.5, 0))
				table.insert(out.mouths, { name = br.name, x = br.roadX, z = br.z, w = br.w, road = br.to == "market" and "Market" or side })
			end
			for _, n in { nodes[1], nodes[#nodes] } do
				table.insert(out.mouths, { name = a.Name, x = n.x, z = n.z, w = a.w, road = "cross" })
			end
			out.spineEnds[side .. si] = { south = nodes[1].x, north = nodes[#nodes].x, w = a.w }
		end
	end

	------------------------------------------------------------ potholes
	local potholes = {}
	local templates = kit.Templates:FindFirstChild("Potholes")
	local potCount = ({ OldTown = 22, Mill = 34, Harbour = 44 })[styleKey] or 20
	local function potOk(x, z)
		for _, p in potholes do
			if math.abs(p.X - x) < 16 and math.abs(p.Z - z) < 16 then
				return false
			end
		end
		for _, h in holes do
			-- keep them out of driveways
			if x > h.x1 - 6 and x < h.x2 + 6 and z > h.z1 - 6 and z < h.z2 + 6 and U.width(h) > 40 then
				return false
			end
		end
		if math.abs(x) < 16 then
			return false -- centre strip (ramps / median)
		end
		return true
	end
	if templates then
		local tries = 0
		while #potholes < potCount and tries < potCount * 20 do
			tries += 1
			local roll = U.range(0, 1)
			local x, z
			if roll < 0.5 then
				x = U.pick({ L.MarketLanes.SBOuter, L.MarketLanes.SBInner, L.MarketLanes.NBInner, L.MarketLanes.NBOuter })
				z = U.range(marketZ1 + 10, marketZ2 - 10)
			elseif roll < 0.8 then
				x = U.pick({ L.StreetLanes.WestSB, L.StreetLanes.WestNB, L.StreetLanes.EastSB, L.StreetLanes.EastNB })
				z = U.range(exitEdge + 20, entryEdge - 20)
			else
				local cr = U.pick(spec.CrossRoads)
				z = cr.zc + U.pick({ -6, 6 })
				x = U.range(-260, 260)
			end
			x, z = math.floor(x + 0.5), math.floor(z + 0.5)
			if potOk(x, z) then
				table.insert(potholes, Vector3.new(x, 0, z))
			end
		end
	end
	-- land slab, holed for the potholes
	local land = U.rect(-L.HalfWidth, exitEdge, L.HalfWidth, entryEdge)
	local potRects = {}
	for _, p in potholes do
		table.insert(potRects, U.rect(p.X - 5, p.Z - 5, p.X + 5, p.Z + 5))
	end
	for _, piece in U.subtractAll({ land }, potRects, 0.5) do
		U.box(f.Ground, "Ground", piece, L.LandBottom, 0, { Material = Enum.Material.Asphalt, Color = Style.Asphalt })
	end
	if templates then
		local kinds = templates:GetChildren()
		for _, p in potholes do
			local t = U.pick(kinds)
			local c = t:Clone()
			local cf = CFrame.new(p.X, -2, p.Z) * CFrame.Angles(0, math.rad(90 * U.int(0, 3)), 0)
			if c:IsA("Model") then
				c:PivotTo(cf)
			else
				c.CFrame = cf
				c.Anchored = true
				c.CanTouch = c.CanCollide
			end
			c.Parent = f.Ground
		end
	end

	------------------------------------------------------------ blocks: lots, sidewalks, alleys
	local strips = {}
	for _, b in blocks do
		local bl = b.rect
		local ring = {
			{ U.rect(bl.x1, bl.z1, bl.x1 + SW, bl.z2), Vector3.new(-1, 0, 0) },
			{ U.rect(bl.x2 - SW, bl.z1, bl.x2, bl.z2), Vector3.new(1, 0, 0) },
			{ U.rect(bl.x1 + SW, bl.z1, bl.x2 - SW, bl.z1 + SW), Vector3.new(0, 0, -1) },
			{ U.rect(bl.x1 + SW, bl.z2 - SW, bl.x2 - SW, bl.z2), Vector3.new(0, 0, 1) },
		}
		for _, entry in ring do
			local kind = "street"
			if (entry[2].X < 0 and b.side == "East") or (entry[2].X > 0 and b.side == "West") then
				kind = "market"
			elseif entry[2].X == 0 then
				kind = "cross"
			end
			for _, piece in U.subtractAll({ entry[1] }, holes, 2) do
				U.box(f.Sidewalks, "Sidewalk", piece, 0, SIDEWALK_TOP, { Material = Enum.Material.Concrete, Color = Style.Sidewalk })
				table.insert(strips, { rect = piece, dir = entry[2], kind = kind })
			end
		end
		-- lots
		local lotHoles = {}
		for _, leg in b.legs do
			table.insert(lotHoles, leg.rect)
		end
		for _, br in b.branches do
			table.insert(lotHoles, br.rect)
		end
		for _, d in dests do
			table.insert(lotHoles, d.rect)
		end
		for _, r in landmarkRects do
			table.insert(lotHoles, r)
		end
		local fronts = {
			{ face = "W", at = b.inner.x1 }, { face = "E", at = b.inner.x2 },
			{ face = "N", at = b.inner.z1 }, { face = "S", at = b.inner.z2 },
		}
		for _, lot in U.subtractAll({ b.inner }, lotHoles, 4) do
			local marketSide = (b.side == "East" and lot.x1 < 60) or (b.side == "West" and lot.x2 > -60)
			fillLot(f.Buildings, lot, styleKey, fronts, marketSide and 10 or 0)
		end
		-- angled legs: fill the two corner triangles with building
		for _, leg in b.legs do
			if leg.kind == "DIAG" then
				local a, bb, wh = leg.a, leg.b, leg.wh
				local dz = a.Z - bb.Z
				local dx = bb.X - a.X
				local h = U.range(style.minH, style.maxH)
				local props = { Material = Enum.Material.Concrete, Color = U.pick(style.colors) }
				local function tri(r0, u, v)
					U.triangle(f.Buildings, "Building", r0, u, v, 0, h, props)
					table.insert(walls, { tri = { r0, r0 + u, r0 + v }, h = h })
				end
				if dx > 0 then
					-- channel moves east going north: fill north-west and south-east corners
					tri(Vector3.new(a.X - wh / 2, 0, bb.Z), Vector3.new(dx, 0, 0), Vector3.new(0, 0, dz))
					tri(Vector3.new(bb.X + wh / 2, 0, a.Z), Vector3.new(-dx, 0, 0), Vector3.new(0, 0, -dz))
				else
					tri(Vector3.new(a.X + wh / 2, 0, bb.Z), Vector3.new(dx, 0, 0), Vector3.new(0, 0, dz))
					tri(Vector3.new(bb.X - wh / 2, 0, a.Z), Vector3.new(-dx, 0, 0), Vector3.new(0, 0, -dz))
				end
			end
		end
		-- dressing
		local avoid = {}
		for _, br in b.branches do
			table.insert(avoid, br.rect)
		end
		for _, d in dests do
			table.insert(avoid, U.expand(d.drive, 2))
		end
		for _, leg in b.legs do
			if leg.kind == "EW" or leg.kind == "DIAG" then
				table.insert(avoid, leg.rect)
			end
		end
		local actx = { zoneKey = styleKey, balconies = styleKey == "OldTown", walls = walls, dirt = styleKey == "Harbour" and U.chance(0.4) }
		-- alley paving: exact, non-overlapping pieces (straight legs first,
		-- then dog-legs and branches minus what is already paved, angled legs
		-- as parallelograms that meet the straight legs edge to edge)
		local pave = {
			Material = actx.dirt and Enum.Material.Ground or Enum.Material.Concrete,
			Color = actx.dirt and Style.Dirt or Style.AlleyPaving,
			CanCollide = false, CanQuery = false, CastShadow = false,
		}
		local paved = {}
		local function paveRect(r)
			for _, piece in U.subtractAll({ r }, paved, 0.2) do
				U.box(f.Alleys, "AlleyPaving", piece, 0.001, 0.04, pave)
			end
			table.insert(paved, r)
		end
		for _, leg in b.legs do
			if leg.kind == "NS" then
				paveRect(leg.rect)
			end
		end
		for _, leg in b.legs do
			if leg.kind == "EW" then
				paveRect(leg.rect)
			elseif leg.kind == "DIAG" then
				local a, bb, wh = leg.a, leg.b, leg.wh
				local y = Vector3.new(0, 0.04, 0)
				U.quad(f.Alleys, "AlleyPaving", Vector3.new(a.X - wh / 2, 0, a.Z) + y, Vector3.new(a.X + wh / 2, 0, a.Z) + y,
					Vector3.new(bb.X + wh / 2, 0, bb.Z) + y, Vector3.new(bb.X - wh / 2, 0, bb.Z) + y, 0.039, pave)
			end
		end
		for _, br in b.branches do
			paveRect(br.rect)
		end
		for _, leg in b.legs do
			if leg.kind == "NS" then
				local own = {}
				for _, av in avoid do
					if av ~= leg.rect then
						table.insert(own, av)
					end
				end
				Alleys.DressLeg(f.Alleys, kit, { rect = U.rect(leg.rect.x1, leg.rect.z1 + 3, leg.rect.x2, leg.rect.z2 - 3), alongZ = true, w = b.alley.w, theme = b.alley.Theme }, own, actx)
			elseif leg.kind == "EW" then
				-- a dog-leg's "walls" are where the straight runs join it: keep
				-- those openings clear
				local joins = {}
				for _, other in b.legs do
					if other.kind == "NS" then
						table.insert(joins, other.rect)
					end
				end
				Alleys.DressLeg(f.Alleys, kit, { rect = leg.rect, alongZ = false, w = b.alley.w, theme = b.alley.Theme }, joins, actx)
			else
				Alleys.DressDiagonal(f.Alleys, kit, leg.a, leg.b, b.alley.w, b.alley.Theme, actx)
			end
		end
		for _, br in b.branches do
			local r = br.rect
			local inner = U.rect(r.x1 + 3, r.z1, r.x2 - 3, r.z2)
			Alleys.DressLeg(f.Alleys, kit, { rect = inner, alongZ = false, w = br.w, theme = br.theme }, {}, actx)
		end
		-- alley signs
		local n1, n2 = b.nodes[1], b.nodes[#b.nodes]
		alleySign(f.Signs, n1.x + b.alley.w / 2 + 2.5, b.rect.z2 - 3, b.alley.Name, true, b.alley.w)
		alleySign(f.Signs, n2.x + b.alley.w / 2 + 2.5, b.rect.z1 + 3, b.alley.Name, true, b.alley.w)
		for _, br in b.branches do
			local x = br.roadX + (br.roadX > (br.rect.x1 + br.rect.x2) / 2 and -3 or 3)
			alleySign(f.Signs, x, br.rect.z1 - 2.5, br.name, false, br.w)
		end
	end

	------------------------------------------------------------ edge strips
	for _, sx in { -1, 1 } do
		local lot = U.rect(sx < 0 and -L.HalfWidth or L.EastSt.x2 + SW, exitEdge, sx < 0 and L.WestSt.x1 - SW or L.HalfWidth, entryEdge)
		local walk = U.rect(sx < 0 and L.WestSt.x1 - SW or L.EastSt.x2, exitEdge, sx < 0 and L.WestSt.x1 or L.EastSt.x2 + SW, entryEdge)
		if spec.QuayFrom then
			lot = U.rect(lot.x1, spec.QuayFrom, lot.x2, lot.z2)
			walk = U.rect(walk.x1, spec.QuayFrom, walk.x2, walk.z2)
		end
		if spec.Id == 1 then
			lot = U.rect(lot.x1, lot.z1, lot.x2, 20)
		end
		-- the zone-end promenades own the last 6 studs of pavement
		walk = U.rect(walk.x1, spec.QuayFrom and walk.z1 or walk.z1 + 6, walk.x2, spec.Id ~= 1 and walk.z2 - 6 or walk.z2)
		U.box(f.Sidewalks, "Sidewalk", walk, 0, SIDEWALK_TOP, { Material = Enum.Material.Concrete, Color = Style.Sidewalk })
		table.insert(strips, { rect = walk, dir = Vector3.new(sx < 0 and 1 or -1, 0, 0), kind = "parking" })
		fillLot(f.Buildings, lot, styleKey, { { face = sx < 0 and "E" or "W", at = sx < 0 and lot.x2 or lot.x1 } }, 12)
	end

	------------------------------------------------------------ zone ends: water edges with gaps for the connector roads
	local function edgeRail(z, gaps, promenadeZ1, promenadeZ2)
		local promenade = U.rect(L.WestSt.x1 - SW, promenadeZ1, L.EastSt.x2 + SW, promenadeZ2)
		for _, piece in U.subtractAll({ promenade }, gaps, 1) do
			U.box(f.Edges, "Promenade", piece, 0, SIDEWALK_TOP, { Material = Enum.Material.Concrete, Color = Style.Sidewalk })
		end
		local rail = U.rect(-L.HalfWidth, z - 0.3, L.HalfWidth, z + 0.3)
		for _, piece in U.subtractAll({ rail }, gaps, 1) do
			U.box(f.Edges, "Railing", piece, 0, 3.9, { Material = Enum.Material.Metal, Color = METAL })
		end
	end
	local function gapsFor(laneX, laneW, z1, z2)
		local g = {
			U.rect(L.WestSt.x1, z1, L.WestSt.x2, z2), U.rect(L.Market.x1, z1, L.Market.x2, z2), U.rect(L.EastSt.x1, z1, L.EastSt.x2, z2),
		}
		if laneX then
			table.insert(g, U.rect(laneX - laneW / 2, z1, laneX + laneW / 2, z2))
		end
		return g
	end
	if not spec.QuayFrom then
		local e = ctx.exitLane
		edgeRail(exitEdge + 0.5, gapsFor(e and e.x, e and e.w, exitEdge - 1, exitEdge + 7), exitEdge, exitEdge + 6)
	end
	if spec.Id ~= 1 then
		local e = ctx.entryLane
		edgeRail(entryEdge - 0.5, gapsFor(e and e.x, e and e.w, entryEdge - 7, entryEdge + 1), entryEdge - 6, entryEdge)
	end

	------------------------------------------------------------ streets: markings, dirt
	for _, sx in { -1, 1 } do
		local x1 = sx < 0 and L.WestSt.x1 or L.EastSt.x1
		local x2 = sx < 0 and L.WestSt.x2 or L.EastSt.x2
		local streetZ1 = spec.QuayFrom and lastRoad.rect.z1 or exitEdge
		local dirt = spec.DirtStreets and spec.DirtStreets[sx < 0 and "West" or "East"]
		if dirt then
			U.box(f.Markings, "DirtRoad", U.rect(x1, streetZ1, x2, entryEdge), 0.001, 0.05, {
				Material = Enum.Material.Ground, Color = Style.Dirt, CanCollide = false, CanQuery = false, CastShadow = false,
			})
		else
			for _, seg in spec.Segments do
				for _, dx in { -0.3, 0.3 } do
					lineZ(f.Markings, sx * 289 + dx, seg.z1, seg.z2, 0.25, YELLOW)
				end
				lineZ(f.Markings, sx * 299, seg.z1, seg.z2, 0.4, WHITE)
			end
		end
	end
	for _, rd in roads do
		if rd.spec.Dirt then
			U.box(f.Markings, "DirtRoad", U.rect(L.WestSt.x2, rd.rect.z1, L.EastSt.x1, rd.rect.z2), 0.001, 0.05, {
				Material = Enum.Material.Ground, Color = Style.Dirt, CanCollide = false, CanQuery = false, CastShadow = false,
			})
		else
			for _, dz in { -0.3, 0.3 } do
				lineX(f.Markings, rd.spec.zc + dz, L.WestSt.x2, L.Market.x1, 0.25, YELLOW)
				lineX(f.Markings, rd.spec.zc + dz, L.Market.x2, L.EastSt.x1, 0.25, YELLOW)
			end
		end
		-- crosswalks across Market on both sides of the junction
		for _, zEdge in { rd.rect.z1 - 4, rd.rect.z2 + 4 } do
			if zEdge < entryEdge - 2 and zEdge > exitEdge + 2 then
				local x = L.Market.x1 + 1
				while x < L.Market.x2 - 1 do
					U.box(f.Markings, "Crosswalk", U.rect(x, zEdge - 3, x + 1.4, zEdge + 3), 0.005, 0.055, {
						Material = Enum.Material.SmoothPlastic, Color = WHITE, CanCollide = false, CanQuery = false, CastShadow = false,
					})
					x += 3.2
				end
			end
		end
		for _, ns in { { L.WestSt, "West St" }, { L.Market, "Market Ave" }, { L.EastSt, "East St" } } do
			table.insert(out.junctions, { name = ns[2] .. " x " .. rd.spec.Name, rect = U.rect(ns[1].x1, rd.rect.z1, ns[1].x2, rd.rect.z2) })
			-- Sign on the junction's NORTH-WEST corner (Market) or north-east
			-- (the streets). The traffic lights take Market's north-east and
			-- south-west corners and the zone arch sits further up the
			-- sidewalk, so a sign never shares a corner with either.
			local sz = rd.rect.z1 - 3
			local sx = ns[2] == "Market Ave" and (ns[1].x1 - 3) or (ns[1].x2 + 3)
			if sx > L.HalfWidth - 70 then
				sx = ns[1].x1 - 3
			end
			streetSign(f.Signs, sx, sz, rd.spec.Name, ns[2], sx > ns[1].x2 and -1 or 1, 1)
		end
	end

	------------------------------------------------------------ Market: markings, median, express
	local strip = L.Strip
	local junctionGaps = {}
	for _, rd in roads do
		table.insert(junctionGaps, U.expand(U.rect(L.Market.x1, rd.rect.z1, L.Market.x2, rd.rect.z2), 0, 4))
	end
	local potSkip = {}
	for _, p in potholes do
		table.insert(potSkip, U.rect(p.X - 5, p.Z - 5, p.X + 5, p.Z + 5))
	end
	local dashSkip = table.clone(junctionGaps)
	for _, r in potSkip do
		table.insert(dashSkip, r)
	end
	for _, x in { -26, 26 } do
		dashedZ(f.Markings, x, marketZ1, marketZ2, dashSkip)
	end
	-- the solid yellow lines along the centre strip, broken at junctions
	for _, x in { -strip - 0.3, strip + 0.3 } do
		for _, run in U.subtractAll({ U.rect(x - 0.2, marketZ1, x + 0.2, marketZ2) }, junctionGaps, 1) do
			U.box(f.Markings, "Line", run, 0.005, 0.055, {
				Material = Enum.Material.SmoothPlastic, Color = YELLOW, CanCollide = false, CanQuery = false, CastShadow = false,
			})
		end
	end
	for _, seg in spec.Segments do
		table.insert(out.marketStretches, U.rect(L.Market.x1, seg.z1 + 4, L.Market.x2, seg.z2 - 4))
	end

	-- express deck + ramps
	local EX = L.Express
	local deckS, deckN = rampS - rampLen, rampN + rampLen
	local concrete = { Material = Enum.Material.Concrete, Color = Color3.fromRGB(170, 166, 158) }
	U.ramp(f.Express, "Ramp", Vector3.new(0, 0, rampS), Vector3.new(0, EX.deckTop, deckS), EX.width, concrete)
	U.ramp(f.Express, "Ramp", Vector3.new(0, 0, rampN), Vector3.new(0, EX.deckTop, deckN), EX.width, concrete)
	U.box(f.Express, "Deck", U.rect(-strip, deckN, strip, deckS), EX.deckTop - EX.deckThick, EX.deckTop, concrete)
	-- parapets along deck and ramps
	local mergeGaps = {}
	for _, lk in links do
		table.insert(mergeGaps, U.rect(-strip - 1, lk.m1, -strip + 1, lk.m2))
	end
	for _, sx in { -1, 1 } do
		for _, piece in U.subtractAll({ U.rect(sx * strip - 0.5, deckN, sx * strip + 0.5, deckS) }, mergeGaps, 1) do
			U.box(f.Express, "DeckWall", piece, EX.deckTop, EX.deckTop + 3.2, concrete)
		end
		for _, rp in { { rampS, deckS }, { rampN, deckN } } do
			local lo = Vector3.new(sx * (strip - 0.5), 0, rp[1])
			local hi = Vector3.new(sx * (strip - 0.5), EX.deckTop, rp[2])
			local mid = (lo + hi) / 2 + Vector3.new(0, 1.6, 0)
			local len = (hi - lo).Magnitude
			U.part(f.Express, "RampWall", Vector3.new(1, 3.2, len), CFrame.lookAt(mid, mid + (hi - lo)), concrete)
		end
	end
	-- deck markings
	for _, dx in { -0.3, 0.3 } do
		lineZ(f.Express, dx, deckN, deckS, 0.25, YELLOW)
	end
	for _, l in f.Express:GetChildren() do
		if l.Name == "Line" then
			l.Position += Vector3.new(0, EX.deckTop, 0)
		end
	end
	-- median + pillars under the deck, with gaps at junctions and market alley mouths
	local medianGaps = table.clone(junctionGaps)
	for _, b in blocks do
		for _, br in b.branches do
			if br.to == "market" then
				table.insert(medianGaps, U.rect(-strip - 1, br.rect.z1 - 6, strip + 1, br.rect.z2 + 6))
			end
		end
	end
	for _, run in U.subtractAll({ U.rect(-strip + 1, deckN, strip - 1, deckS) }, medianGaps, 6) do
		U.box(f.Express, "Median", run, 0, 0.8, { Material = Enum.Material.Concrete, Color = Style.Median })
	end
	local z = deckS - 20
	while z > deckN + 10 do
		local ok = true
		for _, g in medianGaps do
			if z > g.z1 - 3 and z < g.z2 + 3 then
				ok = false
				break
			end
		end
		if ok then
			U.part(f.Express, "Pillar", Vector3.new(4, EX.deckTop - EX.deckThick, 4), CFrame.new(0, (EX.deckTop - EX.deckThick) / 2, z), concrete)
			z -= EX.pillarEvery
		else
			z -= 6
		end
	end
	-- lights on the deck walls
	z = deckS - 10
	while z > deckN do
		for _, sx in { -1, 1 } do
			local inMerge = false
			for _, g in mergeGaps do
				if sx < 0 and z > g.z1 - 3 and z < g.z2 + 3 then
					inMerge = true
				end
			end
			if inMerge then
				continue
			end
			U.part(f.Express, "DeckLight", Vector3.new(0.6, 0.4, 4), CFrame.new(sx * (strip - 1), EX.deckTop + 3.4, z), {
				Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 230, 180), CanCollide = false,
			})
		end
		z -= 60
	end
	-- toll gates at both ramp feet (Outward = away from the ramp)
	local function tollGate(zGate, outward, zPay)
		table.insert(out.gates, { name = "TollGate", rect = U.rect(-strip, zGate - 1.5, strip, zGate + 1.5), outward = outward, kind = "Toll" })
		table.insert(out.gates, { name = "TollPayZone", rect = U.rect(-strip, math.min(zGate, zPay), strip, math.max(zGate, zPay)) })
		table.insert(out.gates, { name = "TollBoomPivot", pos = Vector3.new(-strip, 3.5, zGate), armDir = Vector3.new(1, 0, 0), length = strip })
		table.insert(out.gates, { name = "TollBoomPivot", pos = Vector3.new(strip, 3.5, zGate), armDir = Vector3.new(-1, 0, 0), length = strip })
		for _, sx in { -1, 1 } do
			U.part(f.Express, "TollBoomPost", Vector3.new(1.4, 4, 1.4), CFrame.new(sx * (strip + 0.2), 2, zGate), { Material = Enum.Material.Metal, Color = YELLOW })
		end
		local signZ = zGate + outward.Z * 6
		for _, sx in { -1, 1 } do
			U.part(f.Express, "GantryPost", Vector3.new(1.2, 21.7, 1.2), CFrame.new(sx * (strip + 1.5), 10.85, signZ), { Material = Enum.Material.Metal, Color = METAL })
		end
		U.part(f.Express, "GantryBeam", Vector3.new(strip * 2 + 4, 1, 1), CFrame.new(0, 21.5, signZ), { Material = Enum.Material.Metal, Color = METAL })
		textSign(f.Express, "GantrySign", Vector3.new(strip * 2, 4, 0.4), CFrame.new(0, 19, signZ), "EXPRESS  -  TOLL", { Enum.NormalId.Front, Enum.NormalId.Back }, Color3.fromRGB(30, 110, 60))
	end
	tollGate(rampS + 3, Vector3.new(0, 0, 1), rampS + 18)
	tollGate(rampN - 3, Vector3.new(0, 0, -1), rampN - 18)

	-- the express link: deck, high walls, merge onto the main deck, and
	-- cantilever columns on the west Market pavement
	local linkCols = {}
	local WH = L.LinkWallHeight
	local bottom = EX.deckTop - EX.deckThick
	for _, lk in links do
		U.box(f.Express, "LinkDeck", U.rect(linkX1, lk.z1, linkX2, lk.z2), bottom, EX.deckTop, concrete)
		U.box(f.Express, "LinkDeck", U.rect(linkX2, lk.m1, -strip, lk.m2), bottom, EX.deckTop, concrete)
		U.box(f.Express, "LinkWall", U.rect(linkX1, lk.z1, linkX1 + 1, lk.z2), EX.deckTop, EX.deckTop + WH, concrete)
		-- east wall only where the link runs beside the ramp (open at the merge)
		local ez1, ez2 = lk.z1, lk.m1
		if lk.closedAtZ1 then
			ez1, ez2 = lk.m2, lk.z2
		end
		U.box(f.Express, "LinkWall", U.rect(linkX2 - 1, ez1, linkX2, ez2), EX.deckTop, EX.deckTop + WH, concrete)
		-- the closed end, across the link
		local endZ = lk.closedAtZ1 and lk.z1 or lk.z2 - 1
		U.box(f.Express, "LinkWall", U.rect(linkX1 + 1, endZ, linkX2, endZ + 1), EX.deckTop, EX.deckTop + WH, concrete)
		for _, dx in { -0.3, 0.3 } do
			U.box(f.Express, "LinkLine", U.rect(L.LinkX + dx - 0.125, lk.z1, L.LinkX + dx + 0.125, lk.z2), EX.deckTop + 0.005, EX.deckTop + 0.055, {
				Material = Enum.Material.SmoothPlastic, Color = YELLOW, CanCollide = false, CanQuery = false, CastShadow = false,
			})
		end
		local lz = lk.z1 + 10
		while lz < lk.z2 - 10 do
			local ok = true
			for _, h in holes do
				if L.Market.x1 - 3 > h.x1 - 4 and L.Market.x1 - 3 < h.x2 + 4 and lz > h.z1 - 4 and lz < h.z2 + 4 then
					ok = false
				end
			end
			for _, j in out.junctions do
				if lz > j.rect.z1 - 10 and lz < j.rect.z2 + 10 then
					ok = false
				end
			end
			for _, zg in { rampS + 18, rampN - 18, rampS + 3, rampN - 3 } do
				if math.abs(lz - zg) < 8 then
					ok = false
				end
			end
			if ok then
				local cx = L.Market.x1 - 3
				-- the column ends inside the beam (no shared top face)
				U.part(f.Express, "LinkColumn", Vector3.new(2, bottom - 0.8 - SIDEWALK_TOP, 2), CFrame.new(cx, (bottom - 0.8 + SIDEWALK_TOP) / 2, lz), {
					Material = Enum.Material.Metal, Color = Color3.fromRGB(62, 78, 70),
				})
				U.part(f.Express, "LinkBeam", Vector3.new(linkX2 - (cx - 1), 1.6, 2), CFrame.new((linkX2 + cx - 1) / 2, bottom - 0.8, lz), {
					Material = Enum.Material.Metal, Color = Color3.fromRGB(62, 78, 70),
				})
				table.insert(linkCols, U.rect(cx - 1, lz - 1, cx + 1, lz + 1))
				lz += 48
			else
				lz += 6
			end
		end
		for zz = lk.z1 + 30, lk.z2 - 10, 60 do
			for _, x in { linkX1 + 1.2, linkX2 - 1.2 } do
				U.part(f.Express, "DeckLight", Vector3.new(0.4, 0.4, 5), CFrame.new(x, EX.deckTop + 9, zz), {
					Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 230, 180), CanCollide = false, CanQuery = false,
				})
			end
		end
	end

	------------------------------------------------------------ roadworks (inner lanes, barriers along the lane)
	for _, rw in spec.Roadworks or {} do
		local x = L.MarketLanes[rw.lane]
		local x1, x2 = x - 6, x + 6
		local fw = U.folder(f.Traffic, "RoadWorks_" .. math.floor(math.abs(rw.z1)))
		local barrier = kit.Props:FindFirstChild("Barrier3")
		if barrier then
			-- the long barriers run ALONG the lane edges...
			local zz = rw.z1 + 4
			while zz < rw.z2 - 3 do
				for _, bx in { x1 + 1, x2 - 1 } do
					U.place(barrier, fw, bx, 0, zz, Vector3.new(0, 0, -1))
				end
				zz += 7.5
			end
			-- ...and across both ends
			for _, ez in { rw.z1 + 0.8, rw.z2 - 0.8 } do
				for _, bx in { x - 3.6, x + 3.6 } do
					U.place(barrier, fw, bx, 0, ez, Vector3.new(1, 0, 0))
				end
			end
		end
		for _, cz in { rw.z2 + 8, rw.z2 + 16, rw.z2 + 24, rw.z1 - 8 } do
			U.part(fw, "Cone", Vector3.new(1.2, 2.4, 1.2), CFrame.new(x + (cz > rw.z2 and (cz - rw.z2) / 8 * 1.5 - 4 or 0), 1.2, cz), {
				Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(240, 110, 20),
			})
		end
		U.part(fw, "WorkPit", Vector3.new(x2 - x1 - 4, 0.4, rw.z2 - rw.z1 - 6), CFrame.new(x, 0.2, (rw.z1 + rw.z2) / 2), {
			Material = Enum.Material.Ground, Color = Color3.fromRGB(90, 70, 50),
		})
		textSign(fw, "RoadWorkSign", Vector3.new(4, 3, 0.2), CFrame.new(x, 2.2, rw.z2 + 32), "ROAD WORK", { Enum.NormalId.Back }, Color3.fromRGB(240, 150, 20), Color3.new(0, 0, 0))
		table.insert(out.roadworks, U.rect(x1, rw.z1, x2, rw.z2))
	end

	------------------------------------------------------------ furniture
	local furn = kit.Furniture
	local lamp, tree = furn:FindFirstChild("lamp"), furn:FindFirstChild("tree")
	local clearOf = {}
	for _, h in holes do
		table.insert(clearOf, h)
	end
	-- junction corners belong to the street signs and traffic lights
	for _, j in out.junctions do
		table.insert(clearOf, U.expand(j.rect, 9))
	end
	for _, c in linkCols do
		table.insert(clearOf, U.expand(c, 3))
	end
	local function clear(x, z, pad)
		for _, h in clearOf do
			if x > h.x1 - pad and x < h.x2 + pad and z > h.z1 - pad and z < h.z2 + pad then
				return false
			end
		end
		return true
	end
	for _, s in strips do
		local r, dir = s.rect, s.dir
		local alongZ = math.abs(dir.X) > 0.5
		local a1, a2 = alongZ and r.z1 or r.x1, alongZ and r.z2 or r.x2
		if a2 - a1 < 20 then
			continue
		end
		local roadLine = alongZ and (dir.X < 0 and r.x1 + 1 or r.x2 - 1) or (dir.Z < 0 and r.z1 + 1 or r.z2 - 1)
		local buildLine = alongZ and (dir.X < 0 and r.x2 - 1.5 or r.x1 + 1.5) or (dir.Z < 0 and r.z2 - 1.5 or r.z1 + 1.5)
		local function at(a, lineV)
			if alongZ then
				return lineV, a
			end
			return a, lineV
		end
		-- lamps + trees along the kerb
		local a = a1 + 12
		while a < a2 - 8 do
			local x, zz = at(a, roadLine)
			if clear(x, zz, 5) and lamp then
				U.place(lamp, f.Furniture, x, SIDEWALK_TOP, zz, dir)
			end
			local tx, tz = at(a + 22, roadLine + (alongZ and -dir.X or -dir.Z) * 1.6)
			if tree and (s.kind == "market" or styleKey == "OldTown") and a + 22 < a2 - 6 and clear(tx, tz, 5) then
				U.place(tree, f.Furniture, tx, SIDEWALK_TOP, tz, dir)
			end
			a += (s.kind == "market") and 48 or 64
		end
		-- parking meters along parking kerbs
		if s.kind == "parking" and styleKey ~= "Harbour" then
			local meter = furn:FindFirstChild("meter")
			a = a1 + 8
			while meter and a < a2 - 6 do
				local x, zz = at(a, roadLine + (alongZ and -dir.X or -dir.Z) * 0.8)
				if clear(x, zz, 3) then
					U.place(meter, f.Furniture, x, SIDEWALK_TOP, zz, dir)
				end
				a += 24
			end
		end
		-- extras on the building side
		a = a1 + U.range(8, 24)
		while a < a2 - 8 do
			local x, zz = at(a, buildLine)
			if clear(x, zz, 4) and U.chance(0.6) then
				local pool = styleKey == "Harbour" and { "bench", "bin", "hydrant", "bollard" } or (styleKey == "Mill" and { "bin", "hydrant", "bollard", "news" } or { "bench", "bin", "hydrant", "news", "bench" })
				local t = furn:FindFirstChild(U.pick(pool))
				if t then
					U.place(t, f.Furniture, x, SIDEWALK_TOP, zz, -dir)
				end
			end
			a += U.range(22, 40)
		end
	end
	-- bus stops + traffic lights on Market
	local busstop = furn:FindFirstChild("busstop")
	local tl = furn:FindFirstChild("TrafficLight")
	for i, rd in roads do
		if tl then
			-- north-east corner, arm reaching west over the northbound lanes;
			-- south-west corner, arm reaching east over the southbound lanes
			local ne = rd.rect.z1 - 2
			local sw = rd.rect.z2 + 2
			if ne > exitEdge + 8 and rd ~= lastRoad then
				local c = tl:Clone()
				c:PivotTo(CFrame.new(L.Market.x2 + 3, 10.4 + SIDEWALK_TOP - 0.5, ne) * CFrame.Angles(0, math.rad(90), 0) * CFrame.new(0, 0, -10.3))
				c.Parent = f.Furniture
			end
			if sw < entryEdge - 8 and rd ~= firstRoad then
				local c = tl:Clone()
				c:PivotTo(CFrame.new(L.Market.x1 - 3, 10.4 + SIDEWALK_TOP - 0.5, sw) * CFrame.Angles(0, math.rad(-90), 0) * CFrame.new(0, 0, -10.3))
				c.Parent = f.Furniture
			end
		end
		if busstop and i < #roads then
			local zb = (rd.rect.z1 + roads[i + 1].rect.z2) / 2
			for _, sx in { -1, 1 } do
				local x = sx * (L.Market.x2 + 3.5)
				if clear(x, zb, 12) then
					U.place(busstop, f.Furniture, x, SIDEWALK_TOP, zb + sx * 30, Vector3.new(-sx, 0, 0))
				end
			end
		end
	end
	-- manhole covers on the roads
	for _ = 1, 14 do
		local x = U.pick({ -26, 26, -289, 289, -8 + 0 })
		local zz = U.range(exitEdge + 20, entryEdge - 20)
		if math.abs(x) > 16 and clear(x, zz, 2) then
			U.part(f.Markings, "ManholeCover", Vector3.new(0.2, 4.2, 4.2), CFrame.new(x, 0.05, zz) * CFrame.Angles(0, 0, math.rad(90)), {
				Shape = Enum.PartType.Cylinder, Material = Enum.Material.DiamondPlate, Color = Color3.fromRGB(40, 40, 42), CanCollide = false, CanQuery = false,
			})
		end
	end

	------------------------------------------------------------ parked cars on the streets
	local cars = kit.Cars:GetChildren()
	local parkFolder = U.folder(f.Traffic, "Parked")
	local function carBlocked(x, zz)
		for _, rd in roads do
			if math.abs(zz - rd.spec.zc) < rd.spec.w / 2 + 45 then
				return true
			end
		end
		for _, h in holes do
			if zz > h.z1 - 16 and zz < h.z2 + 16 and x > h.x1 - 14 and x < h.x2 + 14 then
				return true
			end
		end
		for _, p in potholes do
			if math.abs(p.X - x) < 8 and math.abs(p.Z - zz) < 16 then
				return true
			end
		end
		return false
	end
	if #cars > 0 then
		for _, side in { { x = L.StreetLanes.WestPark, look = Vector3.new(0, 0, 1) }, { x = L.StreetLanes.EastPark, look = Vector3.new(0, 0, -1) } } do
			local zz = exitEdge + 30
			while zz < entryEdge - 30 do
				if not carBlocked(side.x, zz) and U.chance(0.6) then
					U.place(U.pick(cars), parkFolder, side.x, 0, zz, side.look)
				end
				zz += U.range(24, 30)
			end
		end
	end

	------------------------------------------------------------ zone arch
	-- up the Market sidewalk from the first junction, clear of its sign and lights
	-- (where the express link comes in over the west lanes, the arch stands
	-- taller and wider so the link passes under it)
	local archZ = firstRoad.rect.z1 - 12
	local archY = ctx.linkSouth and 44.3 or 30
	local archX = ctx.linkSouth and 45.5 or 41
	for _, sx in { -1, 1 } do
		U.part(f.Landmarks, "ArchPillar", Vector3.new(3, archY, 3), CFrame.new(sx * archX, archY / 2, archZ), { Material = Enum.Material.Brick, Color = Color3.fromRGB(125, 72, 56) })
	end
	U.part(f.Landmarks, "ArchBeam", Vector3.new(archX * 2 + 4, 4, 3), CFrame.new(0, archY, archZ), { Material = Enum.Material.Brick, Color = Color3.fromRGB(125, 72, 56) })
	for _, sz in { -1, 1 } do
		textSign(f.Landmarks, "ArchSign", Vector3.new(50, 3.6, 0.3), CFrame.new(0, archY, archZ + sz * 1.7), string.upper(spec.Name),
			{ sz > 0 and Enum.NormalId.Back or Enum.NormalId.Front }, Color3.fromRGB(30, 30, 34), Color3.fromRGB(255, 220, 140))
	end

	------------------------------------------------------------ landmarks
	for _, lm in spec.Landmarks or {} do
		Landmarks.Build(f.Landmarks, kit, lm, styleKey)
	end

	------------------------------------------------------------ destinations
	for _, d in dests do
		local def = d.def
		local m = Dock.Build(f.Dest, kit, d.rect, def.access, {
			name = def.Name, spaces = def.spaces, rig = def.rig, depth = def.depth,
			height = styleKey == "Harbour" and 24 or 28,
			color = styleKey == "Mill" and Color3.fromRGB(110, 84, 70) or (styleKey == "Harbour" and Color3.fromRGB(80, 100, 116) or nil),
		})
		m:SetAttribute("Zone", spec.Id)
	end

	-- quay (Harbour's far end)
	if spec.QuayFrom then
		U.box(f.Edges, "Apron", U.rect(-L.HalfWidth, spec.Exit, L.HalfWidth, spec.QuayFrom), 0.001, 0.04, {
			Material = Enum.Material.Concrete, Color = Color3.fromRGB(105, 103, 100), CanCollide = false, CanQuery = false, CastShadow = false,
		})
		U.box(f.Edges, "QuayKerb", U.rect(-L.HalfWidth, spec.Exit, L.HalfWidth, spec.Exit + 1.5), 0, 1.6, {
			Material = Enum.Material.Concrete, Color = Color3.fromRGB(210, 180, 40),
		})
		for x = -L.HalfWidth + 10, L.HalfWidth - 10, 30 do
			U.part(f.Edges, "Bollard", Vector3.new(1.6, 2.4, 1.6), CFrame.new(x, 2.8, spec.Exit + 0.75), { Material = Enum.Material.Metal, Color = Color3.fromRGB(40, 40, 42) })
		end
	end

	out.holes = holes
	out.roads = roads
	out.entryEdge = entryEdge
	out.exitEdge = exitEdge
	out.potholes = potholes
	return out
end

return Zone

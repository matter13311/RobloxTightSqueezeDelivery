-- The distant city outside the walls, so the playable strip reads as one
-- district of a bigger town instead of an island in the ocean.
--
--   require(game.ServerStorage.MapGen.Backdrop).Build()
--
-- Main.Run / RunZones / RunConnectors call it after Bounds.Build.
--
-- Nobody can ever get to any of this (Bounds walls the playable area in), so it
-- is built as cheaply as it can be and still sell the illusion:
--   * ONE dark ground slab set under everything, at the level the city's own
--     ground meets it, with the harbour's sea left open (Layout.Backdrop);
--   * plain concrete boxes for buildings - no textures, no shadows, no
--     collision, no queries - in three rings of coarser and coarser blocks, so
--     the part count is spent near the walls where it can be seen and the far
--     ring is a few big towers that the atmosphere haze turns into a skyline;
--   * ring blocks are jittered and randomly dropped, so the gaps read as
--     streets and the grid does not look like a grid.
-- Seeded, so the same map gets the same skyline.
--
-- CULLED BY SIGHT. Most of the blocks the rings lay down can never be seen: a
-- player on foot or in a cab is at eye height inside the city's own buildings,
-- and only the tall blocks poking above the skyline (and the ones at the very
-- edge of the land) ever reach the eye. So after placing them every block is
-- tested from a lattice of real eye positions - on the ground, and on the
-- express deck - and any block that no eye can see the top of is deleted. See
-- `cull`. That is what keeps this to a couple of hundred parts.
--
-- The model is Persistent: the far rings sit beyond StreamingTargetRadius, and
-- streamed-out scenery would leave a hole in the horizon.

local L = require(script.Parent.Layout)
local Bounds = require(script.Parent.Bounds)

local Backdrop = {}

local FOLDER = "Backdrop"
local SEED = 7

local MAX_PART = 2000

-- Culling. Eye positions are sampled every VIEW_STEP studs across the land at
-- first-person height (or on the express deck), and a block is kept only if
-- one of them has a clear line to a point on its roof. Only things this big
-- count as blocking the line: a lamp post or a parked car does not hide a
-- skyline from anyone standing next to it.
local VIEW_STEP = 32
local EYE_HEIGHT = 5.5
local DECK_EYE = 5.5 -- above the express deck's surface
local OCCLUDER_MIN = 25 -- part Size.Magnitude
local MAX_HOPS = 8
local GROUND_TOP = -1 -- just under the city's own ground (0)
local CLEAR = 40 -- nothing is built this close to the city: the walls and a margin

-- Rings by distance from the city, studs. `cell` is the block pitch, `fill` the
-- fraction of a block a building covers (the rest is street), `h` its height.
local RINGS = {
	{ from = CLEAR, to = 320, cell = 64, fill = { 0.7, 0.94 }, h = { 18, 50 }, skip = 0.06 },
	{ from = 320, to = 900, cell = 128, fill = { 0.7, 0.94 }, h = { 30, 90 }, skip = 0.06 },
	{ from = 900, to = math.huge, cell = 256, fill = { 0.65, 0.92 }, h = { 60, 170 }, skip = 0.05 },
}

-- The city's own palette (Style.Zones colours) knocked back towards grey, so
-- the distant town matches the near one without drawing the eye.
local COLORS = {
	Color3.fromRGB(118, 96, 86), Color3.fromRGB(132, 108, 92), Color3.fromRGB(150, 140, 126),
	Color3.fromRGB(104, 100, 98), Color3.fromRGB(126, 118, 108), Color3.fromRGB(96, 104, 112),
	Color3.fromRGB(110, 92, 80), Color3.fromRGB(140, 128, 112),
}
local GROUND = Color3.fromRGB(46, 46, 50)

local function inRects(rects, x, z, pad)
	for _, r in rects do
		if x >= r.x1 - pad and x <= r.x2 + pad and z >= r.z1 - pad and z <= r.z2 + pad then
			return true
		end
	end
	return false
end

local function part(parent, name, size, pos, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Material = material
	p.Color = color
	p.Size = size
	p.Position = pos
	p.Parent = parent
	return p
end

-- Ground for the whole world except the water rects. Only handles the shapes
-- the layout uses: each water rect is cut out by splitting the slab into the
-- strips around it, so keep them axis-aligned and inside the world.
local function groundRects(world, holes)
	local rects = { { x1 = world.x1, z1 = world.z1, x2 = world.x2, z2 = world.z2 } }
	for _, h in holes do
		local nextRects = {}
		for _, r in rects do
			if h.x2 <= r.x1 or h.x1 >= r.x2 or h.z2 <= r.z1 or h.z1 >= r.z2 then
				table.insert(nextRects, r)
				continue
			end
			if h.z1 > r.z1 then
				table.insert(nextRects, { x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = h.z1 })
			end
			if h.z2 < r.z2 then
				table.insert(nextRects, { x1 = r.x1, z1 = h.z2, x2 = r.x2, z2 = r.z2 })
			end
			local z1, z2 = math.max(r.z1, h.z1), math.min(r.z2, h.z2)
			if h.x1 > r.x1 then
				table.insert(nextRects, { x1 = r.x1, z1 = z1, x2 = h.x1, z2 = z2 })
			end
			if h.x2 < r.x2 then
				table.insert(nextRects, { x1 = h.x2, z1 = z1, x2 = r.x2, z2 = z2 })
			end
		end
		rects = nextRects
	end
	return rects
end

-- Eye positions a person could actually have: standing (or driving) on the
-- ground, or on the express deck. Found by probing a lattice of cells, so it
-- follows whatever the map is now rather than being listed by hand.
local function eyePositions(raster, params)
	local eyes = {}
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = params.FilterDescendantsInstances
	local stepCells = math.max(1, math.round(VIEW_STEP / raster.Cell))
	for j = 0, raster.Nz - 1, stepCells do
		for i = 0, raster.Nx - 1, stepCells do
			if raster.isSea(i, j) then
				continue
			end
			local x, z = raster.cellCentre(i, j)
			-- ground: clear air at eye height with ground just beneath it
			local eye = Vector3.new(x, EYE_HEIGHT, z)
			if #workspace:GetPartBoundsInBox(CFrame.new(eye), Vector3.one, overlap) == 0 then
				local hit = workspace:Raycast(eye, Vector3.new(0, -EYE_HEIGHT - 3, 0), params)
				if hit and hit.Position.Y > -1 then
					table.insert(eyes, eye)
				end
			end
			-- deck: the same, but the surface under the eye has to be the express
			local top = Vector3.new(x, 24 + DECK_EYE + 6, z)
			local hit = workspace:Raycast(top, Vector3.new(0, -24, 0), params)
			if hit and hit.Instance:FindFirstAncestor("Express") and hit.Normal.Y > 0.9 then
				local eyeDeck = hit.Position + Vector3.new(0, DECK_EYE, 0)
				if #workspace:GetPartBoundsInBox(CFrame.new(eyeDeck), Vector3.one, overlap) == 0 then
					table.insert(eyes, eyeDeck)
				end
			end
		end
	end
	return eyes
end

-- Deletes every block no eye can see. `blocks` is { { part =, d = }, ... }.
-- Nearest first, and a deleted block stops counting as scenery, so a block
-- hidden behind another hidden block is not saved by it - but one behind a
-- block that IS kept is correctly culled.
local function cull(raster, blocks, exclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	local eyes = eyePositions(raster, params)

	local base = table.clone(exclude)
	table.sort(blocks, function(a, b)
		return a.d < b.d
	end)

	local function visible(eye, target, block)
		local delta = target - eye
		local ray = delta.Unit * (delta.Magnitude + 1)
		local hops = 0
		local extra = nil
		local seen = false
		while hops < MAX_HOPS do
			local hit = workspace:Raycast(eye, ray, params)
			if not hit then
				break
			end
			local inst = hit.Instance
			if inst == block then
				seen = true
				break
			end
			if inst.Size.Magnitude >= OCCLUDER_MIN and inst.Transparency < 0.9 then
				break -- a wall of the city: blocked
			end
			-- small or see-through: look past it
			extra = extra or table.clone(base)
			table.insert(extra, inst)
			params.FilterDescendantsInstances = extra
			hops += 1
		end
		if extra then
			params.FilterDescendantsInstances = base
		end
		return seen
	end

	local kept = 0
	for _, b in blocks do
		local part = b.part
		local size, pos = part.Size, part.Position
		local roofY = pos.Y + size.Y / 2 - 0.3
		local hx, hz = size.X * 0.4, size.Z * 0.4
		local targets = {
			Vector3.new(pos.X, roofY, pos.Z),
			Vector3.new(pos.X - hx, roofY, pos.Z - hz),
			Vector3.new(pos.X + hx, roofY, pos.Z + hz),
			Vector3.new(pos.X - hx, roofY, pos.Z + hz),
			Vector3.new(pos.X + hx, roofY, pos.Z - hz),
		}
		local seenBy = false
		for _, eye in eyes do
			for _, target in targets do
				if visible(eye, target, part) then
					seenBy = true
					break
				end
			end
			if seenBy then
				break
			end
		end
		if seenBy then
			kept += 1
		else
			part:Destroy()
		end
	end
	return kept, #eyes
end

function Backdrop.Build()
	local t0 = os.clock()
	local old = workspace:FindFirstChild(FOLDER)
	if old then
		old:Destroy()
	end

	local raster = Bounds.Raster()
	local cell, nx, nz, gx0, gz0 = raster.Cell, raster.Nx, raster.Nz, raster.X0, raster.Z0
	local W = L.World
	-- The open water stops short of the world's edge so the far shore is
	-- skyline too, not a bare horizon line: sides on the edge are pulled in.
	local water = {}
	for _, r in L.Backdrop.WaterRects do
		table.insert(water, {
			x1 = if r.x1 <= W.x1 then r.x1 + L.Backdrop.EdgeBand else r.x1,
			z1 = if r.z1 <= W.z1 then r.z1 + L.Backdrop.EdgeBand else r.z1,
			x2 = if r.x2 >= W.x2 then r.x2 - L.Backdrop.EdgeBand else r.x2,
			z2 = if r.z2 >= W.z2 then r.z2 - L.Backdrop.EdgeBand else r.z2,
		})
	end

	-- distance from the city, in studs, for every cell: a breadth-first sweep
	-- out from the land (8-connected, so it is close to true distance)
	local dist = table.create(nx * nz, math.huge)
	local queue, head = {}, 1
	for j = 0, nz - 1 do
		for i = 0, nx - 1 do
			if not raster.isSea(i, j) then
				dist[j * nx + i + 1] = 0
				table.insert(queue, j * nx + i)
			end
		end
	end
	while head <= #queue do
		local k = queue[head]
		head += 1
		local i, j = k % nx, k // nx
		local d = dist[k + 1]
		for dj = -1, 1 do
			for di = -1, 1 do
				local a, b = i + di, j + dj
				if (di ~= 0 or dj ~= 0) and a >= 0 and b >= 0 and a < nx and b < nz then
					local step = if di ~= 0 and dj ~= 0 then cell * 1.4142 else cell
					local ki = b * nx + a + 1
					if d + step < dist[ki] then
						dist[ki] = d + step
						table.insert(queue, ki - 1)
					end
				end
			end
		end
	end
	local function distanceAt(x, z)
		local i = math.clamp(math.floor((x - gx0) / cell), 0, nx - 1)
		local j = math.clamp(math.floor((z - gz0) / cell), 0, nz - 1)
		return dist[j * nx + i + 1]
	end

	local model = Instance.new("Model")
	model.Name = FOLDER
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	local groundFolder = Instance.new("Folder")
	groundFolder.Name = "Ground"
	groundFolder.Parent = model
	local grounds = 0
	for _, r in groundRects(W, water) do
		-- a Part cannot be bigger than 2048 on a side, so tile anything larger
		local tx, tz = math.ceil((r.x2 - r.x1) / MAX_PART), math.ceil((r.z2 - r.z1) / MAX_PART)
		local w, d = (r.x2 - r.x1) / tx, (r.z2 - r.z1) / tz
		for a = 0, tx - 1 do
			for b = 0, tz - 1 do
				part(groundFolder, "Ground", Vector3.new(w, 2, d),
					Vector3.new(r.x1 + w * (a + 0.5), GROUND_TOP - 1, r.z1 + d * (b + 0.5)), GROUND, Enum.Material.Concrete)
				grounds += 1
			end
		end
	end

	local rng = Random.new(SEED)
	local towers = Instance.new("Folder")
	towers.Name = "Buildings"
	towers.Parent = model
	local count = 0
	local blocks = {}
	for _, ring in RINGS do
		local pitch = ring.cell
		local x = math.ceil(W.x1 / pitch) * pitch
		while x + pitch <= W.x2 do
			local z = math.ceil(W.z1 / pitch) * pitch
			while z + pitch <= W.z2 do
				local cx, cz = x + pitch / 2, z + pitch / 2
				local d = distanceAt(cx, cz)
				-- the block's own corners must clear the city too, not just its
				-- middle, or a big far block can lean into the walls
				local nearest = math.min(d, distanceAt(x, z), distanceAt(x + pitch, z), distanceAt(x, z + pitch), distanceAt(x + pitch, z + pitch))
				if d >= ring.from and d < ring.to and nearest >= CLEAR and not inRects(water, cx, cz, pitch / 2)
					and rng:NextNumber() > ring.skip then
					local fw = ring.fill[1] + rng:NextNumber() * (ring.fill[2] - ring.fill[1])
					local fd = ring.fill[1] + rng:NextNumber() * (ring.fill[2] - ring.fill[1])
					local h = ring.h[1] + rng:NextNumber() ^ 1.6 * (ring.h[2] - ring.h[1])
					local jx = (rng:NextNumber() - 0.5) * pitch * (1 - fw)
					local jz = (rng:NextNumber() - 0.5) * pitch * (1 - fd)
					local block = part(towers, "Block", Vector3.new(pitch * fw, h, pitch * fd),
						Vector3.new(cx + jx, GROUND_TOP + h / 2, cz + jz), COLORS[rng:NextInteger(1, #COLORS)], Enum.Material.Concrete)
					block.CanQuery = true -- only while the culling rays run
					table.insert(blocks, { part = block, d = d })
					count += 1
				end
				z += pitch
			end
			x += pitch
		end
	end

	model.Parent = workspace

	local map = workspace:FindFirstChild("Map")
	local exclude = { groundFolder, workspace.Terrain }
	for _, name in { "Vehicles", "Trailers", "Arms" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	if map then
		for _, name in { "Sea", "Bounds" } do
			local f = map:FindFirstChild(name)
			if f then
				table.insert(exclude, f)
			end
		end
	end
	local kept, eyes = cull(raster, blocks, exclude)
	for _, b in blocks do
		if b.part.Parent then
			b.part.CanQuery = false
		end
	end
	return string.format("Backdrop: %d of %d buildings visible (%d eye points) + %d ground slabs in %.1fs",
		kept, count, eyes, grounds, os.clock() - t0)
end

return Backdrop

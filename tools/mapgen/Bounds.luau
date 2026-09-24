-- Invisible walls around the whole playable area, so a player on foot cannot
-- walk (or jump) off the city onto the sea, which is a solid glass slab that
-- can be stood on. Vehicles never get near an edge - every road is sealed by
-- buildings (see Zone.endWall and the connector terraces) - so this only ever
-- stops characters.
--
--   require(game.ServerStorage.MapGen.Bounds).Build()
--
-- Main.Run, Main.RunZones and Main.RunConnectors all call it last, so the
-- walls always match whatever the map looks like NOW, hand edits included.
--
-- HOW. The outline is read off the built map, not derived from Layout: every
-- solid part above the water is stamped onto a coarse grid, the sea is flood-
-- filled in from the edge of the world, and whatever the sea did not reach is
-- land (which also fills any enclosed pocket of water, so no wall is spent
-- fencing something nobody can reach). One wall goes on every land/sea cell
-- boundary and collinear ones are merged into a single box.
--
-- The grid is deliberately OVER-inclusive: a cell counts as land if any part
-- touches it, so the wall lands at or just beyond the real edge and can never
-- cut into the city. The price is up to one cell of sea between the land and
-- the wall, which nobody will notice on the far side of a kerb.

local L = require(script.Parent.Layout)

local Bounds = {}

local CELL = 8 -- grid resolution, studs
local THICK = 6 -- wall thickness (outward from the boundary), studs
local BOTTOM = -14 -- below the water and the catch floor's reach for a jump
local TOP = 320 -- higher than any building, express deck or jump
local MIN_TOP = -2 -- parts whose top is under this are the seabed, not land

local FOLDER = "Bounds"

-- Only parts the city is made of. Sea, the walls themselves and anything that
-- is not solid (shopfront modules, gate volumes, decals' parents) are ignored.
local function isLand(part)
	return part:IsA("BasePart") and part.CanCollide and part.Size.Magnitude > 0.5
end

-- The land/sea grid, for anything else that needs to know where the city
-- stops (Backdrop). `isSea(i, j)` is true for open water and for every cell
-- off the grid; `cellCentre(i, j)` is the world X, Z of a cell's middle.
function Bounds.Raster()
	local map = workspace:WaitForChild("Map")
	local sea = map:FindFirstChild("Sea")
	local walls = map:FindFirstChild(FOLDER) -- a rebuild must not fence its own old walls

	local W = L.World
	local gx0, gz0 = W.x1, W.z1
	local nx = math.ceil((W.x2 - W.x1) / CELL)
	local nz = math.ceil((W.z2 - W.z1) / CELL)
	local land = table.create(nx * nz, false)
	local function idx(i, j)
		return j * nx + i + 1
	end

	-- 1. stamp every solid part onto the grid
	local half = CELL * 0.75
	for _, p in map:GetDescendants() do
		if not isLand(p) or (sea and p:IsDescendantOf(sea)) or (walls and p:IsDescendantOf(walls)) then
			continue
		end
		local cf, size = p.CFrame, p.Size
		local ex = (math.abs(cf.RightVector.X) * size.X + math.abs(cf.UpVector.X) * size.Y + math.abs(cf.LookVector.X) * size.Z) / 2
		local ey = (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z) / 2
		local ez = (math.abs(cf.RightVector.Z) * size.X + math.abs(cf.UpVector.Z) * size.Y + math.abs(cf.LookVector.Z) * size.Z) / 2
		if cf.Position.Y + ey < MIN_TOP then
			continue
		end
		-- a part only turned about Y is tested as its true rectangle; anything
		-- tilted (a wedge, a ramp) as its bounding box, which is the safe side
		local flat = math.abs(cf.UpVector.Y) > 0.999
		local hx, hz = size.X / 2 + half, size.Z / 2 + half
		local i1 = math.max(0, math.floor((cf.Position.X - ex - gx0) / CELL))
		local i2 = math.min(nx - 1, math.floor((cf.Position.X + ex - gx0) / CELL))
		local j1 = math.max(0, math.floor((cf.Position.Z - ez - gz0) / CELL))
		local j2 = math.min(nz - 1, math.floor((cf.Position.Z + ez - gz0) / CELL))
		for j = j1, j2 do
			for i = i1, i2 do
				local k = idx(i, j)
				if not land[k] then
					if flat then
						local lp = cf:PointToObjectSpace(Vector3.new(gx0 + (i + 0.5) * CELL, cf.Position.Y, gz0 + (j + 0.5) * CELL))
						if math.abs(lp.X) <= hx and math.abs(lp.Z) <= hz then
							land[k] = true
						end
					else
						land[k] = true
					end
				end
			end
		end
	end

	-- 2. flood the sea in from the world's edge; whatever it never reaches is land
	local reached = table.create(nx * nz, false)
	local stack = {}
	local function push(i, j)
		if i < 0 or j < 0 or i >= nx or j >= nz then
			return
		end
		local k = idx(i, j)
		if land[k] or reached[k] then
			return
		end
		reached[k] = true
		table.insert(stack, k)
	end
	for i = 0, nx - 1 do
		push(i, 0)
		push(i, nz - 1)
	end
	for j = 0, nz - 1 do
		push(0, j)
		push(nx - 1, j)
	end
	while #stack > 0 do
		local k = table.remove(stack) - 1
		local i, j = k % nx, k // nx
		push(i + 1, j)
		push(i - 1, j)
		push(i, j + 1)
		push(i, j - 1)
	end
	local function isSea(i, j)
		if i < 0 or j < 0 or i >= nx or j >= nz then
			return true
		end
		return reached[idx(i, j)]
	end

	return {
		Cell = CELL,
		Nx = nx,
		Nz = nz,
		X0 = gx0,
		Z0 = gz0,
		isSea = isSea,
		cellCentre = function(i, j)
			return gx0 + (i + 0.5) * CELL, gz0 + (j + 0.5) * CELL
		end,
	}
end

function Bounds.Build()
	local t0 = os.clock()
	local map = workspace:WaitForChild("Map")
	local old = map:FindFirstChild(FOLDER)
	if old then
		old:Destroy()
	end
	local r = Bounds.Raster()
	local nx, nz, gx0, gz0, isSea = r.Nx, r.Nz, r.X0, r.Z0, r.isSea

	-- 3. a wall on every land/sea boundary, merged along collinear runs
	local folder = Instance.new("Folder")
	folder.Name = FOLDER
	local count = 0
	local function wall(x1, z1, x2, z2)
		local p = Instance.new("Part")
		p.Name = "BoundsWall"
		p.Anchored = true
		p.CanCollide = true
		p.CanTouch = false
		p.CanQuery = false -- invisible geometry must not eat the mirrors' part budget
		p.CastShadow = false
		p.Transparency = 1
		p.Size = Vector3.new(x2 - x1, TOP - BOTTOM, z2 - z1)
		p.CFrame = CFrame.new((x1 + x2) / 2, (TOP + BOTTOM) / 2, (z1 + z2) / 2)
		p.Parent = folder
		count += 1
	end

	-- horizontal boundaries (a wall along X) on the north (-z) and south (+z)
	-- side of a land row, then vertical ones (along Z) on west and east
	for _, dir in { -1, 1 } do
		for j = 0, nz - 1 do
			local runStart = nil
			for i = 0, nx do
				local edge = i < nx and not isSea(i, j) and isSea(i, j + dir)
				if edge and not runStart then
					runStart = i
				elseif not edge and runStart then
					local x1, x2 = gx0 + runStart * CELL, gx0 + i * CELL
					local zb = gz0 + (if dir < 0 then j else j + 1) * CELL
					if dir < 0 then
						wall(x1, zb - THICK, x2, zb)
					else
						wall(x1, zb, x2, zb + THICK)
					end
					runStart = nil
				end
			end
		end
	end
	for _, dir in { -1, 1 } do
		for i = 0, nx - 1 do
			local runStart = nil
			for j = 0, nz do
				local edge = j < nz and not isSea(i, j) and isSea(i + dir, j)
				if edge and not runStart then
					runStart = j
				elseif not edge and runStart then
					local z1, z2 = gz0 + runStart * CELL, gz0 + j * CELL
					local xb = gx0 + (if dir < 0 then i else i + 1) * CELL
					if dir < 0 then
						wall(xb - THICK, z1, xb, z2)
					else
						wall(xb, z1, xb + THICK, z2)
					end
					runStart = nil
				end
			end
		end
	end

	folder.Parent = map
	return string.format("Bounds: %d wall parts in %.1fs (cell %d)", count, os.clock() - t0, CELL)
end

return Bounds

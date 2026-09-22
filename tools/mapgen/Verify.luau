-- Reachability check for one vehicle class at a time:
--
--   print(require(game.ServerStorage.MapGen.Verify).Run("BoxTruck"))
--
-- Rasterises the world onto a 1-stud grid: a cell is drivable only if some
-- surface (road, sidewalk, verge, deck - anything whose top is between -0.2
-- and 0.7) covers it, and no solid part lower than the vehicle's roof comes
-- within the vehicle's half-width of it (oriented boxes; the triangular
-- building fillers of angled alleys as real triangles). Then it flood-fills
-- from the Terminal yard and reports every space, garage and alley the class
-- cannot reach. Permit/express gates are ignored (every pass assumed owned).

local L = require(script.Parent.Layout)

local Verify = {}

local CELL = 1
local W = L.World
local X0, Z0 = W.x1, W.z1
local NX = math.ceil((W.x2 - W.x1) / CELL)
local NZ = math.ceil((W.z2 - W.z1) / CELL)

local CLASSES = {
	Starter = { half = 4.1, height = 5.5 },
	Pickup = { half = 5.15, height = 6.3 },
	BoxTruck = { half = 5.65, height = 10.9 },
	StraightTruck = { half = 5.8, height = 12.8 },
	HitchTruck = { half = 6.0, height = 15.5 },
}

local function idx(i, j)
	return j * NX + i
end
local function toCell(x, z)
	return math.floor((x - X0) / CELL), math.floor((z - Z0) / CELL)
end

local function vertical(cf, s)
	return math.abs(cf.RightVector.Y) * s.X / 2 + math.abs(cf.UpVector.Y) * s.Y / 2 + math.abs(cf.LookVector.Y) * s.Z / 2
end

-- distance from 2D point p to segment ab
local function segDist(px, py, ax, ay, bx, by)
	local dx, dy = bx - ax, by - ay
	local t = math.clamp(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy), 0, 1)
	local qx, qy = ax + dx * t - px, ay + dy * t - py
	return math.sqrt(qx * qx + qy * qy)
end

local function paint(grid, cf, s, grow, value, test)
	-- iterate the grown horizontal bounding box of an oriented part
	local r = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
	local u = Vector3.new(cf.UpVector.X, 0, cf.UpVector.Z)
	local l = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	local ex = math.abs(r.X) * s.X / 2 + math.abs(u.X) * s.Y / 2 + math.abs(l.X) * s.Z / 2 + grow
	local ez = math.abs(r.Z) * s.X / 2 + math.abs(u.Z) * s.Y / 2 + math.abs(l.Z) * s.Z / 2 + grow
	local i1, j1 = toCell(cf.X - ex, cf.Z - ez)
	local i2, j2 = toCell(cf.X + ex, cf.Z + ez)
	for j = math.max(0, j1), math.min(NZ - 1, j2) do
		local z = Z0 + (j + 0.5) * CELL
		for i = math.max(0, i1), math.min(NX - 1, i2) do
			local x = X0 + (i + 0.5) * CELL
			if test(x, z) then
				buffer.writeu8(grid, idx(i, j), value)
			end
		end
	end
end

local function boxTest(cf, s, grow)
	return function(x, z)
		local lp = cf:PointToObjectSpace(Vector3.new(x, cf.Y, z))
		return math.abs(lp.X) <= s.X / 2 + grow and math.abs(lp.Y) <= s.Y / 2 + grow and math.abs(lp.Z) <= s.Z / 2 + grow
	end
end

-- a WedgePart laid on its side (local X vertical): triangle in local (Y, Z)
local function planWedgeTest(cf, s, grow)
	local h, d = s.Y / 2, s.Z / 2
	return function(x, z)
		local lp = cf:PointToObjectSpace(Vector3.new(x, cf.Y, z))
		local y, zz = lp.Y, lp.Z
		-- inside?
		if y >= -h and zz <= d and y <= zz * (h / d) then
			return true
		end
		if grow <= 0 then
			return false
		end
		local dist = math.min(segDist(y, zz, -h, -d, -h, d), segDist(y, zz, -h, d, h, d), segDist(y, zz, h, d, -h, -d))
		return dist <= grow
	end
end

local function collect()
	local parts = {}
	for _, root in { workspace.Map, workspace.Delivery } do
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			end
		end
	end
	return parts
end

local function rasterize(class, parts)
	local grid = buffer.create(NX * NZ)
	buffer.fill(grid, 0, 1) -- everything blocked (sea) until a surface covers it
	for _, p in parts do
		if not p.CanCollide or p.Transparency >= 1 then
			continue
		end
		local cf, s = p.CFrame, p.Size
		local hy = vertical(cf, s)
		local top = cf.Y + hy
		if top > -0.2 and top <= 0.7 then
			if not p:IsA("WedgePart") then
				paint(grid, cf, s, 0, 0, boxTest(cf, s, 0))
			elseif math.abs(cf.RightVector.Y) > 0.9 then
				-- a flat triangle of a curved road / pavement (U.tri)
				paint(grid, cf, s, 0, 0, planWedgeTest(cf, s, 0))
			end
		end
	end
	for _, p in parts do
		if not p.CanCollide then
			continue
		end
		local cf, s = p.CFrame, p.Size
		local hy = vertical(cf, s)
		local top, bottom = cf.Y + hy, cf.Y - hy
		if top <= 0.7 or bottom >= class.height then
			continue
		end
		local test
		if p:IsA("WedgePart") and math.abs(cf.RightVector.Y) > 0.9 then
			test = planWedgeTest(cf, s, class.half)
		elseif p:IsA("Part") and p.Shape == Enum.PartType.Cylinder and math.abs(cf.RightVector.Y) > 0.9 then
			local rad = s.Y / 2 + class.half
			test = function(x, z)
				return (x - cf.X) ^ 2 + (z - cf.Z) ^ 2 <= rad * rad
			end
		else
			test = boxTest(cf, s, class.half)
		end
		paint(grid, cf, s, class.half, 1, test)
	end
	return grid
end

local function flood(grid, sx, sz)
	local seen = buffer.create(NX * NZ)
	local queue = buffer.create(4 * 1024 * 1024)
	local qcap = 1024 * 1024
	local head, tail = 0, 0
	local function push(k)
		if tail >= qcap then
			local bigger = buffer.create(qcap * 8)
			buffer.copy(bigger, 0, queue, 0, qcap * 4)
			queue = bigger
			qcap *= 2
		end
		buffer.writeu32(queue, tail * 4, k)
		tail += 1
	end
	local si, sj = toCell(sx, sz)
	local k0 = idx(si, sj)
	buffer.writeu8(seen, k0, 1)
	push(k0)
	while head < tail do
		local k = buffer.readu32(queue, head * 4)
		head += 1
		local i, j = k % NX, k // NX
		if i > 0 then
			local nk = k - 1
			if buffer.readu8(seen, nk) == 0 and buffer.readu8(grid, nk) == 0 then
				buffer.writeu8(seen, nk, 1)
				push(nk)
			end
		end
		if i < NX - 1 then
			local nk = k + 1
			if buffer.readu8(seen, nk) == 0 and buffer.readu8(grid, nk) == 0 then
				buffer.writeu8(seen, nk, 1)
				push(nk)
			end
		end
		if j > 0 then
			local nk = k - NX
			if buffer.readu8(seen, nk) == 0 and buffer.readu8(grid, nk) == 0 then
				buffer.writeu8(seen, nk, 1)
				push(nk)
			end
		end
		if j < NZ - 1 then
			local nk = k + NX
			if buffer.readu8(seen, nk) == 0 and buffer.readu8(grid, nk) == 0 then
				buffer.writeu8(seen, nk, 1)
				push(nk)
			end
		end
	end
	return seen, tail
end

local function reached(seen, x, z, radius)
	local i1, j1 = toCell(x - radius, z - radius)
	local i2, j2 = toCell(x + radius, z + radius)
	for j = math.max(0, j1), math.min(NZ - 1, j2) do
		for i = math.max(0, i1), math.min(NX - 1, i2) do
			if buffer.readu8(seen, idx(i, j)) == 1 then
				return true
			end
		end
	end
	return false
end

local cache = {}

function Verify.Run(className)
	local class = CLASSES[className or "BoxTruck"]
	local t0 = os.clock()
	local grid = rasterize(class, collect())
	local seen, n = flood(grid, 0, 200)
	cache.grid, cache.seen = grid, seen
	local miss = {}
	for _, dest in workspace.Delivery.Destinations:GetChildren() do
		for _, s in dest:GetChildren() do
			if s.Name:match("^Space") and not reached(seen, s.Position.X, s.Position.Z, 6) then
				table.insert(miss, dest.Name .. "." .. s.Name)
			end
		end
	end
	for _, s in workspace.Delivery.Depot.LoadingBay:GetChildren() do
		if s.Name:match("^Space") and not reached(seen, s.Position.X, s.Position.Z, 6) then
			table.insert(miss, "LoadingBay." .. s.Name)
		end
	end
	for _, plot in workspace.Spawn.VehiclePlots:GetChildren() do
		local vs = plot:FindFirstChild("VehicleSpawn")
		if vs and not reached(seen, vs.Position.X, vs.Position.Z, 6) then
			table.insert(miss, plot.Name)
		end
	end
	-- alleys: every 4 studs along each straight north-south leg must have a
	-- reached cell somewhere across its width
	local alleyMiss = {}
	for _, zone in L.Zones do
		for _, seg in zone.Segments do
			for _, side in { "West", "East" } do
				local a = seg[side]
				local ok = true
				local nodes = {}
				for i, nd in a.Path do
					table.insert(nodes, { x = nd.x, z = i == 1 and seg.z2 or (i == #a.Path and seg.z1 or nd.z) })
				end
				for k = 1, #nodes - 1 do
					local p, q = nodes[k], nodes[k + 1]
					if p.x == q.x then
						local z = q.z + 3
						while z < p.z - 3 and ok do
							local any = false
							for dx = -a.w / 2 + 0.5, a.w / 2 - 0.5, 0.5 do
								local w = zone.Frame * Vector3.new(p.x + dx, 0, z)
								local i, j = toCell(w.X, w.Z)
								if buffer.readu8(seen, idx(i, j)) == 1 then
									any = true
									break
								end
							end
							ok = any
							z += 4
						end
					end
				end
				if not ok then
					table.insert(alleyMiss, a.Name .. "(" .. a.w .. ")")
				end
			end
		end
	end
	return string.format("%s: %s | alleys not passable: %s | %d cells, %.1fs", className or "BoxTruck",
		#miss == 0 and "ALL stops+garages reachable" or ("MISSING " .. table.concat(miss, ", ")),
		#alleyMiss == 0 and "none" or table.concat(alleyMiss, ", "), n, os.clock() - t0)
end

-- ASCII dump of a world window from the last Run: '#' blocked, '.' reached, ' ' free but unreached.
function Verify.Debug(x1, z1, x2, z2, step)
	step = step or 1
	local rows = {}
	for z = z1, z2, step do
		local row = {}
		for x = x1, x2, step do
			local i, j = toCell(x, z)
			local k = idx(i, j)
			row[#row + 1] = buffer.readu8(cache.grid, k) == 1 and "#" or (buffer.readu8(cache.seen, k) == 1 and "." or " ")
		end
		rows[#rows + 1] = string.format("%6d ", z) .. table.concat(row)
	end
	return table.concat(rows, "\n")
end

return Verify

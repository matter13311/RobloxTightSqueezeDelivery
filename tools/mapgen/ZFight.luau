-- Finds z-fighting (flicker): pairs of visible parts whose TOP faces lie in
-- the same horizontal plane and overlap. From the Studio command bar:
--
--   print(require(game.ServerStorage.MapGen.ZFight).Run())
--
-- Tops handled: blocks with any axis vertical (rectangle), and wedges laid on
-- their side (triangle - the U.tri / U.triangle pieces). Returns a summary by
-- part-name pair, worst first, plus a few example positions.

local ZFight = {}

local TOL = 0.004 -- same plane if tops differ by less than this
local MIN_AREA = 0.25 -- ignore overlaps smaller than this (studs^2)
local CELL = 32

local function topPoly(p)
	if p.Transparency >= 0.9 then
		return nil
	end
	local cf, s = p.CFrame, p.Size
	local axes = { { cf.RightVector, s.X }, { cf.UpVector, s.Y }, { cf.LookVector, s.Z } }
	if p:IsA("WedgePart") then
		local r = cf.RightVector
		if math.abs(r.Y) < 0.999 then
			return nil
		end
		local sx = r.Y > 0 and 1 or -1
		local h, d = s.Y / 2, s.Z / 2
		local pts = {}
		for _, yz in { { -h, -d }, { h, d }, { -h, d } } do
			table.insert(pts, cf * Vector3.new(sx * s.X / 2, yz[1], yz[2]))
		end
		return pts, pts[1].Y
	end
	if p:IsA("Part") and p.Shape ~= Enum.PartType.Block then
		return nil
	end
	if not (p:IsA("Part") or p:IsA("TrussPart")) then
		return nil -- meshes, unions: unknown top shape
	end
	for k, ax in axes do
		if math.abs(ax[1].Y) > 0.999 then
			local sign = ax[1].Y > 0 and 1 or -1
			local top = cf.Position + ax[1] * sign * ax[2] / 2
			local o = {}
			for kk, other in axes do
				if kk ~= k then
					table.insert(o, other)
				end
			end
			local u, v = o[1][1] * o[1][2] / 2, o[2][1] * o[2][2] / 2
			return { top + u + v, top + u - v, top - u - v, top - u + v }, top.Y
		end
	end
	return nil
end

-- 2D convex polygon helpers on X/Z
local function area(poly)
	local a = 0
	for i = 1, #poly do
		local p, q = poly[i], poly[i % #poly + 1]
		a += p.X * q.Z - q.X * p.Z
	end
	return a / 2
end

local function ccw(poly)
	if area(poly) < 0 then
		local r = {}
		for i = #poly, 1, -1 do
			table.insert(r, poly[i])
		end
		return r
	end
	return poly
end

local function clip(subject, clipper)
	local out = subject
	for i = 1, #clipper do
		local a, b = clipper[i], clipper[i % #clipper + 1]
		local input = out
		out = {}
		if #input == 0 then
			break
		end
		local function inside(p)
			return (b.X - a.X) * (p.Z - a.Z) - (b.Z - a.Z) * (p.X - a.X) >= 0
		end
		local function cross(p, q)
			local x1, z1, x2, z2 = a.X, a.Z, b.X, b.Z
			local x3, z3, x4, z4 = p.X, p.Z, q.X, q.Z
			local den = (x1 - x2) * (z3 - z4) - (z1 - z2) * (x3 - x4)
			if math.abs(den) < 1e-9 then
				return p
			end
			local t = ((x1 - x3) * (z3 - z4) - (z1 - z3) * (x3 - x4)) / den
			return Vector3.new(x1 + t * (x2 - x1), 0, z1 + t * (z2 - z1))
		end
		local prev = input[#input]
		for _, cur in input do
			if inside(cur) then
				if not inside(prev) then
					table.insert(out, cross(prev, cur))
				end
				table.insert(out, cur)
			elseif inside(prev) then
				table.insert(out, cross(prev, cur))
			end
			prev = cur
		end
	end
	return out
end

function ZFight.Run(roots, limit)
	roots = roots or { workspace.Map }
	local items = {}
	for _, root in roots do
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				local poly, y = topPoly(d)
				if poly then
					local flat = {}
					local x1, z1, x2, z2 = math.huge, math.huge, -math.huge, -math.huge
					for _, p in poly do
						table.insert(flat, Vector3.new(p.X, 0, p.Z))
						x1, z1 = math.min(x1, p.X), math.min(z1, p.Z)
						x2, z2 = math.max(x2, p.X), math.max(z2, p.Z)
					end
					table.insert(items, { part = d, poly = ccw(flat), y = y, x1 = x1, z1 = z1, x2 = x2, z2 = z2 })
				end
			end
		end
	end
	-- spatial hash
	local grid = {}
	for idx, it in items do
		for i = math.floor(it.x1 / CELL), math.floor(it.x2 / CELL) do
			for j = math.floor(it.z1 / CELL), math.floor(it.z2 / CELL) do
				local key = i .. "," .. j
				local list = grid[key]
				if not list then
					list = {}
					grid[key] = list
				end
				table.insert(list, idx)
			end
		end
	end
	local seen = {}
	local byPair = {}
	local total = 0
	for _, list in grid do
		for a = 1, #list do
			local A = items[list[a]]
			for c = a + 1, #list do
				local ia, ib = list[a], list[c]
				local B = items[ib]
				if math.abs(A.y - B.y) < TOL and A.x1 < B.x2 and B.x1 < A.x2 and A.z1 < B.z2 and B.z1 < A.z2 then
					local key = math.min(ia, ib) .. ":" .. math.max(ia, ib)
					if not seen[key] then
						seen[key] = true
						local ov = clip(A.poly, B.poly)
						local ar = #ov >= 3 and math.abs(area(ov)) or 0
						if ar > MIN_AREA then
							total += 1
							local n1, n2 = A.part.Name, B.part.Name
							if n1 > n2 then
								n1, n2 = n2, n1
							end
							local pk = n1 .. " x " .. n2
							local e = byPair[pk]
							if not e then
								e = { n = 0, area = 0, at = {} }
								byPair[pk] = e
							end
							e.n += 1
							e.area += ar
							if #e.at < 3 then
								local p = A.part.Position
								table.insert(e.at, string.format("(%d,%d,%d) %s", p.X, A.y, p.Z, A.part.Parent and A.part.Parent.Name or "?"))
							end
						end
					end
				end
			end
		end
	end
	local rows = {}
	for k, e in byPair do
		table.insert(rows, { k = k, e = e })
	end
	table.sort(rows, function(a, b)
		return a.e.area > b.e.area
	end)
	local out = { string.format("%d flat tops checked, %d overlapping coplanar pairs", #items, total) }
	for i, r in rows do
		if i > (limit or 30) then
			break
		end
		table.insert(out, string.format("%5d pairs %8.1f st2  %s   e.g. %s", r.e.n, r.e.area, r.k, table.concat(r.e.at, "; ")))
	end
	return table.concat(out, "\n")
end

return ZFight

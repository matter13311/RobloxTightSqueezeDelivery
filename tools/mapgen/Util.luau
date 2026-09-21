-- Shared helpers for the city generator: part factory, rectangle maths, and a
-- seeded RNG so a rebuild with the same Layout produces the same city.
--
-- Rectangles are { x1, z1, x2, z2 } tables with x1 < x2 and z1 < z2 (world
-- studs, ground top at Y = 0, north = -Z).

local U = {}

U.Seed = 20260921
U.rng = Random.new(U.Seed)

function U.reseed(seed)
	U.rng = Random.new(seed or U.Seed)
end

function U.pick(list)
	return list[U.rng:NextInteger(1, #list)]
end

function U.range(a, b)
	return U.rng:NextNumber(a, b)
end

function U.int(a, b)
	return U.rng:NextInteger(a, b)
end

function U.chance(p)
	return U.rng:NextNumber() < p
end

--=============================================================================
-- Rectangles
--=============================================================================

function U.rect(x1, z1, x2, z2)
	return {
		x1 = math.min(x1, x2),
		z1 = math.min(z1, z2),
		x2 = math.max(x1, x2),
		z2 = math.max(z1, z2),
	}
end

function U.expand(r, dx, dz)
	dz = dz or dx
	return U.rect(r.x1 - dx, r.z1 - dz, r.x2 + dx, r.z2 + dz)
end

function U.overlaps(a, b)
	return a.x1 < b.x2 and b.x1 < a.x2 and a.z1 < b.z2 and b.z1 < a.z2
end

function U.contains(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

function U.width(r)
	return r.x2 - r.x1
end

function U.depth(r)
	return r.z2 - r.z1
end

function U.center(r)
	return (r.x1 + r.x2) / 2, (r.z1 + r.z2) / 2
end

-- a minus b, as up to four non-overlapping rectangles (a strip either side in
-- Z across a's full width, then the leftovers in X).
function U.subtract(a, b)
	if not U.overlaps(a, b) then
		return { a }
	end
	local out = {}
	if b.z1 > a.z1 then
		table.insert(out, U.rect(a.x1, a.z1, a.x2, b.z1))
	end
	if b.z2 < a.z2 then
		table.insert(out, U.rect(a.x1, b.z2, a.x2, a.z2))
	end
	local zlo, zhi = math.max(a.z1, b.z1), math.min(a.z2, b.z2)
	if b.x1 > a.x1 then
		table.insert(out, U.rect(a.x1, zlo, b.x1, zhi))
	end
	if b.x2 < a.x2 then
		table.insert(out, U.rect(b.x2, zlo, a.x2, zhi))
	end
	return out
end

function U.subtractAll(rects, holes, minSize)
	minSize = minSize or 0.5
	local current = rects
	for _, hole in holes do
		local nextList = {}
		for _, r in current do
			for _, piece in U.subtract(r, hole) do
				if U.width(piece) >= minSize and U.depth(piece) >= minSize then
					table.insert(nextList, piece)
				end
			end
		end
		current = nextList
	end
	return current
end

--=============================================================================
-- Parts
--=============================================================================

local DEFAULTS = {
	Anchored = true,
	CanCollide = true,
	CanTouch = true,
	CastShadow = true,
	TopSurface = Enum.SurfaceType.Smooth,
	BottomSurface = Enum.SurfaceType.Smooth,
	Material = Enum.Material.Concrete,
	Color = Color3.fromRGB(128, 128, 128),
}

function U.part(parent, name, size, cframe, props)
	local p = Instance.new(props and props.ClassName or "Part")
	for k, v in DEFAULTS do
		p[k] = v
	end
	if props then
		for k, v in props do
			if k ~= "ClassName" then
				p[k] = v
			end
		end
	end
	-- The crash detector listens for Touched, so anything solid must also
	-- be touchable (see memory/map notes). Non-colliding decoration stays
	-- untouchable so it never fires a crash.
	p.CanTouch = p.CanCollide
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Parent = parent
	return p
end

-- An axis-aligned box spanning rect r from y1 to y2. Splits anything longer
-- than Roblox's 2048 stud part limit into equal pieces.
function U.box(parent, name, r, y1, y2, props)
	local MAX = 2000
	local w, d = U.width(r), U.depth(r)
	local nx, nz = math.ceil(w / MAX), math.ceil(d / MAX)
	local parts = {}
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local x1 = r.x1 + w * i / nx
			local x2 = r.x1 + w * (i + 1) / nx
			local z1 = r.z1 + d * j / nz
			local z2 = r.z1 + d * (j + 1) / nz
			local size = Vector3.new(x2 - x1, y2 - y1, z2 - z1)
			local cf = CFrame.new((x1 + x2) / 2, (y1 + y2) / 2, (z1 + z2) / 2)
			table.insert(parts, U.part(parent, name, size, cf, props))
		end
	end
	return parts[1], parts
end

function U.folder(parent, name)
	local f = parent:FindFirstChild(name)
	if f then
		return f
	end
	f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

function U.model(parent, name)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- A SurfaceGui text panel on one face of a part.
function U.label(part, face, text, props)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = (props and props.PixelsPerStud) or 30
	gui.LightInfluence = 0.3
	gui.Parent = part
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromScale(1, 1)
	l.BackgroundTransparency = 1
	l.Font = (props and props.Font) or Enum.Font.GothamBlack
	l.TextScaled = true
	l.TextColor3 = (props and props.TextColor3) or Color3.new(1, 1, 1)
	l.Text = text
	l.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.04, 0)
	pad.PaddingRight = UDim.new(0.04, 0)
	pad.PaddingTop = UDim.new(0.1, 0)
	pad.PaddingBottom = UDim.new(0.1, 0)
	pad.Parent = l
	return gui
end

-- Clone a template (Model or BasePart) so its bounding box sits with its
-- bottom at `y`, centred on (x, z), facing `look` (a horizontal unit vector
-- the template's -Z should point along). Returns the clone.
function U.place(template, parent, x, y, z, look)
	local c = template:Clone()
	local rot = CFrame.lookAt(Vector3.zero, look or Vector3.new(0, 0, -1))
	if c:IsA("Model") then
		-- The pivot's orientation is replaced outright: templates are authored
		-- with their "front" on the pivot's -Z.
		c:PivotTo(CFrame.new(x, 0, z) * rot)
		local cf, sz = c:GetBoundingBox()
		c:PivotTo(c:GetPivot() + Vector3.new(0, y + sz.Y / 2 - cf.Y, 0))
	else
		c.CFrame = CFrame.new(x, y + c.Size.Y / 2, z) * rot
	end
	for _, d in (c:IsA("Model") and c:GetDescendants() or { c }) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanTouch = d.CanCollide
		end
	end
	c.Parent = parent
	return c
end

--=============================================================================
-- Oriented parts, triangles, ribbons, wires
--=============================================================================

-- A box between two points on the ground plane (y1..y2), `width` wide,
-- lengthened by `extra` at both ends so curved runs have no gaps at the joins.
function U.segment(parent, name, a, b, width, y1, y2, props, extra)
	local d = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local len = d.Magnitude
	if len < 0.05 then
		return nil
	end
	local mid = Vector3.new((a.X + b.X) / 2, (y1 + y2) / 2, (a.Z + b.Z) / 2)
	local cf = CFrame.lookAt(mid, mid + d)
	return U.part(parent, name, Vector3.new(width, y2 - y1, len + 2 * (extra or 0)), cf, props)
end

-- A right-triangle prism in plan (for filling the corners an angled alley
-- leaves between square buildings). `r` = the right-angle corner (x, z),
-- `u` and `v` = the two legs as horizontal Vector3s. Height y1..y2.
function U.triangle(parent, name, r, u, v, y1, y2, props)
	local lu, lv = u.Magnitude, v.Magnitude
	if lu < 0.2 or lv < 0.2 then
		return nil
	end
	-- WedgePart: right angle at local (Y = -h, Z = +d); legs run to +Y and -Z.
	-- Map local Y -> leg u, local -Z -> leg v, local X -> world up.
	local Y, Z = u.Unit, -v.Unit
	local X = Y:Cross(Z)
	local sizeY, sizeZ = lu, lv
	if X.Y < 0 then
		Y, Z = v.Unit, -u.Unit
		X = Y:Cross(Z)
		sizeY, sizeZ = lv, lu
	end
	local centre = Vector3.new(r.X, (y1 + y2) / 2, r.Z) + (u + v) / 2
	local cf = CFrame.fromMatrix(centre, X, Y, Z)
	local pr = table.clone(props or {})
	pr.ClassName = "WedgePart"
	return U.part(parent, name, Vector3.new(y2 - y1, sizeY, sizeZ), cf, pr)
end

-- An exact triangle a-b-c (any orientation in 3D) as two WedgeParts, `thick`
-- studs deep on the side AWAY from its upward normal - so its top face is the
-- triangle itself. Curved roads, pavements and decks are tiled from these:
-- neighbouring triangles share edges and never overlap, so nothing z-fights.
function U.tri(parent, name, a, b, c, thick, props)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab)
	if right.Magnitude < 1e-3 then
		return
	end
	right = right.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	local d0, d1 = math.abs(ab:Dot(back)), math.abs(ac:Dot(back))
	if height < 0.01 then
		return
	end
	local n = right.Y >= 0 and right or -right
	local off = -n * (thick / 2)
	local pr = table.clone(props or {})
	pr.ClassName = "WedgePart"
	if d0 > 0.01 then
		U.part(parent, name, Vector3.new(thick, height, d0), CFrame.fromMatrix((a + b) / 2 + off, right, up, back), pr)
	end
	if d1 > 0.01 then
		U.part(parent, name, Vector3.new(thick, height, d1), CFrame.fromMatrix((a + c) / 2 + off, -right, up, -back), pr)
	end
end

-- Quad p1-p2-p3-p4 (in order round its edge) as two triangles.
function U.quad(parent, name, p1, p2, p3, p4, thick, props)
	U.tri(parent, name, p1, p2, p3, thick, props)
	U.tri(parent, name, p1, p3, p4, thick, props)
end

-- A wall along a polyline of base points (y = foot of the wall, may slope),
-- one box per span. Each box is lengthened only by what closes the outside
-- corner of its bend, so straight runs abut exactly (no coplanar overlap to
-- flicker) and bends have no gaps.
function U.wallRun(parent, name, pts, thick, height, props)
	local function flatDir(i)
		local d = pts[i + 1] - pts[i]
		return Vector3.new(d.X, 0, d.Z)
	end
	local function extraAt(i)
		-- extra at joint i (between span i-1 and span i)
		if i <= 1 or i >= #pts then
			return 0
		end
		local d0, d1 = flatDir(i - 1), flatDir(i)
		if d0.Magnitude < 0.05 or d1.Magnitude < 0.05 then
			return 0
		end
		local cos = math.clamp(d0.Unit:Dot(d1.Unit), -1, 1)
		local theta = math.acos(cos)
		if theta < 0.004 then
			return 0
		end
		return math.min(thick, (thick / 2) * math.tan(theta / 2))
	end
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local d = b - a
		if d.Magnitude < 0.05 then
			continue
		end
		local e0, e1 = extraAt(i), extraAt(i + 1)
		local u = d.Unit
		local a2, b2 = a - u * e0, b + u * e1
		local mid = (a2 + b2) / 2
		-- alternate spans differ in height by a hair, so the tops that
		-- overlap on the inside of a bend are never in the same plane
		local h = height + (i % 2) * 0.05
		local cf = CFrame.lookAt(mid, mid + u) * CFrame.new(0, h / 2, 0)
		U.part(parent, name, Vector3.new(thick, h, (b2 - a2).Magnitude), cf, props)
	end
end

-- Wedge-shaped slab rising from `low` to `high` (points on the centre line,
-- y = top of each end), `width` wide. Used for the express ramps.
function U.ramp(parent, name, low, high, width, props)
	local run = Vector3.new(high.X - low.X, 0, high.Z - low.Z)
	local rise = high.Y - low.Y
	local mid = Vector3.new((low.X + high.X) / 2, low.Y + rise / 2, (low.Z + high.Z) / 2)
	-- WedgePart is tall at +Z (back) and low at -Z (front = LookVector)
	local cf = CFrame.lookAt(mid, mid - run)
	local w = Instance.new("WedgePart")
	for k, v in props or {} do
		w[k] = v
	end
	w.Anchored = true
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.CanTouch = w.CanCollide
	w.Name = name
	w.Size = Vector3.new(width, rise, run.Magnitude)
	w.CFrame = cf
	w.Parent = parent
	return w
end

-- A sagging wire (Beam) between two world points, hung off two invisible
-- anchor parts. Beams cost no physics and no collision.
function U.wire(parent, a, b, color, width, sag)
	local holder = Instance.new("Part")
	holder.Name = "WireHolder"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanTouch = false
	holder.CanQuery = false
	holder.Transparency = 1
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	holder.CFrame = CFrame.new(a)
	holder.Parent = parent
	local a0 = Instance.new("Attachment")
	a0.Parent = holder
	local a1 = Instance.new("Attachment")
	a1.Parent = holder
	a1.WorldPosition = b
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = width or 0.16
	beam.Width1 = width or 0.16
	beam.Color = ColorSequence.new(color or Color3.fromRGB(20, 20, 20))
	beam.LightInfluence = 1
	beam.Segments = 10
	beam.CurveSize0 = -(sag or 2)
	beam.CurveSize1 = sag or 2
	beam.FaceCamera = true
	beam.Parent = holder
	return holder
end

-- A decal on a thin invisible carrier standing just off a wall. `normal` is
-- the direction the decal faces (out of the wall).
function U.wallDecal(parent, name, pos, normal, w, h, texture)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(w, h, 0.05)
	p.CFrame = CFrame.lookAt(pos, pos + normal)
	p.Parent = parent
	local d = Instance.new("Decal")
	d.Texture = texture
	d.Face = Enum.NormalId.Front
	d.Parent = p
	return p
end

-- Hermite curve sampled into `n` + 1 points (inclusive).
function U.hermite(p0, d0, p1, d1, n, k0, k1)
	local chord = (p1 - p0).Magnitude
	local m0 = d0.Unit * chord * (k0 or 1)
	local m1 = d1.Unit * chord * (k1 or 1)
	local pts = {}
	for i = 0, n do
		local t = i / n
		local t2, t3 = t * t, t * t * t
		local h00 = 2 * t3 - 3 * t2 + 1
		local h10 = t3 - 2 * t2 + t
		local h01 = -2 * t3 + 3 * t2
		local h11 = t3 - t2
		table.insert(pts, p0 * h00 + m0 * h10 + p1 * h01 + m1 * h11)
	end
	return pts
end

return U

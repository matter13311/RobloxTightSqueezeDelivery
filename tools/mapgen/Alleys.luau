-- Alley dressing. Every alley run ("leg") gets:
--
--   * clutter BANDS along its walls, sized so a constant channel stays clear
--     down the middle (props never zig-zag the channel - a 20-40 stud truck
--     cannot weave between props on alternating sides);
--   * wall details: back doors, drainpipes, posters, graffiti, AC units, fire
--     escapes, balconies, neon signs;
--   * overhead: sagging wires, laundry lines, lantern strings, nets;
--   * litter that nothing collides with;
--   * parked cars in the wide ones.
--
-- What goes where comes from the alley's Theme (Style.AlleyThemes).
--
-- Channel widths (w = wall to wall):
--   w <= 16  no solid clutter at all (the walls are the challenge)
--   16..24   a band each side of (w - 14) / 2, 0..5 deep
--   >= 26    market themes: a band each side; otherwise a parked-car band (9)
--            on one side and the rest on the other.

local U = require(script.Parent.Util)
local Style = require(script.Parent.Style)
local Props = require(script.Parent.Props)

local Alleys = {}

local CHANNEL = 14
local CAR_BAND = 9

local function bands(w, theme)
	if w < 16 then
		return 0, 0, false
	end
	if w < 26 then
		local b = math.max(0, (w - CHANNEL) / 2)
		return b, b, false
	end
	if theme == "noodle" or theme == "market" then
		local b = (w - CHANNEL) / 2
		return b, b, false
	end
	return CAR_BAND, math.max(0, w - CHANNEL - CAR_BAND), true
end

local function blocked(x, z, avoid, pad)
	for _, r in avoid do
		if x > r.x1 - pad and x < r.x2 + pad and z > r.z1 - pad and z < r.z2 + pad then
			return true
		end
	end
	return false
end

local function inTri(q, t)
	local function side(a, b)
		return (b.X - a.X) * (q.Z - a.Z) - (b.Z - a.Z) * (q.X - a.X)
	end
	local d1, d2, d3 = side(t[1], t[2]), side(t[2], t[3]), side(t[3], t[1])
	local neg = d1 < 0 or d2 < 0 or d3 < 0
	local pos = d1 > 0 or d2 > 0 or d3 > 0
	return not (neg and pos)
end

-- Height of the building wall behind wall point `p` (normal = out of the
-- wall), checked at the middle and at +-half along it; 0 if any of those has
-- no building behind it (a driveway, an alley mouth, a destination's yard).
local function wallHeight(ctx, p, normal, along, half)
	local reg = ctx.walls
	if not reg then
		return 999
	end
	local lowest = math.huge
	for _, o in { -half, 0, half } do
		local q = p - normal * 0.8 + along * o
		local best = 0
		for _, w in reg do
			if w.h > best then
				local r = w.rect
				if r then
					if q.X > r.x1 and q.X < r.x2 and q.Z > r.z1 and q.Z < r.z2 then
						best = w.h
					end
				elseif inTri(q, w.tri) then
					best = w.h
				end
			end
		end
		lowest = math.min(lowest, best)
		if lowest == 0 then
			return 0
		end
	end
	return lowest
end

-- Zone's alley-mouth kit hangs things on the same walls.
Alleys.WallHeight = wallHeight

-- One straight leg. `leg` = { rect, alongZ (bool), w, theme, zoneStyle }
function Alleys.DressLeg(folder, kit, leg, avoid, ctx)
	local r = leg.rect
	local theme = Style.AlleyThemes[leg.theme] or Style.AlleyThemes.garbage
	local w = leg.w
	local bandA, bandB, carsOnA = bands(w, leg.theme)
	local alongZ = leg.alongZ
	local a1, a2 = alongZ and r.z1 or r.x1, alongZ and r.z2 or r.x2
	-- the two walls: position on the cross axis, and the normal into the alley
	local walls = {
		{ at = alongZ and r.x1 or r.z1, normal = alongZ and Vector3.new(1, 0, 0) or Vector3.new(0, 0, 1), band = bandA, cars = carsOnA },
		{ at = alongZ and r.x2 or r.z2, normal = alongZ and Vector3.new(-1, 0, 0) or Vector3.new(0, 0, -1), band = bandB, cars = false },
	}
	if U.chance(0.5) and carsOnA then
		-- put the cars on the other side sometimes
		walls[1].band, walls[2].band = bandB, bandA
		walls[1].cars, walls[2].cars = false, true
	end
	local function wallCF(wall, along)
		local p
		if alongZ then
			p = Vector3.new(wall.at, 0, along)
		else
			p = Vector3.new(along, 0, wall.at)
		end
		return CFrame.lookAt(p, p + wall.normal), p
	end

	local length = a2 - a1
	if length < 12 then
		return
	end

	for wi, wall in walls do
		-- ground clutter / parked cars
		local pos = a1 + U.range(6, 14)
		while pos < a2 - 6 do
			local cf, p = wallCF(wall, pos)
			local probe = p + wall.normal * 3
			if not blocked(probe.X, probe.Z, avoid, 6) then
				if wall.cars then
					if U.chance(0.7) and #kit.Cars:GetChildren() > 0 then
						local car = U.pick(kit.Cars:GetChildren())
						local c = p + wall.normal * (CAR_BAND / 2)
						local dir = alongZ and Vector3.new(0, 0, U.chance(0.5) and 1 or -1) or Vector3.new(U.chance(0.5) and 1 or -1, 0, 0)
						U.place(car, folder, c.X, 0, c.Z, dir)
					end
					pos += U.range(24, 30)
					continue
				elseif wall.band >= 2.8 and #theme.props > 0 and U.chance(0.75) then
					local name = U.pick(theme.props)
					local ok = Props[name] and Props[name](folder, kit, cf, wall.band - 0.3)
					if not ok then
						Props.Bags(folder, kit, cf, wall.band)
					end
				elseif U.chance(theme.litter * 0.6) then
					Props.Bags(folder, kit, cf, 0)
				end
			end
			pos += U.range(11, 20)
		end

		-- wall details
		pos = a1 + U.range(4, 12)
		while pos < a2 - 4 do
			local cf, p = wallCF(wall, pos)
			local along = cf.RightVector
			local open = blocked(p.X, p.Z, avoid, 2)
			local function wallFor(half)
				return not open and wallHeight(ctx, p, wall.normal, along, half) or 0
			end
			local roll = U.range(0, 1)
			local low = wallFor(3)
			if low >= 12 then
				if roll < 0.22 then
					Props.Graffiti(folder, cf)
				elseif roll < 0.34 then
					Props.BackDoor(folder, kit, cf)
				elseif roll < 0.44 then
					Props.Poster(folder, cf)
				elseif roll < 0.54 then
					Props.DrainPipe(folder, cf, math.min(26, low))
				end
			end
			-- high stuff, only on a real wall that is tall enough for it
			local high = U.range(0, 1)
			if high < 0.28 then
				if wallFor(2) >= 23 then
					Props.AC(folder, cf)
				end
			elseif high < 0.42 then
				local h = wallFor(6.5)
				if h >= 18 and pos - (wall.lastEscape or -math.huge) > 13 then
					Props.FireEscape(folder, cf, h)
					wall.lastEscape = pos
				end
			elseif high < 0.52 and ctx.balconies then
				local h = wallFor(4.5)
				if h >= 21 then
					Props.Balcony(folder, cf, h)
				end
			elseif high < 0.62 and (leg.theme == "noodle" or leg.theme == "market" or U.chance(0.4)) then
				if wallFor(1) >= 19 then
					Props.Neon(folder, cf, Style.NeonWords[leg.theme] or Style.NeonWords[ctx.zoneKey] or Style.NeonWords.OldTown)
				end
			end
			pos += U.range(9, 18)
			local _ = wi
		end
	end

	-- overhead across the alley, strung between two real walls
	local pos = a1 + U.range(5, 12)
	while pos < a2 - 5 do
		local cfa, pa = wallCF(walls[1], pos)
		local _, pb = wallCF(walls[2], pos + U.range(-4, 4))
		local along = cfa.RightVector
		local top = math.min(wallHeight(ctx, pa, walls[1].normal, along, 0.6), wallHeight(ctx, pb, walls[2].normal, along, 0.6))
		if top >= 17 then
			local kind = U.pick(theme.overhead)
			if kind == "Laundry" then
				Props.Laundry(folder, pa, pb, top)
			elseif kind == "Lanterns" then
				Props.Lanterns(folder, pa, pb, top)
			elseif kind == "Nets" then
				Props.Nets(folder, pa, pb, top)
			else
				Props.Wires(folder, pa, pb, top)
			end
		end
		pos += U.range(14, 26)
	end

	-- litter in the channel (never solid)
	pos = a1 + U.range(3, 8)
	local flats = { "cardboard_unfolded_01", "garbage_carboard001a", "garbage_carboard002a", "Wooden Plank", "garbage_sodacan01a_crushed", "garbage_plasticbottle001a", "garbage_milkcarton001a", "garbage256_composite002a" }
	while pos < a2 - 3 do
		if U.chance(theme.litter) then
			local off = U.range(-w / 2 + 1, w / 2 - 1)
			local x, z
			if alongZ then
				x, z = (r.x1 + r.x2) / 2 + off, pos
			else
				x, z = pos, (r.z1 + r.z2) / 2 + off
			end
			local t = kit.Props:FindFirstChild(U.pick(flats))
			if t then
				local c = U.place(t, folder, x, 0, z, CFrame.Angles(0, U.range(0, 6.28), 0).LookVector)
				for _, d in (c:IsA("Model") and c:GetDescendants() or { c }) do
					if d:IsA("BasePart") then
						d.CanCollide = false
						d.CanTouch = false
						d.CanQuery = false
					end
				end
			end
		end
		pos += U.range(10, 20)
	end

	-- (the paving is laid by Zone, in exact non-overlapping pieces)
end

-- A diagonal leg: only overhead things (nothing on the ground to catch on).
function Alleys.DressDiagonal(folder, _kit, a, b, w, theme, ctx)
	local d = (b - a)
	local n = Vector3.new(-d.Z, 0, d.X).Unit
	local along = d.Unit
	local th = Style.AlleyThemes[theme] or Style.AlleyThemes.garbage
	for _, t in { 0.3, 0.7 } do
		local c = a:Lerp(b, t)
		local pa, pb = c - n * (w / 2), c + n * (w / 2)
		local top = math.min(wallHeight(ctx, pa, n, along, 0.6), wallHeight(ctx, pb, -n, along, 0.6))
		if top >= 17 then
			local kind = U.pick(th.overhead)
			if kind == "Laundry" then
				Props.Laundry(folder, pa, pb, top)
			elseif kind == "Lanterns" then
				Props.Lanterns(folder, pa, pb, top)
			else
				Props.Wires(folder, pa, pb, top)
			end
		end
	end
end

return Alleys

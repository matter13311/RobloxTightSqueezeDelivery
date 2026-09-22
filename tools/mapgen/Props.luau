-- Small composite props, built from primitives (and a few MapKit meshes) so
-- the alleys and streets have character without heavy toolbox models.
--
-- Wall props take `cf`: a CFrame on the wall line at ground level whose
-- LookVector points OUT of the wall (into the alley/street) and whose
-- RightVector runs along the wall. `depth` is how far a SOLID prop may reach
-- out from the wall; anything above ~13 studs (over every vehicle that uses
-- alleys) or flat litter is non-colliding and may reach further.

local U = require(script.Parent.Util)
local Style = require(script.Parent.Style)

local Props = {}

local BLACK = Color3.fromRGB(28, 28, 30)

-- a box at (along, up, out) from the wall frame, size (along, height, out)
local function box(parent, name, cf, along, up, out, size, props)
	local c = cf * CFrame.new(along, up + size.Y / 2, -(out + size.Z / 2))
	return U.part(parent, name, size, c, props)
end

local function flat(props)
	props = props or {}
	props.CanCollide = false
	props.CanQuery = false
	return props
end

local function mesh(parent, kit, name, cf, along, out, depth, collide, yaw)
	local t = kit.Props:FindFirstChild(name)
	if not t then
		return nil
	end
	local size = t:IsA("Model") and select(2, t:GetBoundingBox()) or t.Size
	local thinIsX = size.X <= size.Z
	local d = thinIsX and size.X or size.Z
	if collide ~= false and d > depth then
		return nil
	end
	local p = cf * CFrame.new(along, 0, -(d / 2 + 0.2))
	-- face so the thin side points out of the wall
	local look = thinIsX and cf.RightVector or cf.LookVector
	if yaw then
		look = (CFrame.Angles(0, yaw, 0) * CFrame.new(Vector3.zero, look)).LookVector
	end
	local c = U.place(t, parent, p.X, 0, p.Z, look)
	if collide == false then
		for _, x in (c:IsA("Model") and c:GetDescendants() or { c }) do
			if x:IsA("BasePart") then
				x.CanCollide = false
				x.CanTouch = false
				x.CanQuery = false
			end
		end
	end
	return c, d
end

--=============================================================================
-- Ground props (solid, within `depth`)
--=============================================================================

function Props.Dumpster(parent, kit, cf, depth)
	local c = mesh(parent, kit, U.pick({ "trashdumpster01a", "trashdumpster02a", "trashdumpster02", "dumpster" }), cf, 0, 0, depth, true)
	if c then
		for _ = 1, U.int(1, 3) do
			mesh(parent, kit, "garbage_bag001a", cf, U.range(3, 6) * (U.chance(0.5) and 1 or -1), 0, 99, false, U.range(0, 6))
		end
		return true
	end
	return Props.WheelieBins(parent, kit, cf, depth)
end

function Props.WheelieBins(parent, _kit, cf, depth)
	if depth < 3.2 then
		return false
	end
	local colors = { Color3.fromRGB(40, 90, 50), Color3.fromRGB(60, 60, 64), Color3.fromRGB(40, 70, 130), Color3.fromRGB(120, 80, 40) }
	for i = 0, U.int(1, 3) do
		local col = U.pick(colors)
		box(parent, "WheelieBin", cf, i * 3.3 - 3, 0, 0.1, Vector3.new(2.9, 3.1, 3), { Material = Enum.Material.SmoothPlastic, Color = col })
		box(parent, "WheelieBinLid", cf, i * 3.3 - 3, 3.1, 0, Vector3.new(3, 0.3, 3.3), flat({ Material = Enum.Material.SmoothPlastic, Color = col }))
	end
	return true
end

function Props.Bags(parent, kit, cf, _depth)
	for _ = 1, U.int(1, 3) do
		mesh(parent, kit, U.pick({ "garbage_bag001a", "trashcluster01a_cluster", "garbage_carboard001a" }), cf, U.range(-5, 5), 0, 99, false, U.range(0, 6))
	end
	return true
end

function Props.GarbagePile(parent, kit, cf, depth)
	mesh(parent, kit, U.pick({ "garbage128_composite001a", "garbage128_composite001b", "garbage128_composite001c", "food_pile01" }), cf, 0, 0, 99, false, U.range(-0.3, 0.3))
	Props.Bags(parent, kit, cf, depth)
	return true
end

function Props.Crates(parent, kit, cf, depth)
	if depth < 3.8 then
		return false
	end
	for i = 0, U.int(1, 3) do
		local h = U.int(1, 3)
		for j = 0, h - 1 do
			box(parent, "Crate", cf, i * 3.8 - 3.8, j * 3.4, 0.1, Vector3.new(3.4, 3.4, 3.4), {
				Material = Enum.Material.WoodPlanks, Color = Color3.fromRGB(150, 110, 70),
			})
		end
	end
	return true
end

function Props.Boxes(parent, _kit, cf, depth)
	if depth < 3 then
		return false
	end
	for i = 0, U.int(2, 5) do
		local s = U.range(1.8, 2.9)
		box(parent, "Box", cf, U.range(-5, 5), (i % 2) * 2.2, U.range(0, depth - s), Vector3.new(s, s * 0.8, s), {
			Material = Enum.Material.Cardboard, Color = Color3.fromRGB(150, 118, 80),
			CanCollide = i < 2,
		})
	end
	return true
end

function Props.Pallets(parent, _kit, cf, depth)
	if depth < 5 then
		return false
	end
	local n = U.int(2, 6)
	for j = 0, n - 1 do
		box(parent, "Pallet", cf, U.range(-0.4, 0.4), j * 0.7, 0.1, Vector3.new(6.6, 0.7, 4.6), {
			Material = Enum.Material.WoodPlanks, Color = Color3.fromRGB(160, 124, 80),
		})
	end
	return true
end

function Props.Tires(parent, _kit, cf, depth)
	if depth < 3.4 then
		return false
	end
	for s = 0, U.int(0, 2) do
		local n = U.int(2, 6)
		for j = 0, n - 1 do
			local c = cf * CFrame.new(s * 3.6 - 3.6, 0.5 + j * 1.05, -1.8) * CFrame.Angles(0, 0, math.rad(90))
			U.part(parent, "Tire", Vector3.new(1, 3.2, 3.2), c, {
				Shape = Enum.PartType.Cylinder, Material = Enum.Material.Rubber, Color = BLACK,
			})
		end
	end
	return true
end

function Props.Washers(parent, _kit, cf, depth)
	if depth < 3.5 then
		return false
	end
	box(parent, "OldFridge", cf, -2, 0, 0.1, Vector3.new(3.4, 6.2, 3.2), { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(200, 200, 190) })
	box(parent, "OldWasher", cf, 2, 0, 0.1, Vector3.new(3.2, 3.4, 3.2), { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(170, 170, 170) })
	return true
end

function Props.Couch(parent, _kit, cf, depth)
	if depth < 3.2 then
		return false
	end
	local col = U.pick({ Color3.fromRGB(120, 60, 40), Color3.fromRGB(70, 90, 60), Color3.fromRGB(80, 70, 110) })
	box(parent, "CouchSeat", cf, 0, 0, 0.3, Vector3.new(7, 1.8, 2.6), { Material = Enum.Material.Fabric, Color = col })
	box(parent, "CouchBack", cf, 0, 1.8, 0, Vector3.new(7, 2, 0.8), flat({ Material = Enum.Material.Fabric, Color = col }))
	return true
end

function Props.Mattress(parent, _kit, cf, _depth)
	local c = cf * CFrame.new(U.range(-3, 3), 3.8, -0.9) * CFrame.Angles(math.rad(-12), 0, 0)
	U.part(parent, "Mattress", Vector3.new(4.8, 7.6, 0.8), c, flat({ Material = Enum.Material.Fabric, Color = Color3.fromRGB(215, 205, 180) }))
	return true
end

function Props.Barrels(parent, kit, cf, depth)
	if depth < 2.8 then
		return false
	end
	for i = 0, U.int(1, 3) do
		mesh(parent, kit, "oil_barrel", cf, i * 2.8 - 3, 0, depth, true)
	end
	return true
end

function Props.ScrapPile(parent, kit, cf, depth)
	if depth < 4 then
		return false
	end
	for _ = 1, U.int(3, 6) do
		local c = cf * CFrame.new(U.range(-4, 4), U.range(0.3, 1.5), -U.range(1, depth - 1)) * CFrame.Angles(U.range(-0.4, 0.4), U.range(0, 6), U.range(-0.4, 0.4))
		U.part(parent, "Scrap", Vector3.new(U.range(1, 4), U.range(0.3, 1.2), U.range(1, 3)), c, flat({
			Material = Enum.Material.CorrodedMetal, Color = U.pick({ Color3.fromRGB(120, 70, 40), Color3.fromRGB(90, 90, 92), Color3.fromRGB(140, 90, 50) }),
		}))
	end
	mesh(parent, kit, U.pick({ "beam01b", "beam01d", "metalbucket02a" }), cf, U.range(-2, 2), 0, 99, false)
	return true
end

local FOOD = { Color3.fromRGB(230, 90, 40), Color3.fromRGB(240, 200, 60), Color3.fromRGB(90, 170, 60), Color3.fromRGB(200, 40, 40) }

function Props.FoodCrates(parent, _kit, cf, depth)
	if depth < 3 then
		return false
	end
	for i = 0, U.int(1, 3) do
		local col = U.pick({ Color3.fromRGB(40, 90, 170), Color3.fromRGB(200, 60, 50), Color3.fromRGB(60, 140, 70) })
		box(parent, "PlasticCrate", cf, i * 4.2 - 4, 0, 0.1, Vector3.new(4, 2.4, 2.9), { Material = Enum.Material.Plastic, Color = col })
		box(parent, "Produce", cf, i * 4.2 - 4, 2.4, 0.4, Vector3.new(3.4, 0.6, 2.2), flat({ Material = Enum.Material.Fabric, Color = U.pick(FOOD) }))
	end
	return true
end

function Props.FishCrates(parent, _kit, cf, depth)
	if depth < 3 then
		return false
	end
	for i = 0, U.int(1, 3) do
		for j = 0, U.int(0, 1) do
			box(parent, "FishCrate", cf, i * 3.8 - 3.8, j * 1.6, 0.1, Vector3.new(3.4, 1.6, 2.6), { Material = Enum.Material.Plastic, Color = Color3.fromRGB(50, 110, 170) })
		end
		box(parent, "Ice", cf, i * 3.8 - 3.8, 1.6, 0.4, Vector3.new(2.8, 0.3, 2), flat({ Material = Enum.Material.Ice, Color = Color3.fromRGB(220, 235, 245) }))
		for _ = 1, 2 do
			box(parent, "Fish", cf, i * 3.8 - 3.8 + U.range(-0.8, 0.8), 1.9, U.range(0.6, 1.8), Vector3.new(1.6, 0.35, 0.5), flat({ Material = Enum.Material.SmoothPlastic, Color = U.pick({ Color3.fromRGB(230, 130, 60), Color3.fromRGB(160, 170, 180) }) }))
		end
	end
	return true
end

function Props.RopeCoils(parent, _kit, cf, depth)
	if depth < 3.2 then
		return false
	end
	for i = 0, U.int(1, 2) do
		local c = cf * CFrame.new(i * 3.6 - 2, 0.5, -1.6) * CFrame.Angles(0, 0, math.rad(90))
		U.part(parent, "RopeCoil", Vector3.new(1, 3, 3), c, { Shape = Enum.PartType.Cylinder, Material = Enum.Material.Fabric, Color = Color3.fromRGB(170, 140, 90) })
	end
	return true
end

function Props.Stall(parent, _kit, cf, depth)
	if depth < 4.6 then
		return false
	end
	local awningColor = U.pick({ Color3.fromRGB(190, 30, 30), Color3.fromRGB(220, 160, 30), Color3.fromRGB(30, 110, 60), Color3.fromRGB(200, 70, 30) })
	box(parent, "StallCounter", cf, 0, 0, 0.1, Vector3.new(9, 3.2, 4.4), { Material = Enum.Material.Wood, Color = Color3.fromRGB(130, 80, 45) })
	for _, a in { -4.3, 4.3 } do
		box(parent, "StallPole", cf, a, 0, 4.1, Vector3.new(0.4, 9, 0.4), flat({ Material = Enum.Material.Wood, Color = Color3.fromRGB(110, 70, 40) }))
	end
	local aw = cf * CFrame.new(0, 9.4, -3.2) * CFrame.Angles(math.rad(-10), 0, 0)
	U.part(parent, "StallAwning", Vector3.new(10, 0.3, 6.6), aw, flat({ Material = Enum.Material.Fabric, Color = awningColor }))
	for i = -1, 1 do
		box(parent, "Food", cf, i * 2.8, 3.2, 1, Vector3.new(2.2, 0.8, 1.8), flat({ Material = Enum.Material.SmoothPlastic, Color = U.pick(FOOD) }))
		local l = box(parent, "Lantern", cf, i * 3, 7.6, 5.6, Vector3.new(0.9, 1.1, 0.9), flat({ Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 80, 40) }))
		if i == 0 then
			local pl = Instance.new("PointLight")
			pl.Color = Color3.fromRGB(255, 120, 60)
			pl.Range = 14
			pl.Brightness = 1
			pl.Parent = l
		end
	end
	return true
end

function Props.Puddle(parent, _kit, cf, _depth)
	local c = cf * CFrame.new(U.range(-3, 3), 0.06, -U.range(1.5, 5)) * CFrame.Angles(0, 0, math.rad(90))
	U.part(parent, "Puddle", Vector3.new(0.1, U.range(4, 8), U.range(3, 7)), c, flat({
		Shape = Enum.PartType.Cylinder, Material = Enum.Material.Glass, Color = Color3.fromRGB(60, 80, 95), Transparency = 0.35, Reflectance = 0.25, CastShadow = false,
	}))
	return true
end

function Props.Rats(parent, _kit, cf, _depth)
	for _ = 1, U.int(2, 4) do
		local c = cf * CFrame.new(U.range(-4, 4), 0.35, -U.range(0.4, 2)) * CFrame.Angles(0, U.range(0, 6.28), 0)
		U.part(parent, "Rat", Vector3.new(0.5, 0.5, 1.2), c, flat({ Material = Enum.Material.Fabric, Color = Color3.fromRGB(80, 74, 70) }))
	end
	return Props.Bags(parent, _kit, cf, _depth)
end

function Props.Pigeons(parent, _kit, cf, _depth)
	for _ = 1, U.int(3, 7) do
		local c = cf * CFrame.new(U.range(-5, 5), 0.45, -U.range(0.5, 4)) * CFrame.Angles(0, U.range(0, 6.28), 0)
		U.part(parent, "Pigeon", Vector3.new(0.6, 0.7, 1), c, flat({ Material = Enum.Material.SmoothPlastic, Color = U.pick({ Color3.fromRGB(120, 124, 130), Color3.fromRGB(90, 94, 100), Color3.fromRGB(200, 200, 200) }) }))
	end
	return true
end

function Props.Cans(parent, _kit, cf, _depth)
	for _ = 1, U.int(4, 9) do
		local c = cf * CFrame.new(U.range(-5, 5), 0.3, -U.range(0.3, 3)) * CFrame.Angles(0, U.range(0, 6.28), math.rad(90))
		U.part(parent, "Can", Vector3.new(1, 0.55, 0.55), c, flat({ Shape = Enum.PartType.Cylinder, Material = Enum.Material.Metal, Color = U.pick(Style.NeonColors) }))
	end
	return true
end

--=============================================================================
-- Wall-mounted (flush, non-colliding)
--=============================================================================

function Props.BackDoor(parent, _kit, cf)
	box(parent, "BackDoorFrame", cf, 0, 0, 0, Vector3.new(5.2, 9, 0.5), flat({ Material = Enum.Material.Metal, Color = Color3.fromRGB(90, 70, 50) }))
	box(parent, "BackDoor", cf, 0, 0, 0.2, Vector3.new(4.2, 8.3, 0.5), flat({ Material = Enum.Material.Metal, Color = U.pick({ Color3.fromRGB(80, 76, 70), Color3.fromRGB(110, 40, 30), Color3.fromRGB(40, 70, 90) }) }))
	box(parent, "DoorLamp", cf, 0, 9.6, 0.2, Vector3.new(1, 0.6, 0.8), flat({ Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 210, 150) }))
end

function Props.Graffiti(parent, cf, y)
	local w = U.range(7, 13)
	local p = cf * CFrame.new(U.range(-2, 2), y or U.range(4, 6), -0.12)
	return U.wallDecal(parent, "Graffiti", p.Position, cf.LookVector, w, w * U.range(0.55, 0.75), U.pick(Style.Graffiti))
end

function Props.Poster(parent, cf)
	local p = cf * CFrame.new(U.range(-2, 2), 5, -0.12)
	return U.wallDecal(parent, "Poster", p.Position, cf.LookVector, 3, 4, U.pick(Style.Posters))
end

function Props.DrainPipe(parent, cf, height)
	box(parent, "DrainPipe", cf, U.range(-3, 3), 0, 0.1, Vector3.new(0.7, height, 0.7), flat({ Material = Enum.Material.CorrodedMetal, Color = Color3.fromRGB(70, 70, 72) }))
end

function Props.AC(parent, cf)
	local y = U.range(13, 20)
	box(parent, "ACUnit", cf, U.range(-3, 3), y, 0, Vector3.new(3.2, 2.4, 2.4), flat({ Material = Enum.Material.Metal, Color = Color3.fromRGB(170, 172, 175) }))
end

function Props.FireEscape(parent, cf, top)
	-- every level (rail included) stays below the roof line
	local levels = math.clamp(math.floor((top - 17) / 9) + 1, 1, 3)
	for i = 0, levels - 1 do
		local y = 13 + i * 9
		box(parent, "FireEscape", cf, 0, y, 0, Vector3.new(12, 0.4, 3.6), flat({ Material = Enum.Material.DiamondPlate, Color = BLACK }))
		box(parent, "FireEscapeRail", cf, 0, y + 0.4, 3.4, Vector3.new(12, 3, 0.2), flat({ Material = Enum.Material.Metal, Color = BLACK, Transparency = 0.3 }))
		if i < levels - 1 then
			box(parent, "FireEscapeLadder", cf, 5, y + 0.4, 1.8, Vector3.new(1.6, 8.9, 0.2), flat({ Material = Enum.Material.Metal, Color = BLACK, Transparency = 0.2 }))
		end
	end
end

-- `bottom` = lowest balcony floor (default 14); raised over a shopfront module,
-- whose cornice reaches ~15.3 and would otherwise sit inside the first slab.
function Props.Balcony(parent, cf, top, bottom)
	local y = bottom or 14
	while y < top - 6 do
		box(parent, "Balcony", cf, 0, y, 0, Vector3.new(8, 0.5, 3), flat({ Material = Enum.Material.Concrete, Color = Color3.fromRGB(190, 185, 175) }))
		box(parent, "BalconyRail", cf, 0, y + 0.5, 2.8, Vector3.new(8, 3, 0.2), flat({ Material = Enum.Material.Metal, Color = BLACK, Transparency = 0.2 }))
		if U.chance(0.4) then
			box(parent, "Plant", cf, U.range(-3, 3), y + 0.5, 1, Vector3.new(1.4, 1.6, 1.4), flat({ Material = Enum.Material.Grass, Color = Color3.fromRGB(70, 120, 50) }))
		end
		y += 10
	end
end

function Props.Neon(parent, cf, words)
	local word = U.pick(words or Style.NeonWords.OldTown)
	local color = U.pick(Style.NeonColors)
	local y = U.range(12, 16)
	box(parent, "NeonBracket", cf, 0, y + 2.3, 0, Vector3.new(0.3, 0.3, 4.2), flat({ Material = Enum.Material.Metal, Color = BLACK }))
	local board = box(parent, "NeonSignBoard", cf, 0, y, 1.5, Vector3.new(0.4, 2.4, #word * 1 + 2), flat({ Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(20, 20, 24) }))
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		local g = U.label(board, face, word, { PixelsPerStud = 30, Font = Enum.Font.FredokaOne, TextColor3 = color })
		g.LightInfluence = 0
		g.Brightness = 2
	end
end

--=============================================================================
-- Overhead (across an alley, between two wall points)
--=============================================================================

-- `top` = the lower of the two wall heights: nothing is strung above a roof.
function Props.Wires(parent, a, b, top)
	local y = math.min(U.range(15, 24), (top or 99) - 4)
	U.wire(parent, a + Vector3.new(0, y, 0), b + Vector3.new(0, y + U.range(-2, 2), 0), Color3.fromRGB(20, 20, 20), 0.16, U.range(1, 3))
	if U.chance(0.5) then
		U.wire(parent, a + Vector3.new(0, y + 1.5, 0), b + Vector3.new(0, y + 1, 0), Color3.fromRGB(20, 20, 20), 0.12, U.range(1, 3))
	end
end

local CLOTH = { Color3.fromRGB(220, 60, 60), Color3.fromRGB(240, 240, 235), Color3.fromRGB(60, 110, 190), Color3.fromRGB(240, 200, 60), Color3.fromRGB(90, 160, 90), Color3.fromRGB(230, 130, 180) }

function Props.Laundry(parent, a, b, top)
	local y = math.min(U.range(15, 21), (top or 99) - 1.5)
	local pa, pb = a + Vector3.new(0, y, 0), b + Vector3.new(0, y, 0)
	U.wire(parent, pa, pb, Color3.fromRGB(230, 230, 225), 0.08, 1)
	local n = math.floor((pb - pa).Magnitude / 3)
	for i = 1, n - 1 do
		if U.chance(0.7) then
			local t = i / n
			local p = pa:Lerp(pb, t) - Vector3.new(0, 1.3 + math.sin(t * math.pi) * 1, 0)
			local h = U.range(1.6, 3)
			U.part(parent, "Laundry", Vector3.new(U.range(1.4, 2.4), h, 0.1), CFrame.lookAt(p, p + (pb - pa):Cross(Vector3.yAxis)), flat({
				Material = Enum.Material.Fabric, Color = U.pick(CLOTH), CastShadow = false,
			}))
		end
	end
end

function Props.Lanterns(parent, a, b, top)
	local y = math.min(U.range(14, 18), (top or 99) - 1.5)
	local pa, pb = a + Vector3.new(0, y, 0), b + Vector3.new(0, y, 0)
	U.wire(parent, pa, pb, Color3.fromRGB(40, 20, 20), 0.1, 1.5)
	local n = math.floor((pb - pa).Magnitude / 3.5)
	for i = 1, n - 1 do
		local t = i / n
		local p = pa:Lerp(pb, t) - Vector3.new(0, 1.2 + math.sin(t * math.pi) * 1.5, 0)
		local l = U.part(parent, "Lantern", Vector3.new(1.2, 1.5, 1.2), CFrame.new(p), flat({
			Material = Enum.Material.Neon, Color = U.pick({ Color3.fromRGB(255, 60, 40), Color3.fromRGB(255, 150, 40) }), Shape = Enum.PartType.Ball, CastShadow = false,
		}))
		local _ = l
	end
end

-- Warm festoon bulbs, the kind a café strings across its yard - hung across
-- an alley mouth so the gap in the frontage glows (see Zone's mouth kit).
function Props.Festoon(parent, a, b, top)
	local y = math.min(15, (top or 99) - 1.5)
	local pa, pb = a + Vector3.new(0, y, 0), b + Vector3.new(0, y + U.range(-0.6, 0.6), 0)
	local sag = 1.4
	U.wire(parent, pa, pb, Color3.fromRGB(30, 26, 22), 0.08, sag)
	local n = math.max(2, math.floor((pb - pa).Magnitude / 2.2))
	for i = 1, n - 1 do
		local t = i / n
		local p = pa:Lerp(pb, t) - Vector3.new(0, 0.45 + math.sin(t * math.pi) * sag, 0)
		U.part(parent, "FestoonBulb", Vector3.new(0.55, 0.7, 0.55), CFrame.new(p), flat({
			Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 205, 130), Shape = Enum.PartType.Ball, CastShadow = false,
		}))
	end
end

function Props.Nets(parent, a, b, top)
	local y = math.min(U.range(12, 16), (top or 99) - 1.5)
	local pa = a + Vector3.new(0, y, 0)
	local pb = b + Vector3.new(0, y, 0)
	U.wire(parent, pa, pb, Color3.fromRGB(150, 130, 90), 0.12, 2)
	for _ = 1, U.int(2, 4) do
		local p = pa:Lerp(pb, U.range(0.2, 0.8)) - Vector3.new(0, 2.2, 0)
		U.part(parent, "Float", Vector3.new(0.9, 0.9, 0.9), CFrame.new(p), flat({ Shape = Enum.PartType.Ball, Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(230, 120, 40) }))
	end
end

return Props

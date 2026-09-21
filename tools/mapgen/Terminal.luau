-- The Terminal (Old Town frame = world): where every player starts.
--
--   * One row of 16 open WORKSHOPS facing north onto the yard - not cubby
--     holes: each bay is a lit floor area with a workbench, tool chest, tyre
--     stack and pegboard, separated from its neighbours by roof posts and a
--     low half-wall at the back. The kiosk stands at the FRONT-RIGHT corner
--     inside its own bay's painted outline, under that bay's number, so it
--     is obvious which garage it claims. (It sits just outside the plot's
--     CollisionBox so the claim/eject logic never touches the claimer.)
--   * The loading bay on the west side of the yard, the freight bay +
--     trailer stalls for the hitch truck on the east side.
--   * Low see-through fences (a kerb and two rails) so the street and its
--     traffic stay visible from the yard, and one big signed exit gate.

local U = require(script.Parent.Util)
local L = require(script.Parent.Layout)
local Style = require(script.Parent.Style)
local Dock = require(script.Parent.Dock)

local Terminal = {}

local WALL = Color3.fromRGB(165, 160, 150)
local TRIM = Color3.fromRGB(40, 90, 150)
local METAL = Color3.fromRGB(70, 72, 78)
local YELLOW = Color3.fromRGB(230, 185, 40)
local WHITE = Color3.fromRGB(215, 215, 208)

local function paint(parent, r, color)
	return U.box(parent, "Paint", r, 0.005, 0.055, {
		Material = Enum.Material.SmoothPlastic, Color = color, CanCollide = false, CanQuery = false, CastShadow = false,
	})
end

local function floorText(parent, x, z, w, d, text, color, yaw)
	local p = U.part(parent, "FloorText", Vector3.new(w, 0.05, d), CFrame.new(x, 0.03, z) * CFrame.Angles(0, yaw or 0, 0), {
		Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false,
	})
	local g = U.label(p, Enum.NormalId.Top, text, { PixelsPerStud = 10, TextColor3 = color or WHITE })
	g.LightInfluence = 1
	return p
end

-- see-through fence: a low kerb and two rails on posts
local function fence(parent, a, b)
	U.segment(parent, "FenceKerb", a, b, 1, 0, 1.2, { Material = Enum.Material.Concrete, Color = WALL }, 0)
	for _, y in { 3.6, 6.2 } do
		U.segment(parent, "FenceRail", a, b, 0.3, y - 0.15, y + 0.15, { Material = Enum.Material.Metal, Color = METAL, CanCollide = false }, 0)
	end
	local d = (b - a)
	local n = math.max(1, math.floor(d.Magnitude / 10))
	for i = 0, n do
		local p = a:Lerp(b, i / n)
		U.part(parent, "FencePost", Vector3.new(0.5, 7, 0.5), CFrame.new(p + Vector3.new(0, 3.5, 0)), { Material = Enum.Material.Metal, Color = METAL })
	end
end

local function orientTerminal(template, pos, facing)
	local t = template:Clone()
	local screen = t:FindFirstChild("Screen", true)
	local bbCF = t:GetBoundingBox()
	local front = Vector3.new(0, 0, -1)
	if screen then
		local off = screen.Position - bbCF.Position
		off = Vector3.new(off.X, 0, off.Z)
		if off.Magnitude > 0.05 then
			front = off.Unit
		else
			front = Vector3.new(screen.CFrame.LookVector.X, 0, screen.CFrame.LookVector.Z).Unit
		end
	end
	local angle = math.atan2(-facing.X, -facing.Z) - math.atan2(-front.X, -front.Z)
	local pivot = t:GetPivot()
	t:PivotTo(CFrame.new(pivot.Position) * CFrame.Angles(0, angle, 0) * pivot.Rotation)
	local cf, size = t:GetBoundingBox()
	t:PivotTo(t:GetPivot() + Vector3.new(pos.X - cf.X, pos.Y + size.Y / 2 - cf.Y, pos.Z - cf.Z))
	for _, d in t:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	return t
end

-- workbench, tool chest, tyres, pegboard, lamp - for looks only
local function workshop(parent, x1, x2, zBack, height)
	local wood = { Material = Enum.Material.WoodPlanks, Color = Color3.fromRGB(150, 110, 70) }
	local steel = { Material = Enum.Material.Metal, Color = Color3.fromRGB(90, 92, 98) }
	-- bench along the back wall, left side
	local bx = x1 + 6
	U.part(parent, "BenchTop", Vector3.new(10, 0.6, 3.6), CFrame.new(bx, 3.6, zBack - 2.4), wood)
	for _, dx in { -4.5, 4.5 } do
		U.part(parent, "BenchLeg", Vector3.new(0.5, 3.3, 3), CFrame.new(bx + dx, 1.65, zBack - 2.4), steel)
	end
	U.part(parent, "BenchShelf", Vector3.new(9, 0.3, 3), CFrame.new(bx, 1, zBack - 2.4), wood)
	U.part(parent, "Vice", Vector3.new(1, 1, 1.4), CFrame.new(bx - 3.5, 4.4, zBack - 3.4), steel)
	U.part(parent, "Toolbox", Vector3.new(2.2, 1, 1.2), CFrame.new(bx + 2, 4.4, zBack - 2.2), { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(190, 40, 35) })
	-- pegboard with tools
	U.part(parent, "Pegboard", Vector3.new(9, 5, 0.2), CFrame.new(bx, 7.5, zBack - 0.3), { Material = Enum.Material.Wood, Color = Color3.fromRGB(190, 160, 110), CanCollide = false })
	for i = -3, 3 do
		U.part(parent, "Tool", Vector3.new(0.3, U.range(1.2, 2.6), 0.2), CFrame.new(bx + i * 1.2, 7.8, zBack - 0.5) * CFrame.Angles(0, 0, U.range(-0.3, 0.3)), {
			Material = Enum.Material.Metal, Color = U.pick({ Color3.fromRGB(60, 60, 64), Color3.fromRGB(180, 40, 30), Color3.fromRGB(40, 90, 170) }), CanCollide = false,
		})
	end
	-- red tool chest on the right side of the bench
	local cx = x1 + 13.5
	U.part(parent, "ToolChest", Vector3.new(3.2, 4.6, 2.2), CFrame.new(cx, 2.3, zBack - 1.6), { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(190, 35, 30) })
	for k = 0, 3 do
		U.part(parent, "Drawer", Vector3.new(2.8, 0.08, 0.1), CFrame.new(cx, 0.9 + k * 1.05, zBack - 2.72), { Material = Enum.Material.Metal, Color = Color3.fromRGB(200, 200, 200), CanCollide = false })
	end
	-- tyre stack on the right
	for k = 0, U.int(2, 4) do
		U.part(parent, "Tire", Vector3.new(1, 3.2, 3.2), CFrame.new(x2 - 3, 0.5 + k * 1.05, zBack - 3) * CFrame.Angles(0, 0, math.rad(90)), {
			Shape = Enum.PartType.Cylinder, Material = Enum.Material.Rubber, Color = Color3.fromRGB(28, 28, 30),
		})
	end
	-- hanging lamp
	local lampY = height - 5
	U.part(parent, "LampCord", Vector3.new(0.1, 4.5, 0.1), CFrame.new((x1 + x2) / 2, height - 2.5, zBack - 20), { Material = Enum.Material.SmoothPlastic, Color = Color3.new(0, 0, 0), CanCollide = false })
	local shade = U.part(parent, "LampShade", Vector3.new(4, 1.2, 4), CFrame.new((x1 + x2) / 2, lampY, zBack - 20), { Material = Enum.Material.Metal, Color = Color3.fromRGB(40, 90, 60), CanCollide = false })
	local _ = shade
	local bulb = U.part(parent, "LampBulb", Vector3.new(1.4, 0.6, 1.4), CFrame.new((x1 + x2) / 2, lampY - 0.8, zBack - 20), { Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 240, 210), CanCollide = false })
	local light = Instance.new("PointLight")
	light.Range = 34
	light.Brightness = 1.6
	light.Color = Color3.fromRGB(255, 235, 200)
	light.Shadows = true
	light.Parent = bulb
	-- oil stain + lift outline on the floor
	paint(parent, U.rect((x1 + x2) / 2 - 2, zBack - 30, (x1 + x2) / 2 + 2, zBack - 26), Color3.fromRGB(40, 40, 42))
end

function Terminal.Build(map, kit, deliveryDepot, plotsFolder)
	local T = L.Terminal
	local f = U.folder(map, "Terminal")
	local yard = T.Yard
	local G = T.Garage

	-- land for the whole terminal
	U.box(f, "Ground", U.rect(-L.HalfWidth, 20, L.HalfWidth, yard.z2 + 6), L.LandBottom, 0, { Material = Enum.Material.Asphalt, Color = Style.Asphalt })
	-- concrete apron in the yard
	U.box(f, "Apron", U.rect(yard.x1, yard.z1 + 2, yard.x2, G.doorZ), 0.001, 0.04, {
		Material = Enum.Material.Concrete, Color = Color3.fromRGB(128, 126, 122), CanCollide = false, CanQuery = false, CastShadow = false,
	})

	------------------------------------------------------------- fences + gate
	local fz = yard.z1 + 1
	fence(f, Vector3.new(yard.x1, 0, fz), Vector3.new(T.Gate.x1 - 8, 0, fz))
	fence(f, Vector3.new(T.Gate.x2 + 8, 0, fz), Vector3.new(yard.x2, 0, fz))
	fence(f, Vector3.new(yard.x1, 0, fz), Vector3.new(yard.x1, 0, yard.z2))
	fence(f, Vector3.new(yard.x2, 0, fz), Vector3.new(yard.x2, 0, yard.z2))
	-- the big exit gate
	for _, x in { T.Gate.x1 - 4, T.Gate.x2 + 4 } do
		U.part(f, "GatePillar", Vector3.new(6, 30, 6), CFrame.new(x, 15, fz), { Material = Enum.Material.Brick, Color = Color3.fromRGB(120, 70, 55) })
		U.part(f, "GateHouse", Vector3.new(10, 10, 10), CFrame.new(x + (x < 0 and -10 or 10), 5, fz + 8), { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(225, 225, 218) })
		U.part(f, "GateHouseRoof", Vector3.new(12, 0.8, 12), CFrame.new(x + (x < 0 and -10 or 10), 10.4, fz + 8), { Material = Enum.Material.Metal, Color = TRIM })
	end
	U.part(f, "GateBeam", Vector3.new(T.Gate.x2 - T.Gate.x1 + 14, 6, 4), CFrame.new(0, 29, fz), { Material = Enum.Material.SmoothPlastic, Color = TRIM })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		U.label(f.GateBeam, face, face == Enum.NormalId.Back and "EXIT  -  OLD TOWN" or "TIGHT SQUEEZE DELIVERY CO.", { PixelsPerStud = 12, TextColor3 = Color3.fromRGB(255, 225, 120) })
	end
	-- yard floor text reads for a driver heading north to the gate
	local north = math.rad(180)
	floorText(f, 0, yard.z1 + 16, 40, 12, "EXIT", YELLOW, north)
	for _, x in { -30, 30 } do
		floorText(f, x, yard.z1 + 34, 12, 12, "^", YELLOW, north)
	end
	-- lane lines leading to the gate
	for _, x in { T.Gate.x1, 0, T.Gate.x2 } do
		paint(f, U.rect(x - 0.3, yard.z1 + 6, x + 0.3, 250), x == 0 and YELLOW or WHITE)
	end
	floorText(f, -150, 180, 50, 10, "<  LOADING BAY", WHITE, north)
	floorText(f, 150, 100, 44, 10, "FREIGHT  >", WHITE, north)
	floorText(f, 0, 280, 40, 10, "GARAGES", WHITE, 0) -- read when driving in, facing the bays

	------------------------------------------------------------- workshops
	local x0 = -(G.bays * G.pitch) / 2
	local garages = U.folder(f, "Garages")
	local roofY = G.height
	U.box(garages, "GarageRoof", U.rect(x0 - 3, G.doorZ - 6, -x0 + 3, G.backZ + 2), roofY, roofY + 2, { Material = Enum.Material.Metal, Color = Color3.fromRGB(90, 94, 100) })
	U.box(garages, "Fascia", U.rect(x0 - 3, G.doorZ - 7, -x0 + 3, G.doorZ - 6), roofY - 4, roofY + 2, { Material = Enum.Material.SmoothPlastic, Color = TRIM })
	U.box(garages, "BackWall", U.rect(x0 - 3, G.backZ, -x0 + 3, G.backZ + 2), 0, roofY, { Material = Enum.Material.Concrete, Color = WALL })
	for _, x in { x0 - 3, -x0 + 1 } do
		U.box(garages, "EndWall", U.rect(x, G.doorZ - 6, x + 2, G.backZ), 0, roofY, { Material = Enum.Material.Concrete, Color = WALL })
	end
	local banner = U.part(garages, "GarageSign", Vector3.new(90, 8, 0.4), CFrame.new(0, roofY + 7, G.doorZ - 6), { Material = Enum.Material.SmoothPlastic, Color = TRIM, CanCollide = false })
	U.label(banner, Enum.NormalId.Front, "TERMINAL WORKSHOPS", { PixelsPerStud = 16 })
	local terminalTemplate = kit.Templates:FindFirstChild("Terminal")
	for i = 1, G.bays do
		local bx1 = x0 + (i - 1) * G.pitch
		local bx2 = bx1 + G.pitch
		local xc = (bx1 + bx2) / 2
		-- posts + low divider at the back half
		U.part(garages, "RoofPost", Vector3.new(1.4, roofY, 1.4), CFrame.new(bx1, roofY / 2, G.doorZ - 5), { Material = Enum.Material.Metal, Color = METAL })
		if i == G.bays then
			U.part(garages, "RoofPost", Vector3.new(1.4, roofY, 1.4), CFrame.new(bx2, roofY / 2, G.doorZ - 5), { Material = Enum.Material.Metal, Color = METAL })
		end
		if i > 1 then
			U.box(garages, "Divider", U.rect(bx1 - 0.5, G.backZ - 30, bx1 + 0.5, G.backZ), 0, 7, { Material = Enum.Material.Concrete, Color = WALL })
		end
		-- floor: bay outline + number
		local inset = 1.2
		U.box(garages, "BayFloor", U.rect(bx1 + inset, G.doorZ - 4, bx2 - inset, G.backZ), 0.001, 0.05, {
			Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(150, 150, 146), CanCollide = false, CanQuery = false, CastShadow = false,
		})
		for _, r in {
			U.rect(bx1 + inset, G.doorZ - 4, bx1 + inset + 0.5, G.backZ),
			U.rect(bx2 - inset - 0.5, G.doorZ - 4, bx2 - inset, G.backZ),
			U.rect(bx1 + inset, G.doorZ - 4, bx2 - inset, G.doorZ - 3.5),
		} do
			paint(garages, r, YELLOW)
		end
		floorText(garages, xc - 3, G.doorZ + 8, 10, 10, tostring(i), YELLOW, 0)
		-- number over the bay
		local num = U.part(garages, "BayNumber", Vector3.new(7, 3.2, 0.2), CFrame.new(xc, roofY - 2, G.doorZ - 7.2), { Material = Enum.Material.SmoothPlastic, Color = TRIM, CanCollide = false })
		U.label(num, Enum.NormalId.Front, "BAY " .. i, { PixelsPerStud = 30 })
		workshop(garages, bx1 + inset, bx2 - inset, G.backZ, roofY)

		local plot = Instance.new("Folder")
		plot.Name = "plot" .. i
		local boxZ1 = G.doorZ
		U.part(plot, "CollisionBox", Vector3.new(G.pitch - 3, roofY, G.backZ - boxZ1), CFrame.new(xc, roofY / 2, (boxZ1 + G.backZ) / 2), {
			Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false,
		})
		U.part(plot, "VehicleSpawn", Vector3.new(4, 1, 4), CFrame.lookAt(Vector3.new(xc - 2, 5.09, G.backZ - 32), Vector3.new(xc - 2, 5.09, G.doorZ - 10)), {
			Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false,
		})
		if terminalTemplate then
			-- front-right corner of its own bay, facing the yard
			local term = orientTerminal(terminalTemplate, Vector3.new(bx2 - 3.5, 0, G.doorZ - 2.2), Vector3.new(0, 0, -1))
			term.Name = "Terminal"
			term.Parent = plot
			-- an arrow sign above the kiosk pointing into its bay
			local tag = U.part(garages, "KioskTag", Vector3.new(4.4, 1.6, 0.2), CFrame.new(bx2 - 3.5, 7.4, G.doorZ - 2.2), { Material = Enum.Material.SmoothPlastic, Color = YELLOW, CanCollide = false })
			U.label(tag, Enum.NormalId.Front, "BAY " .. i .. " >", { PixelsPerStud = 30, TextColor3 = Color3.fromRGB(20, 20, 20) })
			U.part(garages, "KioskTagPole", Vector3.new(0.3, 7, 0.3), CFrame.new(bx2 - 3.5, 3.5, G.doorZ - 1.9), { Material = Enum.Material.Metal, Color = METAL, CanCollide = false })
		end
		plot.Parent = plotsFolder
	end

	------------------------------------------------------------- loading bay
	local D = T.Dock
	Dock.Build(deliveryDepot, kit, U.rect(D.x1, D.z1, D.x2 + 44, D.z2), "E", {
		name = "LoadingBay", spaces = D.spaces, depth = D.x2 - D.x1, height = 30, color = Color3.fromRGB(110, 106, 98),
	})
	------------------------------------------------------------- freight bay
	local F = T.Freight
	local freight = Dock.Build(deliveryDepot, kit, U.rect(F.x1 - 84, F.z1, F.x2, F.z2), "W", {
		name = "FreightBay", spaces = F.bays, spaceSize = L.RigSpaceSize, gap = 12, depth = F.x2 - F.x1,
		height = 30, spacePrefix = "RigSpace", signName = "FreightBoard", color = Color3.fromRGB(96, 104, 112),
	})
	local board = freight:FindFirstChild("FreightBoard")
	if board then
		U.label(board, Enum.NormalId.Front, "FREIGHT  -  TRAILER LOADING", { PixelsPerStud = 20, TextColor3 = Color3.fromRGB(255, 210, 60) })
	end
	local S = T.TrailerStalls
	local stalls = U.model(deliveryDepot, "TrailerStalls")
	stalls.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	local stallCenters = {}
	for i = 1, S.count do
		local z = S.firstZ + (i - 1) * S.pitch
		local cx = (S.x1 + S.x2) / 2
		U.part(stalls, "TrailerStall" .. i, Vector3.new(S.x2 - S.x1, 0.001, 14), CFrame.lookAt(Vector3.new(cx, 0.2, z), Vector3.new(cx - 10, 0.2, z)), {
			Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false,
		})
		for _, dz in { -7, 7 } do
			paint(f, U.rect(S.x1, z + dz - 0.25, S.x2, z + dz + 0.25), YELLOW)
		end
		table.insert(stallCenters, Vector3.new(cx, 0, z))
	end
	local trailersFolder = workspace:FindFirstChild("Trailers")
	if trailersFolder then
		local i = 1
		for _, tr in trailersFolder:GetChildren() do
			if tr:IsA("Model") and stallCenters[i] then
				local kingpin = tr:FindFirstChild("Kingpin", true)
				local cf = tr:GetBoundingBox()
				local nose = Vector3.new(0, 0, -1)
				if kingpin then
					local kp = kingpin:IsA("Attachment") and kingpin.WorldPosition or kingpin.Position
					local d = Vector3.new(kp.X - cf.X, 0, kp.Z - cf.Z)
					if d.Magnitude > 1 then
						nose = d.Unit
					end
				end
				local target = Vector3.new(-1, 0, 0)
				local angle = math.atan2(-target.X, -target.Z) - math.atan2(-nose.X, -nose.Z)
				local pivot = tr:GetPivot()
				tr:PivotTo(CFrame.new(pivot.Position) * CFrame.Angles(0, angle, 0) * pivot.Rotation)
				local cf2 = tr:GetBoundingBox()
				tr:PivotTo(tr:GetPivot() + Vector3.new(stallCenters[i].X - cf2.X, 0, stallCenters[i].Z - cf2.Z))
				i += 1
			end
		end
	end

	------------------------------------------------------------- dressing
	U.box(f, "DispatchOffice", U.rect(yard.x1 + 2, yard.z1 + 8, yard.x1 + 34, D.z1 - 4), 0, 12, { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(225, 225, 218) })
	local sign = U.part(f, "DispatchSign", Vector3.new(0.3, 3, 20), CFrame.new(yard.x1 + 34.3, 9, (yard.z1 + 8 + D.z1 - 4) / 2), { Material = Enum.Material.SmoothPlastic, Color = TRIM, CanCollide = false })
	U.label(sign, Enum.NormalId.Right, "DISPATCH", { PixelsPerStud = 20 })
	for _, p in { { yard.x1 + 50, yard.z1 + 40 }, { yard.x2 - 60, yard.z1 + 40 }, { -200, 290 }, { 200, 290 } } do
		U.part(f, "FloodPole", Vector3.new(1, 30, 1), CFrame.new(p[1], 15, p[2]), { Material = Enum.Material.Metal, Color = METAL })
		local head = U.part(f, "FloodHead", Vector3.new(4, 1.5, 2), CFrame.new(p[1], 30, p[2]), { Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 245, 220), CanCollide = false })
		local spot = Instance.new("SpotLight")
		spot.Face = Enum.NormalId.Bottom
		spot.Range = 60
		spot.Angle = 120
		spot.Brightness = 1.5
		spot.Parent = head
	end
	-- staff cars along the west fence, cones, pallets
	local cars = kit.Cars:GetChildren()
	for k = 0, 3 do
		if #cars > 0 then
			U.place(cars[(k % #cars) + 1], f, yard.x1 + 12, 0, 285 + k * 10, Vector3.new(1, 0, 0))
		end
	end
	-- verges beside the terminal
	local green = { Material = Enum.Material.Grass, Color = Color3.fromRGB(78, 110, 58) }
	U.box(f, "Verge", U.rect(-L.HalfWidth, 20, yard.x1 - 1, yard.z2 + 6), 0, 0.4, green)
	U.box(f, "Verge", U.rect(yard.x2 + 1, 20, L.HalfWidth, yard.z2 + 6), 0, 0.4, green)
	local tree = kit.Furniture:FindFirstChild("tree")
	if tree then
		for z = 40, yard.z2, 26 do
			U.place(tree, f, -340 + U.range(-8, 8), 0.4, z, Vector3.new(0, 0, -1))
			U.place(tree, f, 340 + U.range(-8, 8), 0.4, z, Vector3.new(0, 0, -1))
		end
	end
	U.box(f, "BackWall", U.rect(-L.HalfWidth, yard.z2 + 4, L.HalfWidth, yard.z2 + 6), 0, 8, { Material = Enum.Material.Brick, Color = Color3.fromRGB(120, 80, 64) })

	return f
end

return Terminal

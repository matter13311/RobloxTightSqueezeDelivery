-- Big, recognisable set pieces - one or two per stretch of each zone - so a
-- player can navigate by sight ("left at the clock tower", "the alley past
-- the gas holder"). Built from primitives in the zone's local frame.

local U = require(script.Parent.Util)

local Landmarks = {}

local SIZES = {
	ClockTower = Vector2.new(26, 26),
	Theatre = Vector2.new(50, 40),
	Church = Vector2.new(44, 60),
	WaterTower = Vector2.new(30, 30),
	GasHolder = Vector2.new(60, 60),
	BigFish = Vector2.new(44, 40),
}

function Landmarks.Footprint(lm)
	local s = SIZES[lm.Kind]
	if not s then
		return nil
	end
	return U.rect(lm.x - s.X / 2, lm.z - s.Y / 2, lm.x + s.X / 2, lm.z + s.Y / 2)
end

local function label(parent, name, size, cf, text, bg, fg, font)
	local p = U.part(parent, name, size, cf, { Material = Enum.Material.SmoothPlastic, Color = bg, CanCollide = false })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local g = U.label(p, face, text, { PixelsPerStud = 12, TextColor3 = fg, Font = font or Enum.Font.GothamBlack })
		g.LightInfluence = 0
	end
	return p
end

local BUILD = {}

function BUILD.ClockTower(f, lm)
	local x, z = lm.x, lm.z
	local brick = { Material = Enum.Material.Brick, Color = Color3.fromRGB(140, 80, 60) }
	U.part(f, "TowerBase", Vector3.new(22, 60, 22), CFrame.new(x, 30, z), brick)
	U.part(f, "TowerTop", Vector3.new(24, 20, 24), CFrame.new(x, 70, z), { Material = Enum.Material.Concrete, Color = Color3.fromRGB(210, 200, 180) })
	U.ramp(f, "Spire", Vector3.new(x, 80, z + 12), Vector3.new(x, 100, z), 24, { Material = Enum.Material.Slate, Color = Color3.fromRGB(60, 80, 70) })
	U.ramp(f, "Spire", Vector3.new(x, 80, z - 12), Vector3.new(x, 100, z), 24, { Material = Enum.Material.Slate, Color = Color3.fromRGB(60, 80, 70) })
	for _, dir in { Vector3.new(0, 0, 1), Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0) } do
		local c = Vector3.new(x, 70, z) + dir * 12.2
		local face = U.part(f, "ClockFace", Vector3.new(14, 14, 0.4), CFrame.lookAt(c, c + dir), {
			Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(245, 240, 225), CanCollide = false,
		})
		local g = U.label(face, Enum.NormalId.Front, "XII\n\n IX      III\n\nVI", { PixelsPerStud = 12, TextColor3 = Color3.fromRGB(30, 30, 30), Font = Enum.Font.Garamond })
		g.LightInfluence = 0.5
		local hand = U.part(f, "ClockHand", Vector3.new(0.6, 6, 0.2), CFrame.lookAt(c + dir * 0.4, c + dir) * CFrame.new(0, 2.5, 0), {
			Material = Enum.Material.Metal, Color = Color3.fromRGB(20, 20, 20), CanCollide = false,
		})
		local _ = hand
	end
end

function BUILD.Theatre(f, lm)
	local x, z = lm.x, lm.z
	U.part(f, "Theatre", Vector3.new(50, 44, 40), CFrame.new(x, 22, z), { Material = Enum.Material.Concrete, Color = Color3.fromRGB(150, 60, 60) })
	-- marquee facing Market (east for the west block)
	local face = x < 0 and 1 or -1
	local mx = x + face * 27
	U.part(f, "Marquee", Vector3.new(6, 4, 36), CFrame.new(mx, 12, z), { Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 200, 80), CanCollide = false })
	label(f, "MarqueeText", Vector3.new(34, 5, 0.3), CFrame.new(mx + face * 3.2, 12, z) * CFrame.Angles(0, math.rad(90), 0), "GRAND THEATRE", Color3.fromRGB(30, 20, 20), Color3.fromRGB(255, 230, 120))
	local sign = U.part(f, "TheatreSign", Vector3.new(2, 26, 7), CFrame.new(mx - face * 1, 32, z), { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(30, 20, 20), CanCollide = false })
	for _, fc in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local g = U.label(sign, fc, "T\nH\nE\nA\nT\nR\nE", { PixelsPerStud = 10, TextColor3 = Color3.fromRGB(255, 80, 120), Font = Enum.Font.FredokaOne })
		g.LightInfluence = 0
	end
end

function BUILD.Paifang(f, lm)
	local x, z = lm.x, lm.z
	local red = { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(180, 30, 30) }
	for _, dx in { -16.5, 16.5 } do
		U.part(f, "GatePost", Vector3.new(2, 19.7, 2), CFrame.new(x + dx, 9.85, z), red)
	end
	U.part(f, "GateBeam", Vector3.new(40, 2, 3), CFrame.new(x, 19, z), red)
	U.part(f, "GateRoof", Vector3.new(44, 1.5, 6), CFrame.new(x, 21.5, z), { Material = Enum.Material.Slate, Color = Color3.fromRGB(40, 90, 60), CanCollide = false })
	label(f, "GateSign", Vector3.new(16, 3.5, 0.4), CFrame.new(x, 16, z), "NOODLE ROW", Color3.fromRGB(200, 150, 30), Color3.fromRGB(120, 10, 10), Enum.Font.FredokaOne)
	for _, dx in { -10, 0, 10 } do
		U.part(f, "Lantern", Vector3.new(1.6, 2, 1.6), CFrame.new(x + dx, 16.5, z + 1.8), { Shape = Enum.PartType.Ball, Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 60, 40), CanCollide = false })
	end
end

function BUILD.Church(f, lm)
	local x, z = lm.x, lm.z
	local stone = { Material = Enum.Material.Slate, Color = Color3.fromRGB(170, 165, 150) }
	U.part(f, "Nave", Vector3.new(30, 30, 56), CFrame.new(x, 15, z), stone)
	U.ramp(f, "NaveRoof", Vector3.new(x - 15, 30, z), Vector3.new(x, 42, z), 56, { Material = Enum.Material.Slate, Color = Color3.fromRGB(70, 70, 80) })
	U.ramp(f, "NaveRoof", Vector3.new(x + 15, 30, z), Vector3.new(x, 42, z), 56, { Material = Enum.Material.Slate, Color = Color3.fromRGB(70, 70, 80) })
	U.part(f, "Bell", Vector3.new(14, 56, 14), CFrame.new(x, 28, z + 24), stone)
	for _, s in { { 7, 0 }, { -7, 0 } } do
		U.ramp(f, "Spire", Vector3.new(x + s[1], 56, z + 24), Vector3.new(x, 96, z + 24), 14, { Material = Enum.Material.Slate, Color = Color3.fromRGB(60, 70, 80) })
	end
	local w = U.part(f, "RoseWindow", Vector3.new(0.4, 8, 8), CFrame.new(x - 15.3, 22, z) * CFrame.Angles(0, 0, 0), { Material = Enum.Material.Neon, Color = Color3.fromRGB(80, 120, 220), CanCollide = false, Shape = Enum.PartType.Cylinder })
	w.CFrame = CFrame.new(x - 15.3, 22, z)
end

function BUILD.WaterTower(f, lm)
	local x, z = lm.x, lm.z
	for _, o in { { -9, -9 }, { 9, -9 }, { -9, 9 }, { 9, 9 } } do
		U.part(f, "TowerLeg", Vector3.new(1.4, 50, 1.4), CFrame.new(x + o[1], 25, z + o[2]), { Material = Enum.Material.Metal, Color = Color3.fromRGB(80, 80, 84) })
	end
	local tank = U.part(f, "Tank", Vector3.new(18, 26, 26), CFrame.new(x, 59, z) * CFrame.Angles(0, 0, math.rad(90)), {
		Shape = Enum.PartType.Cylinder, Material = Enum.Material.Metal, Color = Color3.fromRGB(170, 50, 40),
	})
	local _ = tank
	U.part(f, "TankCap", Vector3.new(14, 8, 14), CFrame.new(x, 72, z), { Material = Enum.Material.Metal, Color = Color3.fromRGB(140, 40, 32), Shape = Enum.PartType.Ball })
	label(f, "TankText", Vector3.new(22, 5, 0.3), CFrame.new(x + 13.3, 59, z) * CFrame.Angles(0, math.rad(90), 0), "MILL DISTRICT", Color3.fromRGB(170, 50, 40), Color3.fromRGB(245, 235, 220))
end

function BUILD.Chimneys(f, lm)
	local x, z = lm.x, lm.z
	for i, dz in { -14, 14 } do
		local c = U.part(f, "Smokestack", Vector3.new(90, 9, 9), CFrame.new(x, 28 + 45, z + dz) * CFrame.Angles(0, 0, math.rad(90)), {
			Shape = Enum.PartType.Cylinder, Material = Enum.Material.Brick, Color = Color3.fromRGB(120, 60, 45),
		})
		for k = 0, 2 do
			U.part(f, "StackBand", Vector3.new(1, 9.6, 9.6), CFrame.new(x, 40 + k * 28, z + dz) * CFrame.Angles(0, 0, math.rad(90)), {
				Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(230, 230, 225), CanCollide = false,
			})
		end
		local smoke = Instance.new("ParticleEmitter")
		smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
		smoke.Rate = 4
		smoke.Lifetime = NumberRange.new(6, 9)
		smoke.Speed = NumberRange.new(6, 9)
		smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 6), NumberSequenceKeypoint.new(1, 22) })
		smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
		smoke.Color = ColorSequence.new(Color3.fromRGB(150, 150, 150))
		smoke.EmissionDirection = Enum.NormalId.Right -- the cylinder's axis points up
		smoke.Parent = c
		local _ = i
	end
end

function BUILD.GasHolder(f, lm)
	local x, z = lm.x, lm.z
	U.part(f, "HolderTank", Vector3.new(34, 48, 48), CFrame.new(x, 17, z) * CFrame.Angles(0, 0, math.rad(90)), {
		Shape = Enum.PartType.Cylinder, Material = Enum.Material.Metal, Color = Color3.fromRGB(90, 110, 100),
	})
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		U.part(f, "HolderFrame", Vector3.new(1.4, 60, 1.4), CFrame.new(x + math.cos(a) * 27, 30, z + math.sin(a) * 27), { Material = Enum.Material.Metal, Color = Color3.fromRGB(120, 60, 50) })
	end
	for _, y in { 30, 58 } do
		for i = 0, 7 do
			local a1, a2 = i / 8 * math.pi * 2, (i + 1) / 8 * math.pi * 2
			local p1 = Vector3.new(x + math.cos(a1) * 27, y, z + math.sin(a1) * 27)
			local p2 = Vector3.new(x + math.cos(a2) * 27, y, z + math.sin(a2) * 27)
			U.segment(f, "HolderRing", p1, p2, 1, y - 0.6, y + 0.6, { Material = Enum.Material.Metal, Color = Color3.fromRGB(120, 60, 50), CanCollide = false })
		end
	end
end

function BUILD.BigFish(f, lm)
	local x, z = lm.x, lm.z
	U.part(f, "FishShop", Vector3.new(44, 26, 40), CFrame.new(x, 13, z), { Material = Enum.Material.WoodPlanks, Color = Color3.fromRGB(70, 110, 140) })
	-- a giant fish on the roof
	U.part(f, "FishBody", Vector3.new(30, 12, 12), CFrame.new(x, 36, z), { Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(240, 130, 50) })
	U.part(f, "FishHead", Vector3.new(12, 12, 12), CFrame.new(x - 15, 36, z), { Shape = Enum.PartType.Ball, Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(240, 130, 50) })
	U.ramp(f, "FishTail", Vector3.new(x + 16, 36, z), Vector3.new(x + 24, 44, z), 2, { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(220, 100, 40) })
	U.ramp(f, "FishTail", Vector3.new(x + 16, 36, z), Vector3.new(x + 24, 28, z), 2, { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(220, 100, 40) })
	for _, s in { -1, 1 } do
		U.part(f, "FishEye", Vector3.new(2.4, 2.4, 2.4), CFrame.new(x - 11, 38, z + s * 5), { Shape = Enum.PartType.Ball, Material = Enum.Material.SmoothPlastic, Color = Color3.new(1, 1, 1) })
	end
	label(f, "FishSign", Vector3.new(30, 5, 0.3), CFrame.new(x, 22, z + 20.3), "BIG FISH CO.", Color3.fromRGB(20, 50, 80), Color3.fromRGB(255, 220, 120), Enum.Font.FredokaOne)
end

function BUILD.Lighthouse(f, lm)
	local x, z = lm.x, lm.z
	for i = 0, 5 do
		U.part(f, "LighthouseRing", Vector3.new(10, 14 - i, 14 - i), CFrame.new(x, 5 + i * 10, z) * CFrame.Angles(0, 0, math.rad(90)), {
			Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = i % 2 == 0 and Color3.fromRGB(240, 240, 235) or Color3.fromRGB(200, 40, 40),
		})
	end
	local lamp = U.part(f, "Lamp", Vector3.new(6, 6, 6), CFrame.new(x, 64, z), { Shape = Enum.PartType.Ball, Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 240, 180) })
	local l = Instance.new("PointLight")
	l.Range = 60
	l.Brightness = 2
	l.Parent = lamp
	U.part(f, "LampRoof", Vector3.new(8, 3, 8), CFrame.new(x, 68.5, z), { Material = Enum.Material.Metal, Color = Color3.fromRGB(40, 40, 42) })
end

function BUILD.Cranes(f, lm)
	for i = 0, 1 do
		local x = lm.x + i * 70
		local z = lm.z
		for _, dx in { -9, 9 } do
			for _, dz in { -12, 12 } do
				U.part(f, "CraneLeg", Vector3.new(2, 54, 2), CFrame.new(x + dx, 27, z + dz), { Material = Enum.Material.Metal, Color = Color3.fromRGB(210, 130, 30) })
			end
		end
		U.part(f, "CraneBeam", Vector3.new(22, 4, 90), CFrame.new(x, 56, z - 20), { Material = Enum.Material.Metal, Color = Color3.fromRGB(210, 130, 30) })
		U.part(f, "CraneCab", Vector3.new(8, 6, 8), CFrame.new(x, 51, z - 30), { Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(240, 240, 230) })
	end
end

function Landmarks.Build(parent, _kit, lm, _styleKey)
	local f = U.folder(parent, lm.Label or lm.Kind)
	local fn = BUILD[lm.Kind]
	if fn then
		fn(f, lm)
	end
end

return Landmarks

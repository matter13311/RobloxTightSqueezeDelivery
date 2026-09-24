-- Junction treatments: what a Market Ave crossing looks like when it is not
-- the plain signalled four-way every zone used to have.
--
-- ROUNDABOUT. A drivable mini-roundabout in the middle of a Market junction:
-- a low kerbed island (top 0.5, the same height as a pavement, so Verify counts
-- it as road and every vehicle class rides over it), a monument, and white
-- circulation arrows painted round it. It is deliberately SMALL and DRIVABLE.
-- The cross roads are only 34 deep, so a ring wide enough for a box truck to
-- circle would not fit; a mini-roundabout is the real-world answer to that too.
-- Nothing here is randomised, so adding or moving one never reshuffles the
-- rest of the zone.
--
-- NPC traffic that crosses a roundabout junction is steered round the island by
-- Traffic.detour (same radius maths, see L.Roundabout).
--
-- Placed by Zone.Build from the zone's Layout `Roundabouts` list.

local U = require(script.Parent.Util)
local L = require(script.Parent.Layout)
local Style = require(script.Parent.Style)

local Junctions = {}

local WHITE = Color3.fromRGB(215, 215, 208)
local KERB_TOP = 0.42
local ISLAND_TOP = 0.5

-- A vertical cylinder centred on (x, z), from y1 to y2. Roblox cylinders lie
-- along their local X, so it is stood up with a quarter turn about Z.
local function disc(parent, name, x, z, radius, y1, y2, props)
	props.Shape = Enum.PartType.Cylinder
	return U.part(parent, name, Vector3.new(y2 - y1, radius * 2, radius * 2),
		CFrame.new(x, (y1 + y2) / 2, z) * CFrame.Angles(0, 0, math.rad(90)), props)
end

-- A painted arrow lying on the road at (x, z), pointing along `dir`.
local function arrow(parent, x, z, dir)
	local cf = CFrame.lookAt(Vector3.new(x, 0.03, z), Vector3.new(x + dir.X, 0.03, z + dir.Z))
	local props = { Material = Enum.Material.SmoothPlastic, Color = WHITE, CanCollide = false, CanQuery = false, CastShadow = false }
	U.part(parent, "RoundaboutArrow", Vector3.new(0.55, 0.05, 3), cf, props)
	for _, s in { -1, 1 } do
		U.part(parent, "RoundaboutArrow", Vector3.new(0.55, 0.05, 1.8), cf * CFrame.new(s * 0.58, 0, -0.81) * CFrame.Angles(0, s * math.rad(40), 0), props)
	end
end

-- Mill: a big rust-coloured cog on a post, face to the traffic on Market.
local function cog(parent, x, z, rs)
	local cy = 10.5
	disc(parent, "CogPost", x, z, 0.8, 2.2, cy, { Material = Enum.Material.Metal, Color = rs.metal })
	local face = CFrame.new(x, cy, z)
	local along = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis X -> Z
	local wheel = { Material = Enum.Material.Metal, Color = rs.accent, CanCollide = false }
	U.part(parent, "CogWheel", Vector3.new(1.0, 7.4, 7.4), face * along, { Shape = Enum.PartType.Cylinder, Material = wheel.Material, Color = wheel.Color, CanCollide = false })
	for k = 0, 9 do
		U.part(parent, "CogTooth", Vector3.new(1.7, 1.5, 1.0), face * CFrame.Angles(0, 0, math.rad(k * 36)) * CFrame.new(0, 3.9, 0), wheel)
	end
	U.part(parent, "CogHub", Vector3.new(1.3, 2.4, 2.4), face * along, { Shape = Enum.PartType.Cylinder, Material = Enum.Material.Metal, Color = rs.metal, CanCollide = false })
end

-- Harbour: a ship's anchor standing on end, seen flat from Market.
local function anchor(parent, x, z, rs)
	local iron = { Material = Enum.Material.Metal, Color = rs.metal, CanCollide = false }
	local function bar(a, b, w)
		local pa, pb = Vector3.new(x + a.X, a.Y, z), Vector3.new(x + b.X, b.Y, z)
		U.part(parent, "AnchorPart", Vector3.new(w, w, (pb - pa).Magnitude), CFrame.lookAt((pa + pb) / 2, pb), iron)
	end
	disc(parent, "AnchorPost", x, z, 0.5, 2.2, 3, { Material = Enum.Material.Metal, Color = rs.metal })
	U.part(parent, "AnchorShank", Vector3.new(1.0, 10.4, 1.0), CFrame.new(x, 7.8, z), iron)
	U.part(parent, "AnchorCrown", Vector3.new(1.8, 1.2, 1.2), CFrame.new(x, 3.0, z), iron)
	bar(Vector2.new(-3.6, 11.2), Vector2.new(3.6, 11.2), 0.9) -- stock
	bar(Vector2.new(0, 3.0), Vector2.new(-3.6, 4.9), 1.0) -- arms
	bar(Vector2.new(0, 3.0), Vector2.new(3.6, 4.9), 1.0)
	bar(Vector2.new(-3.6, 4.9), Vector2.new(-3.9, 6.5), 1.3) -- flukes
	bar(Vector2.new(3.6, 4.9), Vector2.new(3.9, 6.5), 1.3)
	U.part(parent, "AnchorRing", Vector3.new(0.5, 2.2, 2.2), CFrame.new(x, 13.4, z) * CFrame.Angles(0, math.rad(90), 0), {
		Shape = Enum.PartType.Cylinder, Material = Enum.Material.Metal, Color = rs.accent, CanCollide = false,
	})
end

local MONUMENTS = { cog = cog, anchor = anchor }

-- The island, kerb, monument and circulation arrows of one roundabout centred
-- on local (cx, cz). Traffic here is right-hand, so it circulates
-- anticlockwise seen from above (east -> north -> west -> south).
function Junctions.Roundabout(parent, styleKey, cx, cz, radius)
	local rs = Style.Roundabouts[styleKey] or Style.Roundabouts.default
	local kerb = L.Roundabout.Kerb
	local f = U.folder(parent, "Roundabout_" .. math.abs(math.floor(cz)))

	disc(f, "RoundaboutKerb", cx, cz, radius + kerb, 0, KERB_TOP, { Material = Enum.Material.Concrete, Color = rs.kerb })
	if rs.hazard then
		-- alternate blocks of hazard paint round the kerb
		for k = 0, 15, 2 do
			local a = k * math.pi / 8
			local rr = radius + kerb / 2
			U.part(f, "RoundaboutKerbStripe", Vector3.new(kerb, 0.06, 1.5),
				CFrame.new(cx + rr * math.cos(a), KERB_TOP + 0.03, cz + rr * math.sin(a)) * CFrame.Angles(0, -a, 0), {
					Material = Enum.Material.SmoothPlastic, Color = rs.hazard, CanCollide = false, CanQuery = false,
				})
		end
	end
	disc(f, "RoundaboutIsland", cx, cz, radius, 0, ISLAND_TOP, { Material = rs.surface.material, Color = rs.surface.color })
	disc(f, "RoundaboutPlinth", cx, cz, 2.8, ISLAND_TOP, 2.2, { Material = Enum.Material.Concrete, Color = rs.kerb })
	MONUMENTS[rs.monument](f, cx, cz, rs)

	local ringR = radius + kerb + 3.2
	for k = 0, 7 do
		local a = math.rad(22.5 + k * 45)
		local dir = Vector3.new(math.sin(a), 0, -math.cos(a))
		arrow(f, cx + ringR * math.cos(a), cz + ringR * math.sin(a), dir)
	end
end

return Junctions

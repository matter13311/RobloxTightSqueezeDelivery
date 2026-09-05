-- Not synced by Rojo. Paste into the Studio Command Bar with a car Model
-- selected (e.g. Workspace.Vehicles.PickupTruck), run it once, then nudge the
-- boxes by hand until they wrap the truck's silhouette.
--
-- WHY THIS EXISTS
--
-- A MeshPart does not collide using its mesh. It collides using whatever hull
-- CollisionFidelity produced, and the default is a rough approximation that is
-- usually noticeably smaller than what you can see. Against a big flat
-- building wall you never notice, because the wall is one huge convex slab and
-- any error is hidden inside it. Against another car, BOTH cars' hull errors
-- point inward and stack, so the two trucks visually overlap by the sum of
-- them before anything touches - which reads exactly like "my bumper clipped
-- through their door and then hit something in the middle of their car". The
-- something in the middle is the Chassis, which is a plain Part and therefore
-- the only piece of either truck whose collision shape is honest.
--
-- Five hand-authored boxes fix that permanently, and they are also cheaper to
-- simulate and far more predictable to tune than any mesh hull. Check the real
-- shapes any time with:
--   File > Studio Settings > Physics > Show Decomposition Geometry
--
-- WHAT IT DOES NOT DO
--
-- It does not weld (Raycast.server.luau welds the Collision folder at runtime,
-- alongside Body/Lights/Engine) and it does not change any part's mass. The
-- hulls are created Massless, so the truck's total mass - which Stiffness,
-- Torque and BrakeFriction in Configs/PickupTruck.luau are all tuned against -
-- is exactly what it was before.

local Selection = game:GetService("Selection")

local carModel = Selection:Get()[1]
assert(carModel and carModel:IsA("Model"), "Select the car Model first")

local chassis = carModel.PrimaryPart
assert(chassis, "Set the car's PrimaryPart (the Chassis) first")

local body = carModel:FindFirstChild("Body")
assert(body, "No Body folder found on " .. carModel:GetFullName())

local existing = carModel:FindFirstChild("Collision")
if existing then
	existing:Destroy()
end

-- Bounding box of the BODY only, measured in the chassis' own space. Not
-- Model:GetBoundingBox: that includes the wheels (which hang below the body)
-- and the door swing, and it is oriented to the model pivot rather than to the
-- chassis, so the boxes would come out tilted on any car whose pivot isn't
-- perfectly square to its chassis.
local min, max = nil, nil
local CORNER_SIGNS = {
	Vector3.new(1, 1, 1),
	Vector3.new(1, 1, -1),
	Vector3.new(1, -1, 1),
	Vector3.new(1, -1, -1),
	Vector3.new(-1, 1, 1),
	Vector3.new(-1, 1, -1),
	Vector3.new(-1, -1, 1),
	Vector3.new(-1, -1, -1),
}

for _, part in body:GetDescendants() do
	if part:IsA("BasePart") then
		local half = part.Size / 2
		for _, sign in CORNER_SIGNS do
			local corner = chassis.CFrame:PointToObjectSpace(part.CFrame:PointToWorldSpace(half * sign))
			min = if min then min:Min(corner) else corner
			max = if max then max:Max(corner) else corner
		end
	end
end
assert(min, "Body folder contains no BaseParts")

local centre = (min + max) / 2
local size = max - min
local width, height, length = size.X, size.Y, size.Z

local folder = Instance.new("Folder")
folder.Name = "Collision"
folder.Parent = carModel

local function hull(name, offset, boxSize)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = boxSize
	part.CFrame = chassis.CFrame * CFrame.new(centre + offset)
	part.Anchored = false
	part.CanCollide = true
	part.CanTouch = true
	part.CanQuery = true
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.4, 0, 1, 100)
	-- Left visible on purpose so you can see and drag them. Set Transparency to
	-- 1 on the whole folder once the fit looks right - VehicleCollisionSetup
	-- does not touch Transparency, so whatever you leave here is what ships.
	part.Transparency = 0.6
	part.Color = Color3.fromRGB(0, 200, 255)
	part.Parent = folder
	return part
end

-- A starting point, not an answer. The flanks are deliberately thin and set
-- slightly inboard of the widest point so mirrors and arches aren't part of
-- the car's collision width - on a game about threading gaps, a truck whose
-- hull is as wide as its mirrors will feel like it can't fit anywhere.
hull("Hull_Core", Vector3.new(0, 0, 0), Vector3.new(width * 0.92, height * 0.70, length * 0.70))
hull("Hull_Front", Vector3.new(0, -height * 0.15, -length * 0.42), Vector3.new(width * 0.92, height * 0.40, length * 0.16))
hull("Hull_Rear", Vector3.new(0, -height * 0.15, length * 0.42), Vector3.new(width * 0.92, height * 0.40, length * 0.16))
hull("Hull_Left", Vector3.new(-width * 0.46, -height * 0.10, 0), Vector3.new(width * 0.08, height * 0.45, length * 0.80))
hull("Hull_Right", Vector3.new(width * 0.46, -height * 0.10, 0), Vector3.new(width * 0.08, height * 0.45, length * 0.80))

-- Front/rear is a guess: it assumes the chassis' -Z is forward, which is the
-- Roblox convention (LookVector). If the bumpers come out swapped, the chassis
-- is turned round - rename the two parts rather than negating anything here,
-- since nothing in the collision system cares which is which.
print(
	("[BuildCollisionHulls] %s: 5 hulls from body extents W=%.2f H=%.2f L=%.2f"):format(
		carModel.Name,
		width,
		height,
		length
	)
)

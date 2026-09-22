-- A warehouse with a yard of parking spaces in front of it. Used for every
-- delivery destination, the Terminal's loading bay and its freight bay.

local U = require(script.Parent.Util)
local L = require(script.Parent.Layout)
local Style = require(script.Parent.Style)

local Dock = {}

local NORMALS = {
	E = Vector3.new(1, 0, 0),
	W = Vector3.new(-1, 0, 0),
	S = Vector3.new(0, 0, 1),
	N = Vector3.new(0, 0, -1),
}

-- rect: footprint. access: side that opens to the road. opts:
--   spaces (regular count), rig (bool), depth (warehouse), height, name,
--   spacePrefix (default "Space"), rigPrefix, noYard, color
function Dock.Build(parent, kit, rect, access, opts)
	local model = U.model(parent, opts.name)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	local normal = NORMALS[access]
	local depth = opts.depth or L.WarehouseDepth
	local height = opts.height or 28
	local alongIsZ = math.abs(normal.X) > 0.5
	local alongDir = alongIsZ and Vector3.new(0, 0, 1) or Vector3.new(1, 0, 0)
	local a1 = alongIsZ and rect.z1 or rect.x1
	local a2 = alongIsZ and rect.z2 or rect.x2

	-- warehouse block + face line
	local wr, face
	if access == "E" then
		wr = U.rect(rect.x1, rect.z1, rect.x1 + depth, rect.z2)
		face = rect.x1 + depth
	elseif access == "W" then
		wr = U.rect(rect.x2 - depth, rect.z1, rect.x2, rect.z2)
		face = rect.x2 - depth
	elseif access == "S" then
		wr = U.rect(rect.x1, rect.z1, rect.x2, rect.z1 + depth)
		face = rect.z1 + depth
	else
		wr = U.rect(rect.x1, rect.z2 - depth, rect.x2, rect.z2)
		face = rect.z2 - depth
	end
	local wh = U.box(model, "Warehouse", wr, 0, height, {
		Material = Enum.Material.Concrete,
		Color = opts.color or Color3.fromRGB(96, 92, 86),
	})
	for _, f in { Enum.NormalId.Front, Enum.NormalId.Back, Enum.NormalId.Left, Enum.NormalId.Right } do
		local t = Instance.new("Texture")
		t.Texture = "rbxassetid://5143828689"
		t.StudsPerTileU = 8
		t.StudsPerTileV = 8
		t.Color3 = Color3.fromRGB(200, 190, 170)
		t.Face = f
		t.Parent = wh
	end
	-- yard pad
	if not opts.noYard then
		local yr
		if access == "E" then
			yr = U.rect(face, rect.z1, rect.x2, rect.z2)
		elseif access == "W" then
			yr = U.rect(rect.x1, rect.z1, face, rect.z2)
		elseif access == "S" then
			yr = U.rect(rect.x1, face, rect.x2, rect.z2)
		else
			yr = U.rect(rect.x1, rect.z1, rect.x2, face)
		end
		U.box(model, "YardPad", yr, 0, 0.08, {
			Material = Enum.Material.Concrete,
			Color = Style.YardPad,
			CastShadow = false,
		})
	end

	local function point(along, out, y)
		-- along: coordinate on the along axis; out: distance from the face
		if alongIsZ then
			return Vector3.new(face + normal.X * out, y, along)
		end
		return Vector3.new(along, y, face + normal.Z * out)
	end

	local spaceTemplate = kit.Templates:FindFirstChild("Space")
	local doorTemplate = kit.Templates:FindFirstChild("RollupDoor")
	local signTemplate = kit.Templates:FindFirstChild("Sign")
	local prefix = opts.spacePrefix or "Space"

	local function door(along)
		if not doorTemplate then
			return
		end
		local d = doorTemplate:Clone()
		local pos = point(along, 1.1, d.Size.Y / 2)
		d.CFrame = CFrame.new(pos) * (alongIsZ and CFrame.identity or CFrame.Angles(0, math.rad(90), 0))
		d.Anchored = true
		d.Parent = model
		U.part(model, "DockBumper", alongIsZ and Vector3.new(0.8, 1.2, 14) or Vector3.new(14, 1.2, 0.8), CFrame.new(point(along, 0.4, 1.2)), {
			Material = Enum.Material.Rubber, Color = Color3.fromRGB(30, 30, 30),
		})
		U.part(model, "DockLight", alongIsZ and Vector3.new(1.2, 0.6, 2.5) or Vector3.new(2.5, 0.6, 1.2), CFrame.new(point(along, 0.6, 15.2)), {
			Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 200, 90), CanCollide = false,
		})
	end

	local function space(name, center, lengthDir, size)
		local s
		if spaceTemplate then
			s = spaceTemplate:Clone()
		else
			s = Instance.new("Part")
		end
		s.Name = name
		s.Anchored = true
		s.CanCollide = false
		s.CanTouch = false
		s.CanQuery = false
		s.Size = Vector3.new(size.X, 0.001, size.Y)
		s.CFrame = CFrame.lookAt(center, center + lengthDir)
		s.Parent = model
		return s
	end

	local n = opts.spaces or 2
	local size = opts.spaceSize or L.SpaceSize
	local gap = opts.gap or 6
	local sw, sl = size.X, size.Y
	local pitch = sw + gap
	local regularSpan = n * pitch - gap
	local rigSpan = opts.rig and (L.RigSpaceSize.Y + 12) or 0
	local total = regularSpan + rigSpan
	local start = (a1 + a2) / 2 - total / 2
	local spaces = {}
	for i = 1, n do
		local along = start + (i - 1) * pitch + sw / 2
		local c = point(along, sl / 2 + 1, 0.22)
		local s = space(prefix .. i, c, normal, size)
		if opts.spaceSize then
			s:SetAttribute("RigBay", true)
		end
		table.insert(spaces, s)
		door(along)
	end
	if opts.rig then
		local along = start + regularSpan + 12 + L.RigSpaceSize.Y / 2
		local c = point(along, L.RigSpaceSize.X / 2 + 1, 0.22)
		local s = space(opts.rigPrefix or (prefix .. (n + 1)), c, alongDir, L.RigSpaceSize)
		s:SetAttribute("RigBay", true)
		table.insert(spaces, s)
		door(along - 20)
		door(along + 20)
	end

	-- sign centred on the face, facing the yard (DepotGuides draws on Front)
	if signTemplate then
		local sgn = signTemplate:Clone()
		sgn.Name = opts.signName or "Sign"
		local pos = point((a1 + a2) / 2, 1.3, height - 7)
		sgn.CFrame = CFrame.lookAt(pos, pos + normal)
		sgn.Anchored = true
		sgn.Parent = model
	end
	return model, spaces
end

return Dock

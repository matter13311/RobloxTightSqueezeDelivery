-- Display-only copies of every vehicle template, published to
-- ReplicatedStorage.VehiclePreviews so the garage (GarageStage.luau) can clone
-- them on the client.
--
-- WHY THIS EXISTS. The real templates live in ServerStorage, which clients
-- cannot see, and the garage needs a car it can spawn, repaint and throw away
-- as fast as a player can click through the list - locally, for that one
-- player, with no server round trip and nothing replicated to anyone else.
-- Copying the templates here at startup keeps ServerStorage.VehicleTemplates
-- the ONE place a car is authored: add a vehicle there and it shows up in the
-- garage with no second model to maintain and no thumbnail to render.
--
-- WHAT IS STRIPPED. Anything that makes a car a car rather than a picture of
-- one: scripts, sounds, prompts, joints and constraints. Every part is left
-- anchored and non-colliding, and CanTouch is off so a seat in the preview can
-- never sit anybody down. The wheel-mount Attachments on the Chassis are kept -
-- the garage rebuilds the wheels from them, the same way Raycast.server does
-- for a real car.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local STRIPPED_CLASSES = {
	"LuaSourceContainer",
	"Sound",
	"ProximityPrompt",
	"ClickDetector",
	"JointInstance",
	"WeldConstraint",
	"Constraint",
	"NoCollisionConstraint",
	"BodyMover",
	"Explosion",
}

local function shouldStrip(instance)
	for _, className in STRIPPED_CLASSES do
		if instance:IsA(className) then
			return true
		end
	end
	return false
end

local function makePreview(template)
	local preview = template:Clone()
	for _, descendant in preview:GetDescendants() do
		if shouldStrip(descendant) then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Light") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			-- A parked car: no exhaust smoke, headlights off.
			descendant.Enabled = false
		end
	end
	-- What VehiclePhysics.GetConfig keys off. PlotManager sets the same thing
	-- on a real spawned car; without it the preview would fall back to its
	-- Model name, which only happens to match today.
	if preview.PrimaryPart then
		preview.PrimaryPart:SetAttribute("ConfigName", template.Name)
	end
	return preview
end

local folder = Instance.new("Folder")
folder.Name = "VehiclePreviews"

local templates = ServerStorage:FindFirstChild("VehicleTemplates")
if templates then
	for _, template in templates:GetChildren() do
		if template:IsA("Model") then
			-- One broken template must not take every other car's preview
			-- down with it.
			local ok, err = pcall(function()
				makePreview(template).Parent = folder
			end)
			if not ok then
				warn("VehiclePreviews: could not build a preview of " .. template.Name .. ": " .. tostring(err))
			end
		end
	end
else
	warn("VehiclePreviews: ServerStorage.VehicleTemplates is missing - the garage will have nothing to show")
end

-- Parented last, fully built, so a client that finds the folder never sees it
-- half-filled.
folder.Parent = ReplicatedStorage

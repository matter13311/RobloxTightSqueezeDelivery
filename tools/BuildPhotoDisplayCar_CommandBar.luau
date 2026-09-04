-- Not synced by Rojo. Run in EDIT MODE (no need to Play) from the Command Bar,
-- server context - ServerStorage and ReplicatedStorage are both reachable
-- there without a live game running.
--
-- Clones a vehicle template from ServerStorage.VehicleTemplates and welds on
-- a full set of wheels, so you have something worth photographing - the
-- template alone has none, since wheels are only ever cloned onto a car at
-- spawn time (see the wheels section of AddCar in Raycast.server.luau, which
-- this deliberately mirrors so what you photograph matches what actually
-- spawns in-game).
--
-- Everything else AddCar normally does is skipped on purpose - settling
-- physics, network ownership, doors, collision groups, damage bookkeeping.
-- None of it matters for a static product shot, and skipping it means this
-- doesn't need Workspace.Vehicles or a live server to run at all.
--
-- The result is dropped a short distance in front of wherever your Studio
-- viewport camera currently is, named "<Template>_PhotoDisplay", fully
-- Anchored. Fly the camera around it, screenshot (Win+Shift+S), then delete
-- it from Workspace - it's scratch, not something to ship.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

-- Edit this to build a different vehicle - matches VehicleCatalog's
-- TemplateName, i.e. the model's name under ServerStorage.VehicleTemplates.
local TEMPLATE_NAME = "StarterCar"

local wheelsFolder = ReplicatedStorage:FindFirstChild("Wheels")
if not wheelsFolder then
	warn("BuildPhotoDisplayCar: ReplicatedStorage.Wheels not found - nowhere to clone wheel models from")
	return
end

local templates = ServerStorage:FindFirstChild("VehicleTemplates")
local template = templates and templates:FindFirstChild(TEMPLATE_NAME)
if not template then
	warn("BuildPhotoDisplayCar: no ServerStorage.VehicleTemplates." .. TEMPLATE_NAME .. " found")
	return
end

local carModel = template:Clone()
carModel.Name = TEMPLATE_NAME .. "_PhotoDisplay"

local chassis = carModel.PrimaryPart
if not chassis then
	warn("BuildPhotoDisplayCar: " .. carModel.Name .. " has no PrimaryPart set - can't find wheel attachments")
	carModel:Destroy()
	return
end

local attachments = VehiclePhysics.GetWheelAttachments(chassis)

-- Same lookup AddCar uses: a car can override its wheel mesh via a
-- WheelModelName attribute on the Chassis, or a WheelModelName entry in its
-- Configs/<name>.luau file, naming a different model in
-- ReplicatedStorage.Wheels - falls back to the same default AddCar does.
local defaultWheelModel = wheelsFolder:FindFirstChild("UAZWheelDetailed")
local wheelModelName = VehiclePhysics.GetConfig(chassis).WheelModelName
local wheelModel = (wheelModelName and wheelsFolder:FindFirstChild(wheelModelName)) or defaultWheelModel
if not wheelModel then
	warn(
		"BuildPhotoDisplayCar: no wheel model found in ReplicatedStorage.Wheels (looked for "
			.. tostring(wheelModelName)
			.. " and the default UAZWheelDetailed)"
	)
	carModel:Destroy()
	return
end

-- Parked default: Anchored chassis, wheels welded to it (not anchored
-- themselves) - exactly the state AddCar leaves a freshly-spawned car in
-- before anyone drives it, so the weld solver holds each wheel at its
-- attachment offset relative to the chassis with nothing further needed here.
chassis.Anchored = true

local wheelFolder = Instance.new("Folder", carModel)
wheelFolder.Name = "Wheels"
for _, wheelName in VehiclePhysics.WheelNames do
	local attachment = attachments[wheelName]
	if not attachment then
		warn("BuildPhotoDisplayCar: " .. carModel.Name .. " has no " .. wheelName .. " attachment - skipping it")
		continue
	end

	local clonedWheel = wheelModel:Clone()
	clonedWheel.Parent = wheelFolder
	clonedWheel.Name = wheelName

	-- Works for both a single-Part wheel and a multi-part Model wheel
	-- (rim/tire/hubcap etc, rigidly welded together internally).
	local parts = clonedWheel:IsA("Model") and clonedWheel:GetDescendants() or { clonedWheel }
	for _, part in parts do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.Anchored = false
		end
	end

	local wheelPrimary = VehiclePhysics.GetWheelPrimaryPart(clonedWheel)
	local weld = Instance.new("Weld", wheelPrimary)
	weld.Part0 = chassis
	weld.Part1 = wheelPrimary
	weld.C0 = CFrame.new(attachment.Position)

	if attachment.Position.X > 0 then
		weld.C0 = weld.C0 * CFrame.Angles(0, math.rad(180), 0)
	end
end

-- Drop it a short distance in front of wherever the Studio camera is looking,
-- so it's immediately in view instead of buried at the origin somewhere.
local camera = workspace.CurrentCamera
local displayCFrame = CFrame.new(camera.CFrame.Position + camera.CFrame.LookVector * 15)
carModel:PivotTo(CFrame.new(displayCFrame.Position) * (chassis.CFrame - chassis.CFrame.Position))

carModel.Parent = workspace

print("BuildPhotoDisplayCar: built " .. carModel.Name .. " - delete it from Workspace once you're done with it")

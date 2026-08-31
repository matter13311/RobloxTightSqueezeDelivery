--!strict
-- Finds every Car model in the workspace (tag them with CollectionService tag
-- "Car", or just drop them directly in Workspace / a "Cars" folder) and drives
-- raycast suspension on their four wheels every Heartbeat.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local RaycastSuspension = require(ReplicatedStorage.Modules.Vehicles.RaycastSuspension)

local STEERABLE_WHEELS = { FL = true, FR = true }

local function weldBodyToChassis(car: Model, chassis: BasePart)
	local body = car:FindFirstChild("Body")
	if not body then
		return
	end

	for _, part in body:GetDescendants() do
		if part:IsA("BasePart") then
			local alreadyWelded = false
			for _, child in part:GetChildren() do
				if child:IsA("WeldConstraint") and (child.Part0 == chassis or child.Part1 == chassis) then
					alreadyWelded = true
					break
				end
			end

			if not alreadyWelded then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = chassis
				weld.Part1 = part
				weld.Parent = part
			end
			part.Anchored = false
		end
	end
end

local function setupCar(car: Model)
	local chassis = car:FindFirstChild("Chassis")
	local wheels = car:FindFirstChild("Wheels")

	if not (chassis and chassis:IsA("BasePart")) then
		warn(`[CarSuspensionManager] "{car:GetFullName()}" has no Chassis BasePart, skipping`)
		return
	end
	if not (wheels and wheels:IsA("Folder")) then
		warn(`[CarSuspensionManager] "{car:GetFullName()}" has no Wheels folder, skipping`)
		return
	end

	chassis.Anchored = false
	weldBodyToChassis(car, chassis)

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { car }
	raycastParams.IgnoreWater = true

	local corners = {}
	for _, wheel in wheels:GetChildren() do
		if wheel:IsA("BasePart") then
			local suspension = RaycastSuspension.new(chassis, wheel, {
				Steerable = STEERABLE_WHEELS[wheel.Name] == true,
				RaycastParams = raycastParams,
			})
			table.insert(corners, suspension)
		end
	end

	local connection: RBXScriptConnection
	connection = RunService.Heartbeat:Connect(function(dt: number)
		if not car.Parent then
			connection:Disconnect()
			for _, corner in corners do
				corner:Destroy()
			end
			return
		end

		for _, corner in corners do
			corner:Update(dt)
		end
	end)
end

local function onCarAdded(instance: Instance)
	if instance:IsA("Model") then
		setupCar(instance)
	end
end

for _, instance in CollectionService:GetTagged("Car") do
	onCarAdded(instance)
end
CollectionService:GetInstanceAddedSignal("Car"):Connect(onCarAdded)

-- Fallback for cars that aren't tagged: anything shaped like a car
-- (Chassis + Wheels + Body) sitting directly in Workspace or a "Cars" folder.
local function looksLikeCar(model: Model): boolean
	return model:FindFirstChild("Chassis") ~= nil
		and model:FindFirstChild("Wheels") ~= nil
		and not CollectionService:HasTag(model, "Car")
end

local function scanContainer(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Model") and looksLikeCar(child) then
			setupCar(child)
		end
	end
end

scanContainer(Workspace)
local carsFolder = Workspace:FindFirstChild("Cars")
if carsFolder then
	scanContainer(carsFolder)
end

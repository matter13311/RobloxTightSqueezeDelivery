-- Physically keeps anyone but a plot's owner - and anything but the owner's
-- own vehicle - out of that plot's CollisionBox once the plot is claimed.
-- This is what stops a bystander standing in the way while a car spawns, and
-- stops another player's vehicle ramming one that's parked.
--
-- Deliberately NOT solved with PhysicsService collision groups: the box needs
-- to be solid to everyone except one specific PLAYER and one specific VEHICLE
-- INSTANCE, and collision groups can only express "these two groups do/don't
-- collide" - there's no way to exempt a single instance from a group pairing
-- without pulling it out of the shared Vehicle/Default groups entirely, which
-- would also break its normal collision with the world and other cars. So
-- instead this continuously checks what's actually overlapping the box and
-- shoves out anything that isn't the owner's - the same "invisible force
-- field" trick used for out-of-bounds/safe zones elsewhere. Needs no changes
-- to the groups VehicleCollisionSetup.server.luau owns.
--
-- CollisionBox itself should stay CanCollide = false (it's a trigger, not a
-- wall - a solid one would shove the owner's own car around too) and
-- Transparency = 1. This script is what makes it solid in effect, and only
-- for everyone except the owner.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)

local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")
local VehicleFolder = workspace.Vehicles

-- How far past the box's surface an offender is shoved back out to, so it
-- doesn't land exactly on the boundary and immediately re-trigger next frame.
local PUSH_MARGIN = 1.5

-- [plotModel] = CollisionBox
local boxes = {}

local function trySetupPlot(plotModel)
	local box = plotModel:FindFirstChild("CollisionBox")
	if box and box:IsA("BasePart") then
		boxes[plotModel] = box
	end
end

for _, plotModel in VehiclePlotsFolder:GetChildren() do
	trySetupPlot(plotModel)
end
VehiclePlotsFolder.ChildAdded:Connect(trySetupPlot)
VehiclePlotsFolder.ChildRemoved:Connect(function(plotModel)
	boxes[plotModel] = nil
end)

-- Nearest point OUTSIDE `box`, exiting through whichever face `worldPosition`
-- is currently closest to - keeps offenders moving the shortest distance
-- rather than always ejecting them out one fixed side. Works for a rotated
-- box because the whole thing is done in the box's own local space.
local function nearestOutsidePoint(box, worldPosition)
	local localPos = box.CFrame:PointToObjectSpace(worldPosition)
	local half = box.Size / 2

	local bestAxis, bestDistance, bestSign = "X", math.huge, 1
	for _, axis in { "X", "Y", "Z" } do
		local toPositiveFace = half[axis] - localPos[axis]
		local toNegativeFace = half[axis] + localPos[axis]
		if toPositiveFace < bestDistance then
			bestAxis, bestDistance, bestSign = axis, toPositiveFace, 1
		end
		if toNegativeFace < bestDistance then
			bestAxis, bestDistance, bestSign = axis, toNegativeFace, -1
		end
	end

	local outside = bestSign * (half[bestAxis] + PUSH_MARGIN)
	local pushedLocal = Vector3.new(
		if bestAxis == "X" then outside else localPos.X,
		if bestAxis == "Y" then outside else localPos.Y,
		if bestAxis == "Z" then outside else localPos.Z
	)
	return box.CFrame:PointToWorldSpace(pushedLocal)
end

-- Moves `model` so `referencePart` lands on `newPosition`, keeping the
-- model's current rotation, and kills whatever velocity it had - otherwise a
-- car driven at speed would get ejected only to immediately drive right back
-- in.
local function shoveOutside(model, referencePart, box)
	local newPosition = nearestOutsidePoint(box, referencePart.Position)
	local pivot = model:GetPivot()
	model:PivotTo(pivot - pivot.Position + newPosition)
	referencePart.AssemblyLinearVelocity = Vector3.zero
	referencePart.AssemblyAngularVelocity = Vector3.zero
end

-- Walks up from `part` to the direct child of `container` that owns it (a
-- car's Chassis part -> the car Model directly under workspace.Vehicles; a
-- limb -> the character Model directly under workspace). Returns nil if
-- `part` isn't under `container` at all.
local function ancestorDirectlyUnder(part, container)
	local instance = part
	while instance and instance.Parent ~= container do
		instance = instance.Parent
	end
	return instance
end

local function enforcePlot(plotModel, box)
	local ownerUserId = PlotOwnership.GetOwnerUserId(plotModel)
	if not ownerUserId then
		return
	end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { box }

	local handledModels = {}
	for _, part in workspace:GetPartsInPart(box, overlapParams) do
		local carModel = ancestorDirectlyUnder(part, VehicleFolder)
		if carModel then
			if not handledModels[carModel] then
				handledModels[carModel] = true
				if VehicleOwnership.GetOwnerUserId(carModel) ~= ownerUserId and carModel.PrimaryPart then
					shoveOutside(carModel, carModel.PrimaryPart, box)
				end
			end
			continue
		end

		local character = ancestorDirectlyUnder(part, workspace)
		if character and not handledModels[character] then
			handledModels[character] = true
			local player = Players:GetPlayerFromCharacter(character)
			local rootPart = character:FindFirstChild("HumanoidRootPart")
			if player and player.UserId ~= ownerUserId and rootPart then
				shoveOutside(character, rootPart, box)
			end
		end
	end
end

RunService.Heartbeat:Connect(function()
	for plotModel, box in boxes do
		local ok, err = pcall(enforcePlot, plotModel, box)
		if not ok then
			warn("PlotCollisionGuard: failed to enforce " .. plotModel:GetFullName() .. ": " .. tostring(err))
		end
	end
end)

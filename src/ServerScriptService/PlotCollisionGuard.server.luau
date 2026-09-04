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

-- Nearest point OUTSIDE `box`, exiting through whichever SIDE face
-- `worldPosition` is currently closest to - keeps offenders moving the
-- shortest distance rather than always ejecting them out one fixed side.
-- Works for a rotated box because the whole thing is done in the box's own
-- local space.
--
-- Y is deliberately excluded. A plot box is much wider than it is tall, so
-- for anything sitting near the middle of one the *nearest* face is nearly
-- always the top or the bottom - and picking those means launching a car
-- into the air, or far worse, straight down through the floor and out of the
-- world. There is also no such thing as a useful vertical eject here: a plot
-- is entered and left horizontally, so the only exits that put an offender
-- somewhere they could actually have driven from are the four sides.
local EJECT_AXES = { "X", "Z" }

local function nearestOutsidePoint(box, worldPosition)
	local localPos = box.CFrame:PointToObjectSpace(worldPosition)
	local half = box.Size / 2

	local bestAxis, bestDistance, bestSign = "X", math.huge, 1
	for _, axis in EJECT_AXES do
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
	-- Y is carried through untouched, so the offender leaves at whatever
	-- height it was already at rather than being dropped or lifted.
	local pushedLocal = Vector3.new(
		if bestAxis == "X" then outside else localPos.X,
		localPos.Y,
		if bestAxis == "Z" then outside else localPos.Z
	)
	return box.CFrame:PointToWorldSpace(pushedLocal)
end

-- How long the server keeps physics authority over a vehicle it just shoved,
-- before handing ownership back to whoever is driving. Long enough to cover a
-- client->server->client round trip on a bad connection; short enough that a
-- driver who gets ejected never notices their car went briefly unresponsive.
local OWNERSHIP_HOLD = 0.5

-- [Model] = os.clock() at which physics authority goes back to automatic.
local heldVehicles = {}

-- Takes physics authority away from the driving client for a moment.
--
-- A driven car's assembly is network-owned by that client - it is their
-- RayCastSuspension loop applying every impulse, and their CFrame that wins.
-- So a bare server-side PivotTo on an occupied car is a suggestion, not a
-- move: the owning client's next replicated frame overwrites it, the car is
-- still inside the box, the guard fires again, and the two sides fight at the
-- boundary every Heartbeat - the car buzzes in place instead of leaving.
--
-- Pulling ownership to the server makes the teleport authoritative. The
-- client keeps running its drive loop meanwhile, but its impulses no longer
-- carry, and it snaps to the position the server hands it. Holding for a beat
-- afterwards (rather than releasing immediately) is what stops a CFrame that
-- was already in flight from putting the car back where it was.
local function holdAuthority(model, referencePart)
	if referencePart.Anchored then
		return -- an anchored part has no network owner to take
	end
	-- SetNetworkOwner throws on a part that isn't in a simulated assembly, and
	-- there is nothing useful to do about it if it does - the teleport below
	-- still runs, it just isn't protected from the client for this one frame.
	pcall(function()
		referencePart:SetNetworkOwner(nil)
	end)
	heldVehicles[model] = os.clock() + OWNERSHIP_HOLD
end

local function releaseExpiredAuthority()
	local now = os.clock()
	for model, releaseAt in heldVehicles do
		local referencePart = model.Parent and model.PrimaryPart
		if not referencePart then
			heldVehicles[model] = nil -- car was despawned while held
		elseif now >= releaseAt then
			heldVehicles[model] = nil
			if not referencePart.Anchored then
				pcall(function()
					referencePart:SetNetworkOwnershipAuto()
				end)
			end
		end
	end
end

-- Moves `model` so `referencePart` lands on `newPosition`, keeping the
-- model's current rotation, and kills whatever velocity it had - otherwise a
-- car driven at speed would get ejected only to immediately drive right back
-- in.
--
-- `takeAuthority` is for vehicles only. A player's own character is always
-- network-owned by that player and the server cannot take it, so there is
-- nothing to hold; characters rely on Roblox snapping them to a server-set
-- CFrame, which it does reliably enough for a walking-pace offender.
local function shoveOutside(model, referencePart, box, takeAuthority)
	if takeAuthority then
		holdAuthority(model, referencePart)
	end
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
					shoveOutside(carModel, carModel.PrimaryPart, box, true)
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
				shoveOutside(character, rootPart, box, false)
			end
		end
	end
end

RunService.Heartbeat:Connect(function()
	releaseExpiredAuthority()
	for plotModel, box in boxes do
		local ok, err = pcall(enforcePlot, plotModel, box)
		if not ok then
			warn("PlotCollisionGuard: failed to enforce " .. plotModel:GetFullName() .. ": " .. tostring(err))
		end
	end
end)

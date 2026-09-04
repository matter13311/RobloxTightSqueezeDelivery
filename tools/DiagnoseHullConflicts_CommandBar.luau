-- Not synced by Rojo. Run this DURING A PLAY TEST, with the command bar set to
-- Server context, while sitting in the car you want to check.
--
-- It answers one question: which parts of this car will fight its collision
-- hulls, and shake the truck apart?
--
-- The rule Roblox actually follows is this. Parts rigidly joined together
-- (welds, WeldConstraints, Motor6Ds) form ONE assembly, and two parts in the
-- same assembly NEVER collide with each other no matter how badly they
-- overlap. Two parts in DIFFERENT assemblies collide normally. A
-- HingeConstraint does not join parts into one assembly - that is the whole
-- point of a hinge - so a door is its own assembly, and a door overlapping a
-- flank hull is two separate bodies trying to occupy one space. The solver
-- shoves them apart, the hinge servo drags the door back, and the truck
-- vibrates itself to bits.
--
-- So: overlapping the hulls is fine. Overlapping the hulls FROM ANOTHER
-- ASSEMBLY, while collidable, is the bug. That is what this lists.
--
-- Run it while DRIVING (not parked). A parked car is fully Anchored, which
-- collapses the assembly question and makes the answers meaningless.

local PhysicsService = game:GetService("PhysicsService")

local VehicleCollision = require(game.ReplicatedStorage.Modules.Vehicles.VehicleCollision)

local VehicleFolder = workspace.Vehicles

local function diagnose(carModel)
	local chassis = carModel.PrimaryPart
	local hulls = VehicleCollision.GetHullFolder(carModel)
	if not chassis or not hulls then
		return
	end

	if chassis.Anchored then
		warn(("[Diagnose] %s is Anchored (parked). Get in and drive it, then run this again."):format(carModel.Name))
		return
	end

	local chassisRoot = chassis:GetRootPart()

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Include
	overlapParams.FilterDescendantsInstances = { carModel }
	overlapParams.MaxParts = 200

	local offenders = {}
	for _, hull in hulls:GetDescendants() do
		if not hull:IsA("BasePart") then
			continue
		end
		for _, other in workspace:GetPartsInPart(hull, overlapParams) do
			if other == hull or other:IsDescendantOf(hulls) then
				continue
			end
			if not other.CanCollide then
				continue
			end
			-- Same assembly as the chassis means it can never collide with the
			-- hulls, however much it overlaps them. Not a problem.
			if other:GetRootPart() == chassisRoot then
				continue
			end
			-- Nor is it a problem if the collision groups already say these two
			-- can't touch - which is the whole fix, so without this check the
			-- report keeps naming parts that have already been dealt with.
			-- GetPartsInPart is a geometry query and ignores groups entirely.
			if not PhysicsService:CollisionGroupsAreCollidable(hull.CollisionGroup, other.CollisionGroup) then
				continue
			end
			offenders[other] = hull.Name
		end
	end

	print(("=== %s ==="):format(carModel:GetFullName()))
	local count = 0
	for part, hullName in offenders do
		count += 1
		print(("  CONFLICT  %-40s overlaps %s   [group: %s]"):format(
			part:GetFullName():gsub("^" .. carModel:GetFullName() .. "%.", ""),
			hullName,
			part.CollisionGroup
		))
	end
	if count == 0 then
		print("  no conflicts - every collidable part overlapping a hull is in the chassis assembly")
	else
		print(("  %d part(s) will fight the hulls. Either move the hull clear of them, or put them in the"):format(count))
		print(("  '%s' collision group so they stop colliding with vehicle geometry."):format(
			VehicleCollision.Groups.Attached
		))
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	if carModel:IsA("Model") then
		diagnose(carModel)
	end
end

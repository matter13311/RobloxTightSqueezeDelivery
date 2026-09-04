-- Registers the collision groups and normalises collision properties on every
-- car, so a crash resolves against a shape you authored rather than against
-- whatever hull Roblox guessed from a mesh.
--
-- Separate from Raycast.server.luau on purpose: that script owns a car's
-- LIFECYCLE (welding, settling, anchoring, network ownership) and this one
-- only ever writes CollisionGroup / CanCollide / CustomPhysicalProperties,
-- which no other script touches. The two can run in either order.
--
-- The one thing this does NOT do is change any part's mass. This truck's
-- Stiffness, Torque and BrakeFriction are all tuned against its current
-- chassis mass and none of them scale with it (see the comments in
-- Configs/StarterTruck.luau), so quietly making body panels Massless here would
-- silently drop the ride height and change how the whole car drives. The hull
-- boxes are created Massless instead, which leaves total mass exactly as it
-- was.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)

local VehicleFolder = workspace.Vehicles
local Groups = VehicleCollision.Groups

-- Elasticity 0 at weight 100. Roblox blends the two surfaces in a contact by
-- their elasticity WEIGHTS, so a weight of 100 against a default part's 1 means
-- "this contact does not bounce", regardless of what the building is made of.
-- Without the weight, a default wall at elasticity 0.5 drags the blend back up
-- and the truck pings off it again.
--
-- Density and friction are read back off the part and put straight back
-- unchanged - only the two elasticity fields are rewritten. Writing a whole
-- fresh PhysicalProperties here would overwrite density, which is the same as
-- overwriting mass, and this truck's Stiffness, Torque and BrakeFriction are
-- all tuned against its current mass and none of them scale with it. The wheel
-- meshes in particular carry a deliberate density of their own.
local function makeNonBouncy(part)
	local current = part.CurrentPhysicalProperties
	part.CustomPhysicalProperties =
		PhysicalProperties.new(current.Density, current.Friction, 0, current.FrictionWeight, 100)
end

-- RegisterCollisionGroup throws if the group already exists, which it will if
-- it was created by hand in Studio's Collision Groups editor or if this script
-- somehow runs twice. Existing is the desired end state either way.
local function ensureGroup(name)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

ensureGroup(Groups.Vehicle)
ensureGroup(Groups.Cosmetic)
ensureGroup(Groups.Attached)
ensureGroup(Groups.Debris)

-- Hulls collide with the world and with each other. Car-vs-car is ON: the
-- physics cost of a handful of boxes per car is nothing, and with parked cars
-- fully Anchored (Raycast.server.luau) the only genuinely expensive case -
-- two client-owned assemblies disagreeing about where they each are - is
-- limited to two players actively driving into each other.
PhysicsService:CollisionGroupSetCollidable(Groups.Vehicle, "Default", true)
PhysicsService:CollisionGroupSetCollidable(Groups.Vehicle, Groups.Vehicle, true)

-- Body panels become pure decoration once hulls exist. They collide with
-- nothing at all, which is the entire point - their mesh hulls were the
-- problem.
PhysicsService:CollisionGroupSetCollidable(Groups.Cosmetic, "Default", false)
PhysicsService:CollisionGroupSetCollidable(Groups.Cosmetic, Groups.Vehicle, false)
PhysicsService:CollisionGroupSetCollidable(Groups.Cosmetic, Groups.Cosmetic, false)
PhysicsService:CollisionGroupSetCollidable(Groups.Cosmetic, Groups.Debris, false)

-- Everything on the car that is not its shape: seats, the frame, the steering
-- wheel, wheels, mirrors, and any prop added later. Most of these are welded
-- into the chassis assembly and so could never have collided with the hulls
-- anyway - the group exists for the ones that AREN'T, which is the case that
-- shook the truck apart when doors were still hinged. Keeping the rule general
-- means the next unwelded prop is handled before anyone notices it needed to
-- be. They keep their collision against the world and against players, and
-- lose it only against vehicle geometry.
PhysicsService:CollisionGroupSetCollidable(Groups.Attached, "Default", true)
PhysicsService:CollisionGroupSetCollidable(Groups.Attached, Groups.Vehicle, false)
PhysicsService:CollisionGroupSetCollidable(Groups.Attached, Groups.Cosmetic, false)
PhysicsService:CollisionGroupSetCollidable(Groups.Attached, Groups.Attached, false)
PhysicsService:CollisionGroupSetCollidable(Groups.Attached, Groups.Debris, false)

-- Knocked-off panels tumble along the road but can never shove a car. A wing
-- mirror that has just come off should not be able to push a truck off its
-- line, and a pile of them should not be able to barricade a street.
PhysicsService:CollisionGroupSetCollidable(Groups.Debris, "Default", true)
PhysicsService:CollisionGroupSetCollidable(Groups.Debris, Groups.Vehicle, false)
PhysicsService:CollisionGroupSetCollidable(Groups.Debris, Groups.Debris, false)

local function setUpCar(carModel)
	local hulls = VehicleCollision.GetHullFolder(carModel)
	local body = VehicleCollision.GetBodyFolder(carModel)

	for _, part in carModel:GetDescendants() do
		if not part:IsA("BasePart") then
			continue
		end

		local isHull = hulls ~= nil and part:IsDescendantOf(hulls)
		local isBody = body ~= nil and part:IsDescendantOf(body)
		local isChassis = part == carModel.PrimaryPart

		if isHull or isBody or isChassis then
			makeNonBouncy(part)
		end

		if isChassis then
			-- The chassis is real collision geometry too - it's what a car
			-- without hulls collides on, and it stays as a backstop for one
			-- that has them. Grouping it with the hulls rather than leaving it
			-- in Default is what puts every piece of "the car's shape" in one
			-- group, which is what everything else can then be excluded from.
			part.CollisionGroup = Groups.Vehicle
		elseif isHull then
			part.CollisionGroup = Groups.Vehicle
			part.CanCollide = true
			part.CanTouch = true
			part.Massless = true -- the mass stays in the Chassis; see the note at the top
		elseif isBody then
			if hulls then
				-- Hulls are the car's shape now, so the panels stop colliding.
				part.CollisionGroup = Groups.Cosmetic
				part.CanCollide = false
				part.CanQuery = false

				-- A MeshPart keeps generating and storing a collision hull even
				-- when it collides with nothing, and that hull is what Studio's
				-- collision-performance view is costing when it paints a panel
				-- orange or red. Box is the cheapest fidelity there is, and for
				-- a part that can never touch anything its shape is irrelevant.
				-- pcall'd because CollisionFidelity is only writable at runtime
				-- on recent engine versions - failing to optimise is fine,
				-- erroring out of the whole car's setup is not.
				if part:IsA("MeshPart") and part.CollisionFidelity ~= Enum.CollisionFidelity.Box then
					pcall(function()
						part.CollisionFidelity = Enum.CollisionFidelity.Box
					end)
				end
			else
				-- No hull folder authored for this car yet. The meshes still
				-- have to be the shape, warts and all - better a car that
				-- collides badly than one that drives through walls.
				part.CollisionGroup = Groups.Vehicle
			end

		else
			-- EVERYTHING ELSE on the car - doors, mirrors, seats, the frame,
			-- the steering wheel, wheels, and whatever gets added next year.
			--
			-- This is a whitelist rather than a list of exceptions on purpose,
			-- and that is the whole design. The hulls and the chassis ARE the
			-- car's shape; nothing else on the vehicle has any business
			-- colliding with them. Naming the exceptions instead (doors, then
			-- mirrors, then the next thing) means the truck shakes itself apart
			-- every time someone bolts a new prop onto it, and the symptom
			-- looks nothing like the cause.
			--
			-- These parts keep their collision against the world and against
			-- players: an open door still hits a lamp post and still can't be
			-- walked through. They lose it only against vehicle geometry.
			--
			-- Set as a CollisionGroup and deliberately not as CanCollide,
			-- because VehicleDoors toggles CanCollide on door parts while a
			-- player steps out and would turn anything set there straight back
			-- on. The group survives that.
			part.CollisionGroup = Groups.Attached
		end
	end

	-- Damage bookkeeping, over every folder damage can touch rather than just
	-- Body - mirrors are knocked off the same way panels are. Set here rather
	-- than lazily in the damage script so a builder can watch these tick down
	-- in the Properties window while play-testing.
	for _, part in VehicleCollision.GetDetachableParts(carModel) do
		if part:GetAttribute(VehicleCollision.HEALTH_ATTRIBUTE) == nil then
			part:SetAttribute(VehicleCollision.HEALTH_ATTRIBUTE, VehicleCollision.GetMaxHealth(part))
		end
	end

	carModel:SetAttribute(VehicleCollision.CONDITION_ATTRIBUTE, 1)

	if not hulls then
		warn(
			"VehicleCollisionSetup: "
				.. carModel:GetFullName()
				.. " has no Collision folder - it will collide using its mesh hulls, which is what makes cars clip into each other. Run tools/BuildCollisionHulls_CommandBar.luau on it."
		)
	end
end

-- Same pcall-per-car shape as Raycast.server.luau's TryAddCar: one
-- misconfigured truck must not take the rest of the fleet down with it.
local function trySetUpCar(carModel)
	if not carModel:IsA("Model") then
		return
	end
	local ok, err = pcall(setUpCar, carModel)
	if not ok then
		warn("VehicleCollisionSetup: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	trySetUpCar(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetUpCar)

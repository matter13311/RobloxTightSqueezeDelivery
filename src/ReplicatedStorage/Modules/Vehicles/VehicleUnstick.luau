-- "Is this character inside a car, and if so, get them out of it."
--
-- Two questions, one module, because the answer to the first is what the
-- second needs and three scripts were about to ask it three different ways.
--
-- WHY A CHARACTER CAN EVER BE INSIDE A CAR AT ALL, given that a car is solid
-- and a player is solid: because for short, deliberate windows they are NOT
-- solid to each other. Three separate features move a character into a
-- collision group that cannot touch vehicle geometry -
--
--   * RagdollUtility's PlayerRagdoll, so a truck drives through somebody it
--     just knocked down instead of grinding to a halt on their limbs.
--   * VehicleDoors' ExitGrace, so a passenger jump-exiting isn't shoved by
--     the car they were sitting in a frame ago.
--   * VehiclePlayerImpact's reuse of the same group, so a player leaning on a
--     car that is still settling onto its wheels can't push it around.
--
-- Every one of those is right, and every one of them has the same failure
-- mode: while it is in effect the player can fall THROUGH the car - off the
-- roof, into the cab - and when it lapses they are restored to ordinary
-- collision from inside solid geometry. Roblox's answer to that is either to
-- fire them out at speed or, if the overlap is deep enough that there is no
-- shortest way out, to hold them there permanently. That second case is the
-- "stuck under my own truck until I respawn" report, and no amount of tuning
-- the grace windows removes it: as long as a character can be non-solid to a
-- car at all, something has to be able to get them back out.
--
-- So this module is the escape hatch, and it is deliberately blunt: find a
-- clear patch of ground beside the car and put the character on it. A teleport
-- of a few studs is a far smaller intrusion than a respawn, which is what the
-- player does otherwise.

local VehicleUnstick = {}

local VehicleFolder = workspace:WaitForChild("Vehicles")

-- Padding on the overlap test, in studs, for the "is it safe to stand up here"
-- question. Generous on purpose: restoring collision a hair outside a hull is
-- still a shove, so a ragdoll waits until it is properly clear.
VehicleUnstick.StandUpPadding = 2

-- Studs of clearance past the car's own footprint for the spot a stuck
-- character is moved to. Enough that they land beside the truck rather than
-- against it.
local ESCAPE_CLEARANCE = 4
local ESCAPE_RINGS = { 0, 4, 10 } -- extra distance to try if the first ring is blocked

-- A character-sized volume, used to check a candidate escape spot is actually
-- empty before anybody is put in it.
local ESCAPE_PROBE_SIZE = Vector3.new(4, 6, 4)

local function vehicleOverlapParams()
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { VehicleFolder }
	-- Cosmetic body panels, plot trigger volumes and the like are all
	-- non-collidable, so being "inside" one of those is not being inside
	-- anything. Only the hulls and the chassis - the car's real shape - count.
	params.RespectCanCollide = true
	return params
end

-- The car a character is currently intersecting, or nil.
--
-- Measured from the HumanoidRootPart alone rather than from every limb: an
-- outstretched arm clipping a wing mirror is not "inside the truck", and on a
-- ragdoll the limbs are strewn over a couple of studs in every direction and
-- would report an overlap for anybody lying next to a car.
--
-- `padding` widens the box. Zero means "the root is genuinely intersecting
-- solid car geometry", which is the test for stuck; a couple of studs means
-- "close enough that becoming solid here would be a shove", which is the test
-- for standing up.
function VehicleUnstick.FindOverlappingVehicle(character, padding)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local size = root.Size + Vector3.one * (padding or 0)
	for _, part in workspace:GetPartBoundsInBox(root.CFrame, size, vehicleOverlapParams()) do
		-- Walk up to whatever workspace.Vehicles' own child this part belongs
		-- to, rather than to the nearest Model ancestor - a hull's parent
		-- chain can have folders and sub-models in it, and the car is the top
		-- of that chain, not the first Model on the way up.
		local car = part
		while car.Parent and car.Parent ~= VehicleFolder do
			car = car.Parent
		end
		if car.Parent == VehicleFolder and car:IsA("Model") then
			return car
		end
	end
	return nil
end

function VehicleUnstick.IsInsideAVehicle(character, padding)
	return VehicleUnstick.FindOverlappingVehicle(character, padding) ~= nil
end

-- Blocks until the character is clear of every car, or until `maxSeconds` has
-- passed, whichever comes first. Returns true if they got clear.
--
-- This is what turns the fixed-length collision graces into "as short as they
-- need to be": a player who steps out of a truck and walks two paces away is
-- solid again immediately instead of spending the rest of the window able to
-- fall through the roof they just climbed onto.
function VehicleUnstick.WaitUntilClear(character, maxSeconds, padding)
	local deadline = os.clock() + maxSeconds
	while os.clock() < deadline do
		if not character.Parent then
			return false
		end
		if not VehicleUnstick.IsInsideAVehicle(character, padding) then
			return true
		end
		task.wait(0.1)
	end
	return not VehicleUnstick.IsInsideAVehicle(character, padding)
end

--=============================================================================
-- Getting out
--=============================================================================

local function groundedSpot(fromPosition, character)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- The car is excluded as well as the character: dropping onto the truck's
	-- own roof is not being clear of it.
	params.FilterDescendantsInstances = { character, VehicleFolder }
	params.IgnoreWater = true

	local hit = workspace:Raycast(fromPosition + Vector3.new(0, 20, 0), Vector3.new(0, -80, 0), params)
	if not hit then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local lift = (root and root.Size.Y / 2 or 1) + (humanoid and humanoid.HipHeight or 2) + 0.5
	local spot = hit.Position + Vector3.new(0, lift, 0)

	-- Somewhere with ground under it is no good if the car is over it - the
	-- underside of a truck has plenty of both.
	if #workspace:GetPartBoundsInBox(CFrame.new(spot), ESCAPE_PROBE_SIZE, vehicleOverlapParams()) > 0 then
		return nil
	end
	return spot
end

-- Moves a character to the nearest clear patch of ground beside `carModel`.
--
-- Candidates are the four sides of the car rather than "away from the car's
-- centre", because the direction out from under a truck is not the direction
-- away from its middle - a body pinned under the chassis is closest to the
-- centre of the car in every direction at once. Four sides, nearest usable
-- one wins, and each ring further out is tried only if the one before it was
-- blocked (by a wall, another car, a plot barrier).
--
-- Returns true if the character was moved.
function VehicleUnstick.MoveClear(character, carModel)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	if not carModel or not carModel:IsA("Model") then
		return false
	end

	local carCF, carSize = carModel:GetBoundingBox()
	local from = root.Position

	local best, bestDistance = nil, math.huge
	for _, extra in ESCAPE_RINGS do
		local sideways = carSize.X / 2 + ESCAPE_CLEARANCE + extra
		local lengthways = carSize.Z / 2 + ESCAPE_CLEARANCE + extra
		for _, offset in
			{
				Vector3.new(sideways, 0, 0),
				Vector3.new(-sideways, 0, 0),
				Vector3.new(0, 0, lengthways),
				Vector3.new(0, 0, -lengthways),
			}
		do
			local spot = groundedSpot(carCF * offset, character)
			if spot then
				local distance = (spot - from).Magnitude
				if distance < bestDistance then
					best, bestDistance = spot, distance
				end
			end
		end
		if best then
			break -- nothing in a wider ring can be nearer than something in this one
		end
	end

	-- Every side blocked - hemmed in between two trucks in a loading bay, say.
	-- The roof is not a nice place to be put, but it is out, and gravity
	-- finishes the job.
	if not best then
		best = (carCF * CFrame.new(0, carSize.Y / 2 + 4, 0)).Position
	end

	-- Keep their facing; only the position is anybody's business here. PivotTo
	-- moves every part in the model as one, which matters for a ragdoll: its
	-- limbs are loose bodies, and moving the root alone would leave them to
	-- whip back into place through the sockets from wherever they were left.
	character:PivotTo(CFrame.new(best) * (root.CFrame - root.Position))

	-- A body that has been ground against a hull for a few seconds has
	-- whatever velocity the solver was pushing it out with; carrying that into
	-- the new spot launches them across the street.
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end

	return true
end

return VehicleUnstick

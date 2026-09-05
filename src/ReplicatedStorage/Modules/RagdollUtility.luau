-- Turns a character into an honest physics ragdoll and back.
--
-- Setting Humanoid.PlatformStand alone (the previous approach) does NOT
-- ragdoll a character - it only stops the Humanoid's own controller from
-- re-asserting an upright walking pose every frame. Every body part is still
-- rigidly welded to every other one by Motor6Ds (that's what a rig IS), so
-- the whole character keeps its animated pose and falls as one stiff plank -
-- which is exactly the "legs clip through the floor, still standing up"
-- symptom this replaces.
--
-- A real ragdoll means cutting those rigid joints and replacing them with
-- something that can actually bend: a BallSocketConstraint per joint, built
-- from that joint's own C0/C1 so it needs no per-rig-type knowledge (works
-- on R15, R6, or anything else built out of Motor6Ds). With nothing rigid
-- holding the limbs in their animated pose anymore, gravity and momentum do
-- the rest - the body folds, spreads out, and settles flat instead of
-- toppling over as a single rigid mannequin.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)

local RagdollUtility = {}

-- A shared group for every character currently ragdolled, the same idea as
-- VehicleCollision.Groups.Debris: collides with the world and with a standing
-- player completely normally, but never with itself - without that, a
-- ragdoll's own limbs would fight each other for space right at the joint
-- that's supposed to hold them together, and the constraint would fling them
-- apart instead.
--
-- And, as of the pedestrian-impact work, never with a VEHICLE either. That
-- one rule is what makes being run over feel like being run over: the truck
-- keeps its speed and drives clean through the body instead of grinding to a
-- halt on it. A limp character is a dozen loose limbs, each its own physics
-- body, each of them briefly overlapping a hull box that is moving at 60
-- studs/s - the solver's answer to that is to shove everything apart as hard
-- as it takes, which throws the ragdoll into orbit and jolts the truck. The
-- knockdown velocity applied in VehiclePlayerImpact is the authored,
-- repeatable version of the same thing, and it can only be trusted to be the
-- ONLY thing acting on the body if the contact never happens.
--
-- Standing players are deliberately untouched by this: they are in Default and
-- collide with vehicles exactly as before, so nobody walks through a parked
-- truck and nobody falls through the bed of one they are standing on. The
-- pass-through is a property of BEING KNOCKED DOWN, and it lasts as long as
-- the knockdown does.
local RAGDOLL_GROUP = "PlayerRagdoll"

local function ensureGroup(name)
	-- RegisterCollisionGroup throws if the group already exists (another
	-- character ragdolling first, or a hot-reload in Studio). Existing is
	-- the desired end state either way - see the identical pattern in
	-- VehicleCollisionSetup.server.luau.
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

ensureGroup(RAGDOLL_GROUP)
PhysicsService:CollisionGroupSetCollidable(RAGDOLL_GROUP, RAGDOLL_GROUP, false)

-- Every group that makes up a car, not just the hulls. Wheels, doors and
-- mirrors live in Attached and keep their collision against players, so a
-- front wheel would happily catch a body the chassis was set up to pass
-- through - and one wheel is all it takes to drag a ragdoll under the truck
-- and along the road with it. Cosmetic is listed for completeness: it
-- collides with nothing else in the game, and leaving this one pair out would
-- make it the single exception.
for _, group in { VehicleCollision.Groups.Vehicle, VehicleCollision.Groups.Attached, VehicleCollision.Groups.Cosmetic } do
	ensureGroup(group) -- may not exist yet; VehicleCollisionSetup is a server script and this module is shared
	PhysicsService:CollisionGroupSetCollidable(RAGDOLL_GROUP, group, false)
end

-- [Model] = { { Motor, Attachment0, Attachment1, Socket }, ... } for every
-- joint that was cut, so Stop can put the exact same joints back.
local activeRagdolls = {}

function RagdollUtility.IsRagdolled(character)
	return activeRagdolls[character] ~= nil
end

-- Cuts every Motor6D in the character and bridges the gap with a
-- BallSocketConstraint, so the rig can bend, fold and spread out under
-- gravity instead of falling as one rigid animated pose. Safe to call on an
-- already-ragdolled character - it's a no-op, so a second hit while someone
-- is still down never double-builds the rig.
function RagdollUtility.Start(character)
	if RagdollUtility.IsRagdolled(character) then
		return
	end

	local joints = {}
	for _, motor in character:GetDescendants() do
		if motor:IsA("Motor6D") and motor.Part0 and motor.Part1 then
			motor.Enabled = false

			-- Built from the motor's OWN C0/C1 rather than looked up by a
			-- naming convention (R15's "XRigAttachment" pairs) - this way it
			-- doesn't care whether the rig is R15, R6, or anything else, and
			-- it's exactly where the joint already was, so nothing pops when
			-- the ragdoll begins.
			local attachment0 = Instance.new("Attachment")
			attachment0.Name = "RagdollAttachment"
			attachment0.CFrame = motor.C0
			attachment0.Parent = motor.Part0

			local attachment1 = Instance.new("Attachment")
			attachment1.Name = "RagdollAttachment"
			attachment1.CFrame = motor.C1
			attachment1.Parent = motor.Part1

			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = attachment0
			socket.Attachment1 = attachment1
			-- Limited, not free - an unlimited socket lets a hip or shoulder
			-- spin through a full circle, which reads as broken rather than
			-- knocked down. 60 degrees is loose enough to fold and spread
			-- out flat but stops short of a joint bending inside-out.
			socket.LimitsEnabled = true
			socket.UpperAngle = 60
			socket.TwistLimitsEnabled = true
			socket.TwistUpperAngle = 30
			socket.TwistLowerAngle = -30
			socket.Parent = motor.Part0

			table.insert(joints, { Motor = motor, Attachment0 = attachment0, Attachment1 = attachment1, Socket = socket })
		end
	end

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = RAGDOLL_GROUP
			part.CanCollide = true
		end
	end

	activeRagdolls[character] = joints

	-- The character is about to be destroyed on respawn regardless, but
	-- clearing this frees the joint table (and everything it references)
	-- the moment death happens rather than leaving it pinned in this module
	-- until something else happens to overwrite the key.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Once(function()
			activeRagdolls[character] = nil
		end)
	end
end

-- Removes the constraints and re-enables the original Motor6Ds, snapping the
-- rig back to whatever pose its Animator currently says it should be in.
-- Safe to call on a character that isn't ragdolled.
function RagdollUtility.Stop(character)
	local joints = activeRagdolls[character]
	if not joints then
		return
	end
	activeRagdolls[character] = nil

	for _, joint in joints do
		joint.Socket:Destroy()
		joint.Attachment0:Destroy()
		joint.Attachment1:Destroy()
		if joint.Motor.Parent then
			joint.Motor.Enabled = true
		end
	end

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Default"
		end
	end
end

return RagdollUtility

-- The rules and shared geometry behind a claimed plot's invisible wall.
--
-- WHY THIS REPLACED THE OLD "SHOVE THEM BACK OUT" GUARD
-- -----------------------------------------------------
-- The first version of this feature left CollisionBox as a non-colliding
-- trigger and had the SERVER watch what overlapped it, teleporting offenders
-- back outside every Heartbeat. That cannot feel like a wall, and the reason
-- is structural rather than a tuning problem:
--
--   * A wall stops you BEFORE you are inside it. A trigger can only notice
--     you AFTER you are inside it. By the time the check runs you are already
--     a body-width in, so the correction is always a teleport, never a stop.
--   * Both a character and a driven car are simulated on THEIR OWN CLIENT,
--     not on the server. So the server's teleport and the client's next
--     replicated frame disagree, and they keep disagreeing at the boundary -
--     which is what the ragdolling and the "stuck in a wall taking crash
--     damage" both were. Taking network ownership for half a second papered
--     over it for cars, and could do nothing at all for characters, which the
--     server can never own.
--
-- The fix is to put the wall on the machine that is actually doing the
-- physics. Each CLIENT builds its own local, anchored, solid copy of every
-- CollisionBox it is not allowed into (see PlotBarriers.client.luau). Because
-- that client simulates its own character and whatever car it is sitting in,
-- the solver stops it at the surface exactly like any other anchored part -
-- no overlap, no correction, nothing to fight. And because the part exists
-- only on that client, it does not exist for the plot's OWNER at all, and it
-- does not exist on the server, so a car parked in its own bay is never
-- shoved around by its own bay's wall.
--
-- That is the "CanCollide = false for one player, true for everyone else"
-- the old header said was impossible with collision groups. It is impossible
-- with collision groups - a group pairing is one server-wide rule - but it is
-- easy with per-client geometry, because collision is resolved per-machine.
--
-- The server keeps a much weaker role: it ejects anyone standing in a plot at
-- the moment it gets claimed, and it sweeps for offenders who are DEEPLY
-- inside a box - something an honest client can no longer produce, so that
-- half is purely an exploiter backstop. See PlotCollisionGuard.server.luau.
--
-- The CollisionBox in Workspace stays CanCollide = false, CanQuery = false,
-- Transparency = 1 and Anchored on the server. It is a description of a
-- volume, not a wall; the wall is each client's own copy of it.

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)
local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)

local PlotBarrier = {}

PlotBarrier.BOX_NAME = "CollisionBox"

--=============================================================================
-- Collision group
--=============================================================================

-- The local wall gets its own group purely so it can OPT OUT of a couple of
-- pairings (see RegisterGroup). Note this group is NOT what decides who is
-- kept out of a plot - that is decided by which client the wall exists on.
-- Wheels are worth calling out among the things it deliberately still hits:
-- a wall that only stopped hulls would let a car ride its front wheels into
-- the bay before anything caught it.
PlotBarrier.GROUP = "PlotBarrier"

local function ensureGroup(name)
	-- Throws if the group already exists, which it will on a Studio
	-- hot-reload. Existing is the desired end state either way - same pattern
	-- as RagdollUtility and VehicleCollisionSetup.
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

-- Called by the server only (PlotCollisionGuard), NOT at require time, because
-- registering groups and setting their pairings is a server-side operation.
-- The registry itself replicates, so a client can assign a part to this group
-- without ever calling PhysicsService - which is all PlotBarriers.client.luau
-- needs to do.
--
-- Cosmetic collides with nothing in this game by contract, and debris is junk
-- that despawns - neither should be caught on, or pile up against, a wall
-- nobody can see. Barriers never touch each other either: adjacent plots'
-- boxes may well overlap, and two anchored parts fighting is a nonsense
-- contact. Everything else is left at a new group's default of "collides",
-- which is what puts characters (Default), the car's hulls (Vehicle) and its
-- wheels, doors and mirrors (Attached) all into the wall normally.
function PlotBarrier.RegisterGroup()
	ensureGroup(PlotBarrier.GROUP)
	for _, group in { VehicleCollision.Groups.Cosmetic, VehicleCollision.Groups.Debris, PlotBarrier.GROUP } do
		ensureGroup(group) -- may not be registered yet, depending on script order
		PhysicsService:CollisionGroupSetCollidable(PlotBarrier.GROUP, group, false)
	end
end

--=============================================================================
-- Tuning
--=============================================================================

-- Clearance, in studs, a client needs from a box before that box's wall turns
-- solid FOR THEM. This is the whole anti-trap guarantee: a wall never appears
-- around you, only in front of you, so there is no state in which you are
-- inside something solid and have to respawn to get out.
--
-- TUNING: too small and a plot claimed while you are brushing the entrance
-- can close on you. Too large and someone loitering at the mouth of a bay
-- holds their own wall open - the answer to that is the server sweep below,
-- not a bigger number here.
PlotBarrier.ARM_CLEARANCE = 2.5

-- If a client ever finds itself inside an already-solid wall - a respawn, an
-- admin teleport, tunnelling through at high speed - the wall goes soft again
-- until it is clear. Measured against the CENTRE of the character or car and
-- inset on top of that, because leaning on a wall puts part of you a fraction
-- past its surface every frame (that is what a solver contact is), and
-- reading that as "trapped" would switch the wall off precisely when it was
-- working.
PlotBarrier.DISARM_INSET = 1.5

-- How far inside a box the server treats as "cannot have got there honestly".
-- An honest client is stopped at the surface, so anything whose centre is
-- this deep either removed its barrier or was put there by something other
-- than walking and driving.
PlotBarrier.BACKSTOP_INSET = 4

-- Seconds between server sweeps. Deliberately slow: this is an exploit
-- backstop, not a physics loop, and running it every Heartbeat is exactly
-- what made the old version fight the client.
PlotBarrier.BACKSTOP_INTERVAL = 0.5

-- How far past a box's surface an ejected offender is placed, so they don't
-- land exactly on the boundary and immediately re-trigger.
PlotBarrier.PUSH_MARGIN = 1.5

--=============================================================================
-- Appearance
--=============================================================================

-- The wall is invisible until you are close to it, then ghosts in. Without
-- this the feature is indistinguishable from a bug - you walk into thin air,
-- stop, and nothing on screen says why. Fading only when near keeps the
-- garage looking like a garage from anywhere else in the map.
PlotBarrier.VISIBLE_DISTANCE = 18 -- studs from the box's nearest SIDE face
PlotBarrier.VISIBLE_TRANSPARENCY = 0.9 -- at its most solid-looking; a hint, not a fence
PlotBarrier.FADE_SPEED = 5 -- transparency units per second, so it never pops
PlotBarrier.COLOR = Color3.fromRGB(255, 96, 96)

--=============================================================================
-- Rules
--=============================================================================

-- The one question every side asks: is this plot closed to this user?
-- Unclaimed plots are open to everybody, which is what keeps the garage
-- usable before anyone has claimed anything.
function PlotBarrier.IsClosedTo(plotModel, userId)
	local ownerUserId = PlotOwnership.GetOwnerUserId(plotModel)
	return ownerUserId ~= nil and ownerUserId ~= userId
end

--=============================================================================
-- Geometry
--=============================================================================

-- Whether `worldPosition` is inside `box`, with the box's X/Z extents grown
-- (positive `margin`) or shrunk (negative) first.
--
-- Y is compared against the box's real height, unexpanded: a plot box is much
-- wider than it is tall, and growing the height is how you end up treating
-- somebody on a roof above a bay as though they were standing in it.
function PlotBarrier.IsPositionInside(box, worldPosition, margin)
	local localPos = box.CFrame:PointToObjectSpace(worldPosition)
	local half = box.Size / 2
	return math.abs(localPos.X) <= half.X + margin
		and math.abs(localPos.Z) <= half.Z + margin
		and math.abs(localPos.Y) <= half.Y
end

-- Nearest point OUTSIDE `box`, exiting through whichever SIDE face
-- `worldPosition` is closest to, so an offender moves the shortest distance
-- rather than always leaving through one fixed side. Done entirely in the
-- box's own local space, so it works on a rotated box.
--
-- Y is deliberately excluded from the choice of face. A plot box is much
-- wider than it is tall, so for anything near the middle of one the nearest
-- face is nearly always the top or the bottom - and picking those means
-- launching a car into the air, or far worse, straight down through the floor
-- and out of the world. There is also no useful vertical exit here: a plot is
-- entered and left horizontally, so the four sides are the only exits that
-- put an offender somewhere they could plausibly have come from.
local EJECT_AXES = { "X", "Z" }

function PlotBarrier.NearestOutsidePoint(box, worldPosition)
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

	local outside = bestSign * (half[bestAxis] + PlotBarrier.PUSH_MARGIN)
	-- Y is carried through untouched, so the offender leaves at whatever
	-- height they were already at rather than being dropped or lifted.
	local pushedLocal = Vector3.new(
		if bestAxis == "X" then outside else localPos.X,
		localPos.Y,
		if bestAxis == "Z" then outside else localPos.Z
	)
	return box.CFrame:PointToWorldSpace(pushedLocal)
end

-- Signed horizontal distance from the box's SURFACE to `worldPosition` -
-- negative inside, positive outside. Used for the proximity fade, so the wall
-- lights up when you are near the face you would actually walk into rather
-- than when you are near its centre (a long bay's centre can be twenty studs
-- back from its own entrance).
function PlotBarrier.HorizontalDistanceToSurface(box, worldPosition)
	local localPos = box.CFrame:PointToObjectSpace(worldPosition)
	local half = box.Size / 2
	local outsideX = math.abs(localPos.X) - half.X
	local outsideZ = math.abs(localPos.Z) - half.Z
	if outsideX <= 0 and outsideZ <= 0 then
		return math.max(outsideX, outsideZ) -- inside: negative, nearest face
	end
	return Vector3.new(math.max(outsideX, 0), 0, math.max(outsideZ, 0)).Magnitude
end

-- Normalises a CollisionBox to what the rest of the system assumes it is: a
-- described volume, not a wall. Called by the server for every plot, so a
-- builder ticking CanCollide on in Studio (the intuitive thing to do to a
-- part named CollisionBox) can't quietly bring back the exact bug this
-- feature was rewritten to remove.
--
-- CanQuery matters as much as CanCollide here: a queryable box sitting in the
-- middle of a bay answers suspension raycasts, the crash detector's
-- surface-normal rays, the pedestrian probe and the camera's occlusion
-- checks - all of which want the real world, not a marker volume.
function PlotBarrier.NormaliseBox(box)
	box.Anchored = true
	box.CanCollide = false
	box.CanQuery = false
	box.CanTouch = false
	box.Transparency = 1
	box.CastShadow = false
end

return PlotBarrier

-- PROTOTYPE: articulated vehicles. Trailer wheel visuals.
--
-- Wheel meshes in this game are COSMETIC and are posed entirely separately
-- from the physics: VehiclePhysics.Step never touches them, and
-- VehiclePhysics.UpdateWheelVisuals does all of it - casting its own ray per
-- wheel to follow the ground, and deriving spin from the chassis' velocity at
-- the contact patch.
--
-- RayCastSuspension.client.luau runs that for every car, but its loop walks
-- workspace.Vehicles, and trailers deliberately do not live there (they have
-- no DriverSeat - see TrailerHitch.server.luau). So nothing was ever posing a
-- trailer's wheels: they stayed welded at their modelled offset with a fixed
-- rotation, which is exactly the "wheels don't turn, the trailer looks like it
-- is sliding on its skids" symptom.
--
-- This is the trailer's equivalent of that loop, and deliberately ONLY the
-- wheel part of it. A trailer has no headlights, gauges, steering wheel,
-- exhaust or engine, so none of the rest of that loop's work applies.
--
-- Runs on EVERY client, not just the driver's - a trailer being towed past you
-- has to have turning wheels for you too, and this client has no session for
-- somebody else's rig. Everything here is derived from replicated state
-- (position, velocity, the hitch link), so no client needs permission to know
-- any of it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

-- Weak keys throughout: a trailer that is destroyed must not be kept alive by
-- this bookkeeping, and there is no other cleanup path worth maintaining for
-- state this cheap to rebuild.
local attachmentsCache = setmetatable({}, { __mode = "k" })
local rotationState = setmetatable({}, { __mode = "k" })
local parkedPoseFrames = setmetatable({}, { __mode = "k" })
-- [trailer] = the tractor its ray filter was last pointed at. See syncRayIgnore.
local lastTractor = setmetatable({}, { __mode = "k" })

-- Matches RayCastSuspension's own constant and exists for the same reason: a
-- newly-parked trailer keeps being re-posed for a few frames so the final pose
-- is taken against the settled chassis rather than one still being moved into
-- place. For a trailer that is the uncoupling handover - the server destroys
-- the joint, re-anchors and takes ownership back, and a ray cast in the middle
-- of that can easily miss the ground entirely, which clamps the strut to full
-- droop and drives the wheel down through the floor.
local PARKED_POSE_FRAMES = 15

-- Returns nil rather than erroring while a trailer is still being set up - its
-- WheelXX attachments exist from the start, but the Wheels folder is created
-- by the server and takes a moment to replicate.
local function getAttachments(trailer)
	local cached = attachmentsCache[trailer]
	if cached then
		return cached
	end
	local chassis = trailer.PrimaryPart
	if not chassis then
		return nil
	end
	local ok, attachments = pcall(VehiclePhysics.GetWheelAttachments, chassis)
	if not ok then
		return nil
	end
	attachmentsCache[trailer] = attachments
	return attachments
end

-- Keep this client's suspension-ray filter in step with what is actually
-- hitched, for BOTH bodies.
--
-- The registry is per-context (see SetExtraRayIgnore), and the driving client
-- sets its own copy in TrailerDrive for the physics. That covers the driver
-- and nobody else - so without this, every OTHER client would cast the
-- tractor's visual rays straight into the trailer's nose, read it as road, and
-- pose the truck's rear wheels climbing up it. Driven off the replicated
-- ObjectValue link, so it is right on every machine.
--
-- Overlaps with TrailerDrive deliberately: both write the same pair of values,
-- and TrailerDrive's runs before the driver's first physics step regardless of
-- how the render step happens to be ordered against it.
local function syncRayIgnore(trailer)
	local tractor = TrailerHitch.GetHitchedTractor(trailer)
	local previous = lastTractor[trailer]
	if tractor == previous then
		return -- nothing changed; the common case, every frame
	end

	-- Clearing the TRACTOR's entry is the half that is easy to forget, and it
	-- is the half that rots: the trailer's own entry goes away with the
	-- trailer, but a truck that has dropped its trailer and driven off would
	-- otherwise keep ignoring that trailer's geometry for the rest of the
	-- session - reading real ground as empty air wherever it happened to be
	-- parked. Hence remembering what was last set, rather than only reacting
	-- to what is set now.
	if previous then
		VehiclePhysics.ClearExtraRayIgnore(previous)
	end

	if tractor then
		VehiclePhysics.SetExtraRayIgnore(trailer, { tractor })
		VehiclePhysics.SetExtraRayIgnore(tractor, { trailer })
	else
		VehiclePhysics.ClearExtraRayIgnore(trailer)
	end
	lastTractor[trailer] = tractor
end

-- A trailer has no driver and no controls, so every input the visuals take is
-- a constant. Spin is NOT one of them - UpdateWheelVisuals derives it from the
-- chassis' velocity at each contact patch, which is why a trailer's wheels
-- turn correctly on zero throttle.
--
-- SmoothSteer 0 matters as more than a default: it tells UpdateWheelVisuals to
-- measure tire slip in an unsteered frame, which for a trailer's fixed axles is
-- the true one.
local TRAILER_INPUT = { SmoothSteer = 0, Throttle = 0, Handbrake = false, Burnout = false }

RunService:BindToRenderStep("MoveTrailerWheels", 5, function()
	local folder = workspace:FindFirstChild(TrailerHitch.WorkspaceFolderName)
	if not folder then
		return -- no trailers in this place
	end

	for _, trailer in folder:GetChildren() do
		if not trailer:IsA("Model") then
			continue
		end
		local attachments = getAttachments(trailer)
		local chassis = attachments and trailer.PrimaryPart
		if not chassis then
			continue
		end

		syncRayIgnore(trailer)

		if chassis.Anchored then
			-- Parked. Pose a few more frames, then leave it alone entirely -
			-- an anchored trailer cannot move, so re-posing it every frame
			-- would be four raycasts a frame to produce an identical answer.
			local remaining = parkedPoseFrames[trailer]
			if remaining == nil then
				remaining = PARKED_POSE_FRAMES
			end
			if remaining > 0 then
				parkedPoseFrames[trailer] = remaining - 1
			else
				continue
			end
		else
			-- Moving again (just hitched): re-arm, so the next uncoupling gets
			-- its own settle rather than reusing a spent count.
			parkedPoseFrames[trailer] = nil
		end

		rotationState[trailer] = rotationState[trailer] or {}
		VehiclePhysics.UpdateWheelVisuals(
			trailer,
			attachments,
			-- Read fresh rather than cached: tuneSuspension writes this
			-- trailer's Stiffness and SuspensionMaxLength as Chassis
			-- attributes at setup, and the ray length below is derived from
			-- SuspensionMaxLength - a config cached before those landed would
			-- pose the wheels against the wrong travel.
			VehiclePhysics.GetConfig(chassis),
			rotationState[trailer],
			TRAILER_INPUT
		)
	end
end)

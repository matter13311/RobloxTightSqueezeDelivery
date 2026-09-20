-- PROTOTYPE: articulated vehicles (tractor + drawn trailer).
--
-- The shared half of the hitch: naming, tolerances, and the geometry test for
-- "is this trailer lined up well enough to couple". Shared deliberately, the
-- same way CargoLoad is - the SERVER is the only thing allowed to actually
-- couple anything (see TrailerHitch.server.luau), but the driving client needs
-- the identical test to decide whether to offer the prompt. If the two
-- disagreed the player would be told to press a key that then silently did
-- nothing, which is the worst possible failure for a feature whose whole
-- difficulty is judging an approach.
--
-- HOW THE JOINT IS BUILT, and why it isn't the obvious BallSocketConstraint:
--
-- A ball socket gives yaw, pitch AND roll. Roll is the one that ruins it: a
-- trailer free to roll relative to the tractor flops sideways in every corner
-- and pumps that energy back into the cab, which on a raycast chassis (whose
-- suspension is explicit per-frame impulses) is an oscillation source with
-- nothing damping it. Real fifth wheels have essentially no roll freedom.
--
-- So the joint is a two-hinge gimbal through a small intermediate "Kingpin"
-- part, built at runtime by the server:
--
--     tractor Chassis --[hinge, LATERAL axis]-- Kingpin --[hinge, VERTICAL axis]-- trailer Chassis
--              (pitch: crest a hill)                      (yaw: the articulation)
--
-- Yaw carries the angle limit (the jackknife stop) and a zero-velocity Motor
-- acting as fifth-wheel friction - a free HingeConstraint has no damping term
-- at all, and without it the trailer weaves behind you at speed.
--
-- Positions come from two Studio-authored Attachments and nothing else: the
-- hinge attachments are built in code with explicit orientations, because a
-- hinge takes its axis from its attachments' own X axis and silently doing
-- something reasonable-looking with a mis-rotated one is exactly the kind of
-- bug that costs an afternoon.

local TrailerHitch = {}

--=============================================================================
-- Naming
--=============================================================================

-- Attachment on the TRACTOR's chassis: where the trailer is picked up. Only
-- its Position is read - see the header.
TrailerHitch.TractorAttachmentName = "Hitch"
-- Attachment on the TRAILER's chassis: the point that is brought to the
-- tractor's Hitch. Again, position only.
TrailerHitch.TrailerAttachmentName = "Kingpin"

-- Every runtime instance the coupling creates lives under one folder on the
-- trailer's chassis, so unhitching is "destroy that folder" rather than a list
-- of individually-named things to remember. Forgetting one of those leaves a
-- constraint alive between two bodies that both think they are free, which
-- presents as a trailer being dragged by nothing.
TrailerHitch.JointFolderName = "HitchJoint"

-- Instance links. Attributes cannot hold Instances, so these are ObjectValues
-- (which replicate on their own, same reasoning as the attributes elsewhere).
TrailerHitch.Links = {
	-- ObjectValue inside the TRACTOR model, pointing at the trailer model.
	TrailerOnTractor = "HitchedTrailer",
	-- ObjectValue inside the TRAILER model, pointing at the tractor model.
	TractorOnTrailer = "HitchedTractor",
}

TrailerHitch.Attributes = {
	-- number (UserId) on the trailer model, or absent. Set while a player is
	-- coupled to it, or has otherwise reserved it. Absence is the signal, not
	-- 0 - same convention as CargoLoad.LoadingPlaced.
	ClaimedBy = "TrailerClaimedBy",
	-- bool on the trailer model. True only between a completed couple and its
	-- uncouple, and read by the client to decide which prompt to show.
	Hitched = "TrailerHitched",
}

-- The folder in Workspace trailers live in. Deliberately NOT workspace.Vehicles:
-- Raycast.server.luau's AddCar requires a DriverSeat and would reject every
-- trailer with a warning. Trailers get their own, much smaller setup pass in
-- TrailerHitch.server.luau.
TrailerHitch.WorkspaceFolderName = "Trailers"

--=============================================================================
-- Tolerances
--
-- These are the whole feel of the feature and they are meant to be tuned by
-- driving, not by reasoning. Start generous: a real fifth wheel has a wide
-- funnel that guides the pin in, and a first pass that demands precision the
-- player has no camera angle to achieve reads as "the hitch is broken".
--=============================================================================

-- Studs between the tractor's Hitch and the trailer's Kingpin.
TrailerHitch.MaxDistance = 10
-- Degrees between the two bodies' flat headings. Above this the coupling snap
-- would be a visible teleport-and-rotate rather than a nudge into place.
TrailerHitch.MaxAngleDegrees = 30
-- How long the trailer is tweened onto the pin before the constraints are
-- built. This is not only polish: creating a hinge across a gap or an overlap
-- hands the solver a violated constraint to resolve on frame one, and that is
-- precisely where two coupled bodies detonate. Snapping first means the
-- constraint is satisfied the moment it exists.
TrailerHitch.SnapSeconds = 0.25

-- Jackknife stop, degrees either side of straight. The trailer's own nose will
-- usually foul the cab before this, which is realistic and fine; this is the
-- backstop that stops it folding through.
TrailerHitch.YawLimitDegrees = 75
-- Fifth-wheel friction: a Motor targeting zero relative angular velocity, so
-- it resists the RATE of articulation without resisting the ANGLE. Raise it if
-- the trailer weaves behind you at speed; lower it if the rig refuses to bend
-- into a turn. Zero disables the damping entirely (free-swinging pin).
TrailerHitch.YawFrictionTorque = 4000
-- Pitch freedom, degrees. Small: enough to crest a hill or a kerb without the
-- trailer levering the tractor's rear wheels off the ground, not enough to let
-- it pitch around freely.
TrailerHitch.PitchLimitDegrees = 20

-- Spring compression, in studs, that a PARKED (uncoupled) trailer is placed
-- at. An uncoupled trailer is never simulated - see placeOnGround in
-- TrailerHitch.server.luau for why a bogie-only trailer cannot be - so this is
-- the pose it is put in rather than one it finds.
--
-- Matched to the sag its suspension is tuned for when coupled (see the
-- derivation in Configs/TestTrailer.luau) so that hitching up does not make
-- the trailer visibly jump to a different ride height at the moment the
-- constraints appear.
TrailerHitch.RestSag = 1.4

--=============================================================================
-- Geometry
--=============================================================================

function TrailerHitch.GetHitchAttachment(tractorModel)
	local chassis = tractorModel and tractorModel.PrimaryPart
	return chassis and chassis:FindFirstChild(TrailerHitch.TractorAttachmentName)
end

function TrailerHitch.GetKingpinAttachment(trailerModel)
	local chassis = trailerModel and trailerModel.PrimaryPart
	return chassis and chassis:FindFirstChild(TrailerHitch.TrailerAttachmentName)
end

-- A vehicle can only be hitched if it has somewhere to hitch TO, which is what
-- makes this feature opt-in per vehicle: adding a "Hitch" attachment in Studio
-- is the entire declaration. No catalog flag, nothing to keep in sync.
function TrailerHitch.CanTow(tractorModel)
	return TrailerHitch.GetHitchAttachment(tractorModel) ~= nil
end

-- Heading with the pitch and roll thrown away. Both the angle test and the
-- coupling pose need the rig compared on the flat: a tractor nosed down a ramp
-- is still pointing the same way as the trailer in front of it, and judging
-- that with the full CFrame would refuse a coupling that is visibly lined up.
local function flatLook(cframe)
	local look = cframe.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		-- Nose-straight-up: no meaningful heading to compare. Anything is as
		-- wrong as anything else, so pick a stable answer rather than
		-- returning a NaN direction that poisons every caller.
		return Vector3.new(0, 0, -1)
	end
	return flat.Unit
end
TrailerHitch.FlatLook = flatLook

-- Where the trailer's chassis has to be for its Kingpin to sit exactly on the
-- tractor's Hitch, squared up behind it. This is the pose the snap tweens to
-- and, by construction, the pose in which both hinges are already satisfied.
--
-- Y comes from the hitch like everything else: the trailer is unanchored right
-- after this and drops onto its own suspension, so lifting it to the pin is
-- correct rather than something to compensate for.
function TrailerHitch.CoupleCFrame(tractorModel, trailerModel)
	local hitch = TrailerHitch.GetHitchAttachment(tractorModel)
	local kingpin = TrailerHitch.GetKingpinAttachment(trailerModel)
	if not (hitch and kingpin) then
		return nil
	end

	local rotation = CFrame.lookAt(Vector3.zero, flatLook(tractorModel.PrimaryPart.CFrame))
	-- Kingpin position in the trailer chassis's own space, rotated into the
	-- pose we are about to put the chassis in - so subtracting it from the
	-- hitch gives the chassis origin that lands the pin on the hitch.
	local kingpinOffset = rotation:VectorToWorldSpace(kingpin.Position)
	return rotation + (hitch.WorldPosition - kingpinOffset)
end

--=============================================================================
-- The alignment test
--
-- Returns (ok, reason). `reason` is a short player-facing string on failure,
-- so the client prompt can say WHY rather than just going quiet - "too far
-- apart" and "not lined up" want different corrections from the driver, and a
-- prompt that only appears once you are already correct teaches nothing.
--
-- Deliberately does NOT check ownership, claims, or whether the tractor is
-- stopped. Those are policy, they need server state, and the server checks
-- them itself in CanCouple; this is only the geometry both sides agree on.
--=============================================================================

function TrailerHitch.CheckAlignment(tractorModel, trailerModel)
	local hitch = TrailerHitch.GetHitchAttachment(tractorModel)
	if not hitch then
		return false, "This vehicle has no hitch"
	end
	local kingpin = TrailerHitch.GetKingpinAttachment(trailerModel)
	if not kingpin then
		return false, "That trailer has no kingpin"
	end

	local distance = (hitch.WorldPosition - kingpin.WorldPosition).Magnitude
	if distance > TrailerHitch.MaxDistance then
		return false, "Too far from the trailer"
	end

	local tractorLook = flatLook(tractorModel.PrimaryPart.CFrame)
	local trailerLook = flatLook(trailerModel.PrimaryPart.CFrame)
	-- Clamped before acos: two unit vectors can dot to 1.0000001 in float and
	-- acos of that is NaN, which compares false against every threshold and
	-- would refuse a perfectly square approach.
	local angle = math.deg(math.acos(math.clamp(tractorLook:Dot(trailerLook), -1, 1)))
	if angle > TrailerHitch.MaxAngleDegrees then
		return false, "Not lined up with the trailer"
	end

	return true, nil
end

-- The nearest trailer that passes the geometry test, or nil. Used by the
-- client to decide what to offer and by the server to resolve "hitch to
-- whatever is behind me" without the client naming an instance.
--
-- Nearest rather than first-found because two trailers parked side by side in
-- a yard is the normal case, not an edge case, and backing between them should
-- pick the one you are actually closest to rather than whichever happens to be
-- earlier in the folder.
function TrailerHitch.FindCandidate(tractorModel, trailersFolder)
	if not (tractorModel and tractorModel.PrimaryPart and trailersFolder) then
		return nil
	end
	local hitch = TrailerHitch.GetHitchAttachment(tractorModel)
	if not hitch then
		return nil
	end

	local best, bestDistance = nil, math.huge
	for _, trailer in trailersFolder:GetChildren() do
		if not trailer:IsA("Model") or not trailer.PrimaryPart then
			continue
		end
		if trailer:GetAttribute(TrailerHitch.Attributes.Hitched) then
			continue -- already on the back of somebody else's truck
		end
		local kingpin = TrailerHitch.GetKingpinAttachment(trailer)
		if not kingpin then
			continue
		end
		local distance = (hitch.WorldPosition - kingpin.WorldPosition).Magnitude
		if distance < bestDistance and TrailerHitch.CheckAlignment(tractorModel, trailer) then
			best, bestDistance = trailer, distance
		end
	end
	return best
end

-- What is on the back of this tractor right now, or nil. Reads the ObjectValue
-- rather than searching, so both sides agree even mid-approach.
function TrailerHitch.GetHitchedTrailer(tractorModel)
	local link = tractorModel and tractorModel:FindFirstChild(TrailerHitch.Links.TrailerOnTractor)
	return link and link:IsA("ObjectValue") and link.Value or nil
end

function TrailerHitch.GetHitchedTractor(trailerModel)
	local link = trailerModel and trailerModel:FindFirstChild(TrailerHitch.Links.TractorOnTrailer)
	return link and link:IsA("ObjectValue") and link.Value or nil
end

return TrailerHitch

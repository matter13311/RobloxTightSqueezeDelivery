-- Answers two questions vehicle code keeps needing while driving: is the
-- camera actually in first person right now, and is this player allowed to
-- drive in third person at all. Kept in one module so the camera lock and
-- the dashboard's show/hide agree with each other instead of each
-- reimplementing the same check.
--
-- Third person while driving is a monetized perk and is OFF by default.
-- Nothing here hardcodes that - it reads a per-player attribute that a
-- future gamepass/dev-product purchase sets server-side (see
-- THIRD_PERSON_ATTRIBUTE below). Until something sets that attribute,
-- every player is first-person-only in a vehicle, which is today's default
-- behaviour for free.

local Players = game:GetService("Players")

local VehicleEyePoint = require(script.Parent.VehicleEyePoint)

local player = Players.LocalPlayer

local VehicleViewMode = {}

-- The measurement itself lives in VehicleEyePoint, because the point being
-- measured against is that module's business: while seated the camera is
-- pinned to the car's configured eye rather than to the head, so a
-- first-person driver in a short-torso avatar sits a stud or more from their
-- own head and a head-based check would call that third person. It also has
-- to be there because VehicleEyePoint needs the answer itself, to decide
-- whether to hide the character, and cannot require this module back.
--
-- This stays the front door: it is what the rest of the game calls, and one
-- of the two questions the module answers (the other being whether third
-- person is allowed at all). VehicleZoom used to carry a hand-copied third
-- copy of the measurement.
function VehicleViewMode.IsFirstPerson()
	return VehicleEyePoint.IsFirstPerson()
end

-- Set server-side (an Attribute replicates automatically) to a Unix
-- timestamp - os.time() plus however long the perk lasts - when a gamepass
-- or dev-product grants temporary third person. Absent or expired means
-- locked to first person. This is the one thing a future monetization
-- feature needs to touch; everything below just reads it.
local THIRD_PERSON_ATTRIBUTE = "ThirdPersonExpiresAt"

-- Whole seconds left on the perk, 0 if there is none. The one source of
-- truth for "how much is left" - the dashboard countdown reads this
-- directly, and HasThirdPersonAccess below is just this being positive, so
-- the two can never disagree about whether the perk is active.
function VehicleViewMode.ThirdPersonSecondsRemaining()
	local expiresAt = player:GetAttribute(THIRD_PERSON_ATTRIBUTE)
	if type(expiresAt) ~= "number" then
		return 0
	end
	return math.max(0, expiresAt - os.time())
end

function VehicleViewMode.HasThirdPersonAccess()
	return VehicleViewMode.ThirdPersonSecondsRemaining() > 0
end

-- Called every frame of a drive session (cheap - it's one property write,
-- idempotent when nothing has changed). Forces first person for players
-- without the perk; players who have it get the normal free camera and can
-- pick either view. Checked continuously rather than once on entry so a
-- time-limited perk expiring mid-drive locks the camera back down right
-- away instead of at the next time the player gets in a car.
function VehicleViewMode.EnforceCameraMode()
	player.CameraMode = if VehicleViewMode.HasThirdPersonAccess()
		then Enum.CameraMode.Classic
		else Enum.CameraMode.LockFirstPerson
end

-- Called once when a drive session ends, so getting out of the car never
-- leaves a walking player stuck in a first-person lock that only made sense
-- while driving.
function VehicleViewMode.ReleaseCameraMode()
	player.CameraMode = Enum.CameraMode.Classic
end

return VehicleViewMode

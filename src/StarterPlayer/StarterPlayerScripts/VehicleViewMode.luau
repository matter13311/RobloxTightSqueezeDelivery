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

local player = Players.LocalPlayer

local VehicleViewMode = {}

-- Roblox exposes no "am I in first person" flag: in first person the camera
-- sits on the head, in any third person view it is at least the zoom
-- distance away. Threshold generous enough to cover the small offset the
-- camera keeps from the head, far below the closest third person zoom the
-- default controller allows. Matches the check VehicleZoom already uses.
local FIRST_PERSON_DISTANCE = 1.5

function VehicleViewMode.IsFirstPerson()
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return true
	end
	local camera = workspace.CurrentCamera
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not camera or not head then
		-- No camera or head to measure from - default to the locked-down
		-- state (HUD hidden, effectively first person) rather than assuming
		-- the more permissive one.
		return true
	end
	return (camera.CFrame.Position - head.Position).Magnitude <= FIRST_PERSON_DISTANCE
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

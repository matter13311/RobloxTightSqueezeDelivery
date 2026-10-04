-- Answers one question vehicle code keeps needing while driving: is the
-- camera actually in first person right now. Third person is free for
-- everyone, so there is no access check - the camera is never locked.

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

-- Called once when a drive session ends. Nothing locks the camera any more,
-- but this still clears any first-person lock left over from older code.
function VehicleViewMode.ReleaseCameraMode()
	player.CameraMode = Enum.CameraMode.Classic
end

return VehicleViewMode

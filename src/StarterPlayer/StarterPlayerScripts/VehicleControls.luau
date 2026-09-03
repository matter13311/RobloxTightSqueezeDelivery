-- Thin, input-agnostic wrappers around the vehicle light-switch remotes.
-- Deliberately kept separate from HOW a toggle gets triggered - today that's
-- the L/Q/E keybinds in RayCastSuspension.client.luau, but a future
-- ClickDetector/ProximityPrompt on an in-cab switch should call these same
-- two functions rather than firing the remotes itself.
--
-- No client-side prediction here on purpose: the server is what actually
-- flips the Attribute, and every client (including this one) reacts to that
-- through VehicleLights' Attribute-changed listeners, so the light and the
-- switch sound only ever fire once, in the same place, for everyone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local toggleHeadlightsRemote = ReplicatedStorage:WaitForChild("ToggleHeadlights")
local toggleTurnSignalRemote = ReplicatedStorage:WaitForChild("ToggleTurnSignal")

local VehicleControls = {}

function VehicleControls.ToggleHeadlights(vehicle)
	toggleHeadlightsRemote:FireServer(vehicle)
end

-- `side` is "Left" or "Right". Toggles: firing the side that's already on
-- turns it off, firing the other side switches straight to it.
function VehicleControls.ToggleTurnSignal(vehicle, side)
	toggleTurnSignalRemote:FireServer(vehicle, side)
end

return VehicleControls

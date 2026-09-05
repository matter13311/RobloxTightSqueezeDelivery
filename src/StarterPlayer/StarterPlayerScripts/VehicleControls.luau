-- Thin, input-agnostic wrappers around the vehicle light-switch and horn
-- remotes. Deliberately kept separate from HOW a toggle gets triggered -
-- today that's the L/Q/E/H keybinds in RayCastSuspension.client.luau, but a
-- future ClickDetector/ProximityPrompt on an in-cab switch should call these
-- same functions rather than firing the remotes itself.
--
-- No client-side prediction here on purpose: the server is what actually
-- flips the Attribute, and every client (including this one) reacts to that
-- through VehicleLights' Attribute-changed listeners, so the light and the
-- switch sound only ever fire once, in the same place, for everyone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local toggleHeadlightsRemote = ReplicatedStorage:WaitForChild("ToggleHeadlights")
local toggleTurnSignalRemote = ReplicatedStorage:WaitForChild("ToggleTurnSignal")
local setHornRemote = ReplicatedStorage:WaitForChild("SetHorn")

local VehicleControls = {}

function VehicleControls.ToggleHeadlights(vehicle)
	toggleHeadlightsRemote:FireServer(vehicle)
end

-- `side` is "Left" or "Right". Toggles: firing the side that's already on
-- turns it off, firing the other side switches straight to it.
function VehicleControls.ToggleTurnSignal(vehicle, side)
	toggleTurnSignalRemote:FireServer(vehicle, side)
end

-- `active` is true on key-down and false on key-up: the horn sounds for as
-- long as it's held. Nothing is played locally - the Sound lives on the car's
-- Chassis and is played by the server (see VehicleHorn.server.luau), which is
-- what makes every player in the game hear it, positioned at the car that
-- honked, rather than just the driver.
--
-- The release MUST also be sent whenever the driving session ends without a
-- key-up (getting out, dying, being unseated); the server has a timeout
-- backstop, but it's ten seconds of blaring horn.
function VehicleControls.SetHorn(vehicle, active)
	setHornRemote:FireServer(vehicle, active)
end

return VehicleControls

-- Keeps the camera where the player put it across getting into and out of a
-- vehicle. Roblox's own camera controller re-evaluates the zoom whenever the
-- humanoid is seated or unseated, which is why entering a car from first
-- person dropped you into third, and leaving it from third person put you back
-- into first. Nothing in this game asked for either; both are the default
-- controller's doing, so this puts the player's own choice back afterwards.
--
-- Nothing here fights the player: they can still zoom freely at any time, and
-- whatever they zoom to becomes the value that gets restored across the next
-- transition.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local VehicleEyePoint = require(script.Parent.VehicleEyePoint)

local player = Players.LocalPlayer

-- Flip to true when the game goes first-person-only. That single property is
-- the whole feature - it pins the camera to the head and takes zooming away
-- entirely, at which point everything below becomes a no-op (there is no zoom
-- left to drift) and can simply be deleted.
local LOCK_FIRST_PERSON = false

-- Frames to let the default controller finish whatever it does on a seat
-- change before overriding it. Reapplying on the very next frame is too early:
-- the controller's own adjustment lands after, and wins.
local SETTLE_FRAMES = 3
-- ...and how long to hold the override before handing control back, so the
-- clamp below is definitely applied before it is lifted again.
local HOLD_FRAMES = 2

-- The player's REAL zoom limits, captured once at startup. Every restore below
-- narrows these to a single value and then puts them back - so they have to be
-- read from here rather than from the live properties, which may well be
-- mid-override when the next transition starts.
local trueMinZoom = player.CameraMinZoomDistance
local trueMaxZoom = player.CameraMaxZoomDistance

-- The zoom the player last actually chose. Not sampled while an override is in
-- flight, or it would just read back the value being forced.
local trackedZoom = nil
local overriding = false

-- Measured from the eye the camera is actually orbiting, not from the head.
-- While seated those are different places (see VehicleEyePoint), and reading
-- the head there would sample the eye offset as if it were zoom - so a short
-- avatar getting out of a car would be "restored" to a third-person zoom they
-- never chose.
local function currentZoom()
	local camera = workspace.CurrentCamera
	local viewOrigin = VehicleEyePoint.GetViewOrigin()
	if not (camera and viewOrigin) then
		return nil
	end
	return (camera.CFrame.Position - viewOrigin).Magnitude
end

-- Roblox exposes no "set the zoom to X" API. The supported lever is the
-- player's own zoom clamp: pinning both ends to one value forces the camera
-- there, after which the real limits go back and the player can zoom freely
-- again. Clamped into the player's actual allowed range so this can never
-- widen the limits past what the game permits.
local function applyZoom(zoom)
	local target = math.clamp(zoom, trueMinZoom, trueMaxZoom)
	player.CameraMinZoomDistance = target
	player.CameraMaxZoomDistance = target
end

local function releaseZoom()
	player.CameraMinZoomDistance = trueMinZoom
	player.CameraMaxZoomDistance = trueMaxZoom
end

local function restoreAfterSeatChange()
	local zoom = trackedZoom
	if not zoom or overriding then
		return
	end
	overriding = true
	task.spawn(function()
		for _ = 1, SETTLE_FRAMES do
			RunService.RenderStepped:Wait()
		end
		applyZoom(zoom)
		for _ = 1, HOLD_FRAMES do
			RunService.RenderStepped:Wait()
		end
		releaseZoom()
		overriding = false
	end)
end

-- C cycles first person -> close third -> far third. Only while seated: the
-- key is advertised on the driving controls bar, and on foot the player has
-- the scroll wheel.
local VIEW_FIRST = 0.5
local VIEW_CLOSE = 14
local VIEW_FAR = 32
-- Zoom below this counts as first person, up to VIEW_SPLIT as "close".
local FIRST_LIMIT = 2
local VIEW_SPLIT = 22

local function cycleView()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (humanoid and humanoid.SeatPart) or overriding then
		return
	end
	local zoom = trackedZoom or VIEW_CLOSE
	local target
	if zoom < FIRST_LIMIT then
		target = VIEW_CLOSE
	elseif zoom < VIEW_SPLIT then
		target = VIEW_FAR
	else
		target = VIEW_FIRST
	end
	overriding = true
	task.spawn(function()
		applyZoom(target)
		for _ = 1, HOLD_FRAMES do
			RunService.RenderStepped:Wait()
		end
		releaseZoom()
		overriding = false
	end)
end

ContextActionService:BindAction("VehicleCameraCycle", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		cycleView()
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.C)

-- The touch CAM button (VehicleTouchControls) fires this; it lives beside the
-- scripts so the button doesn't need to reach into this one.
local cycleEvent = Instance.new("BindableEvent")
cycleEvent.Name = "CycleCameraView"
cycleEvent.Event:Connect(cycleView)
cycleEvent.Parent = script.Parent

local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")
	-- Fires for sitting down AND standing up, and both need the same
	-- treatment - the controller re-evaluates the zoom either way.
	humanoid.Seated:Connect(restoreAfterSeatChange)
end

RunService.RenderStepped:Connect(function()
	if not overriding then
		trackedZoom = currentZoom() or trackedZoom
	end
end)

if LOCK_FIRST_PERSON then
	player.CameraMode = Enum.CameraMode.LockFirstPerson
end

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

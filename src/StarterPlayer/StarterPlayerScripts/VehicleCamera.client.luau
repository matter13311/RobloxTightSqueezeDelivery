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

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)
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
--
-- A TRUCK THAT TOWS gets its own, longer set. A tractor and trailer is about
-- seventy studs nose to tail, so the ordinary "far" view sits somewhere over
-- the trailer's roof and shows none of what the driver is trying to judge -
-- where the back end is going. Its three stages are the cab, the cab with the
-- front of the trailer, and the whole rig; and the scroll wheel is allowed out
-- past the last of them, where every other vehicle stops at the game's normal
-- limit.
local VIEW_FIRST = 0.5
local VIEWS = { VIEW_FIRST, 14, 32 }
local RIG_VIEWS = { VIEW_FIRST, 30, 70 }
local RIG_MAX_ZOOM = 95
-- Zoom below this counts as first person.
local FIRST_LIMIT = 2
-- How far short of a stage (studs) the camera has to be for that stage to be
-- "further out" - see cycleView.
local STAGE_SLACK = 2

-- Captured before anything here changes it: the limit every vehicle but a
-- tractor is held to, and what the player goes back to on foot.
local baseMaxZoom = trueMaxZoom

-- The vehicle the player is sitting in, if it is one that tows.
local function seatedInTractor()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	local carModel = seat and seat.Parent
	return carModel ~= nil and carModel:IsA("Model") and TrailerHitch.CanTow(carModel)
end

-- Widens or restores the zoom limit to suit what the player is sitting in.
-- Run on every seat change, BEFORE restoreAfterSeatChange reads trueMaxZoom -
-- so climbing out of a rig at seventy studs is clamped back to the on-foot
-- limit by the restore that follows, rather than left hanging out there.
local function syncZoomLimit()
	trueMaxZoom = if seatedInTractor() then math.max(baseMaxZoom, RIG_MAX_ZOOM) else baseMaxZoom
	if not overriding then
		player.CameraMaxZoomDistance = trueMaxZoom
	end
end

local function cycleView()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (humanoid and humanoid.SeatPart) or overriding then
		return
	end
	local views = if seatedInTractor() then RIG_VIEWS else VIEWS
	local zoom = trackedZoom or views[2]
	-- The next stage OUT from wherever the camera is now, wrapping to first
	-- person from the last. "Out" means clearly further than the camera
	-- already is (STAGE_SLACK), so a view scrolled a little off its stage
	-- still counts as that stage.
	--
	-- Each stage is capped at the zoom limit before it is compared. Without
	-- that a stage the limit cannot reach is never arrived at, so the cycle
	-- keeps asking for it and never wraps - which is what the old two-stage
	-- version did on the game's 20-stud limit: far (32) clamped to 20, read
	-- back as "still short of far", forever.
	local target = VIEW_FIRST
	if zoom < FIRST_LIMIT then
		target = views[2]
	else
		for index = 2, #views do
			local stage = math.min(views[index], trueMaxZoom)
			if zoom < stage - STAGE_SLACK then
				target = stage
				break
			end
		end
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
	humanoid.Seated:Connect(function()
		syncZoomLimit()
		restoreAfterSeatChange()
	end)
	-- A respawn is a seat change nothing fires for: back to the on-foot limit.
	syncZoomLimit()
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

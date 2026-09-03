-- Hold right mouse button while driving to zoom in.
--
-- Exists because the far mirror is small and far away: from the driver's seat
-- the right-hand door mirror is a couple of hundred screen pixels across, and
-- no amount of resolution in VehicleMirrorViews helps when the whole mirror is
-- a thumbnail. Narrowing the player's own field of view magnifies everything
-- in front of them, mirror included, which is the cheapest possible fix - it
-- costs one property write per frame and touches nothing else.
--
-- Deliberately NOT a toggle. Held-to-zoom matches how you actually use a
-- mirror (glance, then back to the road) and can't leave the player stuck
-- zoomed in if they forget about it.
--
-- Started and stopped by RayCastSuspension.client.luau alongside the driving
-- session, so it is impossible to be zoomed while on foot.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local VehicleZoom = {}

-- =========================================================================
-- Tuning
-- =========================================================================

-- Field of view in degrees at full zoom. Lower is more magnified. Roblox's
-- default is 70, so 32 is a little over 2x.
local ZOOM_FOV = 32

-- Seconds to reach full zoom, and to come back out. Out is quicker than in on
-- purpose: zooming in is a deliberate look, dropping back out is you returning
-- your attention to the road and wanting it to happen now.
local ZOOM_IN_TIME = 0.22
local ZOOM_OUT_TIME = 0.14

-- Mouse sensitivity is scaled with the zoom, because zooming multiplies how
-- far the view swings for a given mouse movement: at 32 degrees from 70, the
-- same flick of the wrist covers more than twice the angle on screen, which is
-- why aiming at a mirror while zoomed feels twitchy.
--
-- The correction is the FOV RATIO (32/70 here, about 0.46), which keeps a
-- centimetre of mouse movement worth the same distance ON SCREEN whether or
-- not you are zoomed. That is the physically honest number, and it is why this
-- is derived rather than hand-tuned.
--
-- EXTRA_STEADINESS goes further than physical correctness: 1.0 is exactly
-- proportional, below 1.0 is slower still. Zoom is used here for a careful
-- look at a small mirror, so a little extra steadiness is usually wanted -
-- turn it to 1.0 if the correction feels sluggish rather than precise.
local EXTRA_STEADINESS = 0.85

-- Which inputs count as "hold to zoom".
local ZOOM_INPUTS = {
	[Enum.UserInputType.MouseButton2] = true,
	[Enum.KeyCode.ButtonL2] = true,
}

-- =========================================================================
-- State
-- =========================================================================

local RENDER_NAME = "VehicleZoom"

local active = false -- is a driving session running
local held = false -- is the zoom input down right now
local alpha = 0 -- 0 = normal, 1 = fully zoomed
local baseFov = nil -- the FOV to return to, captured on Start
local baseSensitivity = nil -- likewise for MouseDeltaSensitivity
local connections = {}

-- Smoothstep. A linear ramp reads as mechanical at this duration - it starts
-- and stops abruptly. This eases both ends, so the zoom settles instead of
-- arriving.
local function ease(t)
	return t * t * (3 - 2 * t)
end

local function inputMatches(input)
	return ZOOM_INPUTS[input.UserInputType] or ZOOM_INPUTS[input.KeyCode] or false
end

local function onRenderStep(dt)
	local camera = workspace.CurrentCamera
	if not camera or not baseFov then
		return
	end

	local target = if held then 1 else 0
	if alpha ~= target then
		-- Rate is per-second so the animation takes the same wall-clock time
		-- at any framerate, rather than being faster on a better machine.
		local duration = if target > alpha then ZOOM_IN_TIME else ZOOM_OUT_TIME
		local step = dt / math.max(duration, 1e-3)
		if target > alpha then
			alpha = math.min(alpha + step, 1)
		else
			alpha = math.max(alpha - step, 0)
		end
	end

	local eased = ease(alpha)
	local fov = baseFov + (ZOOM_FOV - baseFov) * eased
	camera.FieldOfView = fov

	-- Driven off the FOV actually in effect this frame rather than off alpha,
	-- so sensitivity tracks the zoom exactly through the transition instead of
	-- lagging or leading it.
	if baseSensitivity then
		local ratio = fov / baseFov
		local scale = 1 + (ratio * EXTRA_STEADINESS - 1) * eased
		UserInputService.MouseDeltaSensitivity = baseSensitivity * scale
	end
end

-- =========================================================================
-- Public API
-- =========================================================================

function VehicleZoom.Start()
	if active then
		return
	end
	active = true
	held = false
	alpha = 0

	local camera = workspace.CurrentCamera
	-- Captured per session rather than once at load, so if the game changes
	-- the default FOV between drives this picks up the new one.
	baseFov = camera and camera.FieldOfView or 70
	baseSensitivity = UserInputService.MouseDeltaSensitivity

	-- UserInputService rather than ContextActionService on purpose: binding
	-- MouseButton2 through ContextActionService sinks it, and right-drag is
	-- also how the player rotates the camera. Listening passively leaves that
	-- working, so you can hold right-click to zoom AND still look around.
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and inputMatches(input) then
				held = true
			end
		end)
	)
	-- InputEnded is NOT filtered on `processed`. A release that arrives marked
	-- as processed still has to un-hold the zoom, or letting go over a UI
	-- element would leave the player stuck zoomed in with no way out.
	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input)
			if inputMatches(input) then
				held = false
			end
		end)
	)
	-- Alt-tabbing away never delivers the release, same trap as above.
	table.insert(
		connections,
		UserInputService.WindowFocusReleased:Connect(function()
			held = false
		end)
	)

	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

function VehicleZoom.Stop()
	if not active then
		return
	end
	active = false
	held = false

	RunService:UnbindFromRenderStep(RENDER_NAME)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	-- Snap the FOV back rather than easing it out: by the time this runs the
	-- player is already being unseated, and animating the camera through a
	-- transition it did not ask for reads as a glitch.
	local camera = workspace.CurrentCamera
	if camera and baseFov then
		camera.FieldOfView = baseFov
	end
	if baseSensitivity then
		UserInputService.MouseDeltaSensitivity = baseSensitivity
	end
	alpha = 0
	baseFov = nil
	baseSensitivity = nil
end

return VehicleZoom

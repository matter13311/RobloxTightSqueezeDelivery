-- Live mirrors for the car THIS client is driving, and only that car.
--
-- The thing to understand before touching anything below: a ViewportFrame
-- does not render the world. There is no scene-capture API in Roblox, so a
-- ViewportFrame only ever shows instances that are parented INSIDE it, lit by
-- its own Ambient/LightColor and viewed through its own Camera. So this module
-- isn't reflecting anything - it is maintaining a second, miniature copy of
-- the interesting parts of the world and keeping their CFrames in sync every
-- frame.
--
-- That is what bounds the cost, and it is why this is driver-only: at most
-- three ViewportFrames exist per client, ever, no matter how many cars are on
-- the map. Start() is called when the local player takes a driver's seat and
-- Stop() when they leave it (see RayCastSuspension.client.luau); nothing here
-- runs for a bystander, and nothing here replicates.
--
-- MIRROR_MODE picks how the image is produced; see the constant for the full
-- comparison. Short version: "Camera" moves the camera and leaves the world
-- alone, "Reflect" mirrors the world and leaves the camera at the driver's
-- eye. "Camera" is the default and the one that works well.
--
-- HARD-WON, DO NOT UNDO: the SurfaceGui for each mirror is parented to
-- PlayerGui with its Adornee set to the glass part - NOT parented to the glass
-- part itself. A SurfaceGui parented straight to a BasePart renders ordinary 2D
-- children fine but leaves any ViewportFrame inside it blank. See buildRig.
--
-- SurfaceGui on a MeshPart maps to the mesh's BOUNDING BOX, not its geometry,
-- so on an angled or inset mirror mesh the image floats off the actual glass.
-- The fix is a thin rectangular Part named "Glass" welded onto the mirror -
-- findGlass below prefers one if it's there and falls back to the mirror part
-- itself (with a one-time warning) if it isn't, so this works either way.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local GameSettings = require(script.Parent.GameSettings)

local VehicleMirrorViews = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Declared up here, ABOVE every function that reads it, and not down beside
-- the render step where it is assigned. Lua resolves an identifier against the
-- locals visible at the point the function is COMPILED, so a `local state`
-- further down the file does not exist yet as far as refreshScene is concerned
-- - it would silently read a global instead and get nil at runtime.
local state = nil

-- =========================================================================
-- Tuning
-- =========================================================================

-- "Camera", "Reflect", or "Auto" (probe, then Reflect if it passes).
--
-- Both have been tried in-game. "Camera" is the right answer; "Reflect" is
-- kept because it is the only route to a true left-right flip, should that
-- ever be worth its costs.
--
-- What "Reflect" actually does, observed rather than assumed:
--
--   It renders, but INSIDE OUT. A mirrored transform reverses every triangle's
--   winding, so backface culling shows the far side of each surface: lighting
--   comes out darker and flatter, and surface detail is lost - decals in
--   particular simply do not appear.
--
--   Its aim cannot be corrected by configuration. The camera sits at the
--   driver's eye and the frustum is symmetric, but MIN_FOV forces it wider
--   than the glass actually subtends, so it shows a cone of the reflected
--   world reaching well past the mirror's edges - which is why the left mirror
--   shows windscreen pillar, and the right one looks like it is filmed from
--   the middle of the windscreen. Only an oblique frustum would fix that, and
--   ViewportFrame cannot do one. Yaw/Pitch do not apply here either: AIM_MODE
--   is consulted only in the "Camera" branch.
--
--   It is also the more expensive mode. Aim derives from the head rather than
--   the chassis, so the driven car cannot be frozen (see FREEZE_OWN_CAR) and
--   pays ~50 CFrame multiplies per mirror per frame.
local MIRROR_MODE = "Camera"

-- Three of this module's knobs are player-facing and live in GameSettings
-- rather than here, so the settings menu can move them at runtime:
--
--   MirrorRenderDistance  how far around the car to look, in studs
--   MirrorDetail          cap on clones per mirror - THE performance knob.
--                         Candidates are ranked by apparent size, so lowering
--                         it drops small clutter before it drops buildings.
--   MirrorRefreshRate     how often each mirror rebuilds what is behind it
--
-- They are read through the helpers below on every use rather than captured
-- once, so a change in the menu takes effect on the next refresh.
local function sceneRadius()
	return GameSettings.Get("MirrorRenderDistance")
end

local function maxSceneParts()
	return GameSettings.Get("MirrorDetail")
end

local function refreshHz()
	return GameSettings.Get("MirrorRefreshRate")
end

-- Cap on the spatial query itself, before per-mirror filtering, and NOT a
-- performance knob.
--
-- GetPartBoundsInRadius does not return the nearest MaxParts, it returns an
-- arbitrary MaxParts. So whenever the radius holds more parts than this, every
-- refresh gets a different arbitrary slice and scenery flickers in and out.
-- It has to stay comfortably above the part count expected at the LARGEST
-- render distance the settings menu allows, not the default one.
local MAX_QUERY_PARTS = 3000

-- How many clones a single refresh tick may CREATE. See the note in
-- refreshScene: this is the guard that stops a render-distance change or a
-- dense street from stalling a frame, which the suspension would turn into a
-- bounce. Ticks happen at the refresh rate times the mirror count, so this is
-- not as slow to fill as it looks.
local MAX_NEW_CLONES_PER_REFRESH = 12

-- How long a part stays in the mirror after the occlusion ray last saw it.
-- See the note in refreshScene: without this, one ray clipping a lamp post
-- makes scenery blink.
local OCCLUSION_GRACE = 1.0

-- Parts with a bounding radius above this are never occlusion-tested. See
-- isVisible: one ray cannot stand in for a floor or a building face, and those
-- are the occluders rather than the occluded.
local OCCLUSION_MAX_RADIUS = 40

-- Time constant, in seconds, for smoothing the chassis frame the whole mirror
-- view is derived from.
--
-- The raycast suspension leaves a constant fine tremor in the chassis'
-- orientation - real, correct, and far too small to notice looking out of the
-- windscreen. A mirror magnifies it: at a 40 degree field of view a fraction
-- of a degree of chassis shake swings the entire mirrored scene, which is what
-- reads as the mirror being choppy rather than the game being slow.
--
-- Everything the mirror uses - camera position, aim, and the glass plane - is
-- rebuilt from this smoothed frame plus constant offsets, NOT from the live
-- glass CFrame. That matters for more than smoothness: it is what keeps the
-- frozen car valid, since car and camera stay rigid to the same frame.
--
-- Small enough to be imperceptible as lag (50ms), large enough to kill the
-- tremor. Raise if it still shimmers, lower if the mirror feels rubbery.
local AIM_SMOOTHING_TAU = 0.05
-- Beyond this much movement in one frame it is a teleport or a respawn, not
-- motion; smoothing across it would smear the view for a moment.
local AIM_SNAP_DISTANCE = 25

-- The three mirrors refresh ROUND-ROBIN, one per tick, rather than all in the
-- same frame: three sorts of a few thousand candidates back to back is a
-- visible hitch at a large render distance. Staggering spreads it flat.

-- A mirror outside the player's view keeps its scene alive and simply updates
-- more slowly - it is never torn down and never re-cloned. That is why there
-- is no blank frame when it comes back into view: the clones were there the
-- whole time, at most a fraction of a second stale.
--
-- Both numbers are deliberately generous. The in-view test samples the glass's
-- CENTRE POINT only, and a door mirror sits far out toward the edge of the
-- screen, so a mirror can be plainly visible while its centre reads as off
-- screen. Getting that wrong throttles a mirror the player is looking at,
-- which is indistinguishable from the mirror being broken - and the saving is
-- small either way, since there are only ever three of these. Erring toward
-- doing the work is the right trade.
local OFFSCREEN_HZ = 12
-- Slack on the frustum test, as a fraction of the viewport.
local VIEW_MARGIN = 0.5

-- Resolution is specified as a CANVAS SIZE, not as pixels-per-stud, and this
-- is not a nicety - a door mirror's glass is about one stud across, so any
-- fixed px/stud figure that sounds reasonable for a wall (Roblox's default is
-- 50) renders the mirror at roughly 50x26 pixels. That does not look like a
-- bad mirror, it looks like the part changed material to something rough,
-- because a 50-pixel-wide render of a grey world is just noise.
--
-- So: pick the pixels you want along the glass's longest edge and let
-- buildRig work backwards to px/stud from the part's actual size. This is the
-- cheapest quality/perf lever here - halving it quarters the pixels rendered.
local TARGET_CANVAS_PIXELS = 320
-- Sanity rails for the derived value, for a mirror that is enormous or
-- microscopic. Roblox itself tops out around 10000 px/stud.
local MIN_PIXELS_PER_STUD = 50
local MAX_PIXELS_PER_STUD = 2000

local MAX_DISTANCE = 60

-- Clones are placed in the VIEWPORT's own space rather than at their real
-- world coordinates, with the mirror camera parked permanently here. See the
-- comment above the placement loops in updateMirror for why.
local VIEWPORT_ANCHOR = CFrame.identity

-- Hold the driven car still in viewport space instead of re-placing it every
-- frame. It is welded to the same chassis the mirror is, so its position in
-- the mirror genuinely cannot change - recomputing it each frame is not just
-- wasted work, it is wasted work that reintroduces floating-point shimmer.
--
-- The tradeoff: anything on the car that moves RELATIVE to the chassis stops
-- moving in the mirror too, so your own wheels do not visibly spin there. At
-- mirror size that is close to unnoticeable and worth the trade; set false to
-- go back to per-frame placement and get it back.
--
-- Only applies in "Camera" + "Rearward", the one combination where the view is
-- derived purely from the chassis. "Physical" and "Reflect" both aim off the
-- driver's HEAD, which drifts independently, so the car's place in the mirror
-- is genuinely not constant there and freezing it would smear. Start() checks
-- this and falls back to per-frame placement on its own.
local FREEZE_OWN_CAR = true
-- How far the mirror has to shift relative to the chassis before the frozen
-- car is rebuilt - i.e. the door it is mounted on swinging open.
local FREEZE_EPSILON = 1e-4

-- Draw the mirrors through anything in front of them.
--
-- This exists for one specific problem: a SurfaceGui seen through a partly
-- transparent part (a door window at Transparency 0.8) often does not draw at
-- all. Roblox renders transparent surfaces in a separate pass that does not
-- write depth, and the GUI loses the sort - it is a render-order quirk, not
-- anything wrong with the mirror, and no property on the WINDOW reliably fixes
-- it. AlwaysOnTop sidesteps sorting entirely.
--
-- The cost is that it sidesteps sorting ENTIRELY: the mirror will also draw
-- over the door frame, the pillar, and anything else that should legitimately
-- hide it, so a mirror out of sight behind bodywork still shows through. On a
-- door mirror that is mostly unobstructed anyway this is often an acceptable
-- trade; judge it by eye. If it looks wrong, the clean fix is to delete the
-- door window or set it to Transparency 1 rather than to live with this.
local SURFACE_ALWAYS_ON_TOP = false

-- A real door mirror is convex and shows far more than a flat window of the
-- same size would. FOV is derived from the glass's actual angular size (which
-- is what makes a FLAT mirror geometrically correct) and then widened by this.
-- 1.0 is a true flat mirror.
local FOV_SCALE = 2.5
-- ...and a floor under the result, because on a small mirror the geometric
-- figure is tiny: a 0.53-stud-tall glass four studs from the eye subtends
-- about 7.6 degrees, so even 2.5x lands at 19 and shows a keyhole. A real
-- convex door mirror is 25-40 degrees, which is what this pins it to.
--
-- TUNING: this is the "how much can I see in the mirror" knob and it is the
-- one most likely to need taste applied. Raise for a wider, more useful
-- mirror; lower towards a flat, more literally-correct one.
local MIN_FOV = 24

-- The FOV used by the fixed "Rearward" camera, in degrees. A real convex door
-- mirror is 25-40; higher shows more road and smaller detail.
local MIRROR_FOV = 40

-- Where the mirror POINTS, which is a separate question from where its glass
-- is, and the likelier of the two to be wrong.
--
--   "Physical" - bounce the driver's line of sight off the glass, the way
--     light does. Correct, and completely at the mercy of how the mirror mesh
--     is rotated: a glass whose normal points straight at the driver reflects
--     straight back at them, so the mirror faithfully shows the driver's own
--     door. That is real mirror behaviour (look at a mirror head-on, see
--     yourself) and a useless mirror. Real door mirrors are angled outward and
--     back; a modelled one usually is not, or not by enough.
--
--   "Rearward" - ignore the glass orientation and aim off the CHASSIS:
--     straight back, yawed outward by the car config Yaw for the side it is
--     on. Not physically derived, but it always shows the road behind the
--     truck no matter how the mesh was built, which is the entire point of
--     having a mirror.
--
-- Start on "Rearward" to get a useful image, then switch to "Physical" once
-- the mirror meshes are actually angled the way real ones are.
local AIM_MODE = "Rearward"

-- ===== WHERE THE MIRROR ANGLES LIVE =====
--
-- Not here any more. Yaw and Pitch are per CAR TYPE, in that car's
-- ReplicatedStorage/Modules/Vehicles/Configs/<name>.luau under a `Mirrors`
-- table - defaults and the full explanation are in VehiclePhysics, at
-- DEFAULT_MIRRORS. They belong there because the right angle depends on the
-- cab: body width, how far the mirrors stand off it and how high the driver
-- sits all change what frames the road instead of the truck's own flank, so a
-- van and a low sports car want genuinely different numbers.
--
-- Precedence per mirror, highest first: a MirrorYaw / MirrorPitch attribute on
-- the mirror part or its Glass (for nudging one instance live in Studio) >
-- that car's config file > DEFAULT_MIRRORS.

-- Greebles cost the same per frame as a wall and contribute nothing at mirror
-- resolution.
local MIN_PART_VOLUME = 0.5

-- Studs of clearance a part's box must leave around the viewport camera before
-- it is allowed into the mirror (see swallowsPoint). Only parts actually
-- wrapped around the lens are rejected, so this can be small - it exists to
-- catch a panel the camera is flush against, not to keep the truck out.
local NEAR_CLIP_MARGIN = 0.35

-- Frustum-based rate throttling. Off while the mirrors are still being dialled
-- in, so an unchanging mirror is never the culling's fault - a mirror out of
-- view then costs exactly what one in view costs. Turn back on once the image
-- itself is right; see OFFSCREEN_HZ for why it cannot cause a blank frame.
local CULL_WHEN_OFFSCREEN = true

-- Clones are never destroyed on the frame they leave view - they are just
-- unparented, so coming back is a reparent rather than a re-clone. This is
-- how long an unused one is kept before it's finally released.
local POOL_TTL = 20

local VIEWPORT_AMBIENT = Color3.fromRGB(140, 140, 140)
local VIEWPORT_LIGHT_COLOR = Color3.fromRGB(255, 255, 255)
local VIEWPORT_LIGHT_DIRECTION = Vector3.new(-0.4, -1, -0.3)
-- Shows through wherever no cloned geometry covers - i.e. the sky.
local VIEWPORT_BACKGROUND = Color3.fromRGB(150, 176, 202)

-- The mirror parts to look for inside the car's Mirror folder. RearViewMirror
-- is genuinely optional; missing ones are skipped silently.
local MIRROR_NAMES = { "LeftMirror", "RightMirror", "RearViewMirror" }

-- Which way each SurfaceGui face points in the part's own space, and which way
-- is "up" across that face - needed to work out the glass's height, which is
-- what sets the vertical FOV.
local FACE_AXES = {
	Front = { Normal = Vector3.new(0, 0, -1), Up = Vector3.new(0, 1, 0) },
	Back = { Normal = Vector3.new(0, 0, 1), Up = Vector3.new(0, 1, 0) },
	Right = { Normal = Vector3.new(1, 0, 0), Up = Vector3.new(0, 1, 0) },
	Left = { Normal = Vector3.new(-1, 0, 0), Up = Vector3.new(0, 1, 0) },
	Top = { Normal = Vector3.new(0, 1, 0), Up = Vector3.new(0, 0, -1) },
	Bottom = { Normal = Vector3.new(0, -1, 0), Up = Vector3.new(0, 0, -1) },
}

-- Sitting in the driver's seat you look at the BACK of the mirror part, so
-- that is the default. Override per mirror with a MirrorFace attribute
-- ("Front", "Left", ...) on the mirror part or its Glass.
local DEFAULT_FACE = "Back"

-- =========================================================================
-- Geometry
-- =========================================================================

-- The affine reflection across the plane through `point` with unit `normal`,
-- packed into a CFrame so the per-clone work is one C-side multiply rather
-- than a dozen Lua vector ops.
--
-- R = I - 2nn^T, and since R*p = p - 2(p.n)n the translation that keeps the
-- plane fixed works out to just 2(point.n)n. The resulting matrix has
-- determinant -1, which is exactly the point (that is what flips the image)
-- and exactly why probeReflectionSupport exists.
local function reflectionCFrame(point, normal)
	local n = normal.Unit
	local nx, ny, nz = n.X, n.Y, n.Z
	local t = 2 * point:Dot(n) * n
	return CFrame.new(
		t.X, t.Y, t.Z,
		1 - 2 * nx * nx, -2 * nx * ny, -2 * nx * nz,
		-2 * ny * nx, 1 - 2 * ny * ny, -2 * ny * nz,
		-2 * nz * nx, -2 * nz * ny, 1 - 2 * nz * nz
	)
end

local function reflectVector(v, normal)
	return v - 2 * v:Dot(normal) * normal
end

-- Does a mirrored CFrame survive being built and read back? For a normal
-- right-handed basis right x up equals back (-look), so that dot is +1; a
-- reflected basis makes it -1. If Roblox ever starts orthonormalising these
-- away, this returns false and everything transparently uses "Camera" mode.
local function probeReflectionSupport()
	local ok, reflected = pcall(function()
		local cf = reflectionCFrame(Vector3.zero, Vector3.new(1, 0, 0))
		local probe = Instance.new("Part")
		probe.Anchored = true
		probe.CFrame = cf
		local readBack = probe.CFrame
		probe:Destroy()
		return readBack.RightVector:Cross(readBack.UpVector):Dot(-readBack.LookVector) < 0
	end)
	return ok and reflected == true
end

-- =========================================================================
-- Rig setup
-- =========================================================================

local warnedNoGlass = {}

-- A thin rectangular Part child named "Glass" is the supported way to mount a
-- mirror image on an irregular mesh; without one the SurfaceGui goes on the
-- mesh's bounding box, which is only right if the mesh happens to be a flat
-- box already. Warned once per part rather than per session so swapping cars
-- doesn't spam.
local function findGlass(mirrorPart)
	local glass = mirrorPart:FindFirstChild("Glass")
	if glass and glass:IsA("BasePart") then
		return glass
	end
	if mirrorPart:IsA("BasePart") then
		if not warnedNoGlass[mirrorPart] then
			warnedNoGlass[mirrorPart] = true
			warn(
				"VehicleMirrorViews: " .. mirrorPart:GetFullName() .. " has no 'Glass' part - "
					.. "falling back to the mirror part's own bounding box, which will look wrong "
					.. "if the mesh isn't a flat box. Add a thin rectangular Part named Glass welded "
					.. "onto the reflective face."
			)
		end
		return mirrorPart
	end
	return nil
end

local function faceOf(mirrorPart, glass)
	local name = glass:GetAttribute("MirrorFace") or mirrorPart:GetAttribute("MirrorFace") or DEFAULT_FACE
	if not FACE_AXES[name] then
		warn(
			"VehicleMirrorViews: unknown MirrorFace '"
				.. tostring(name)
				.. "' on "
				.. glass:GetFullName()
				.. " - using "
				.. DEFAULT_FACE
		)
		name = DEFAULT_FACE
	end
	return name
end

local function buildRig(mirrorPart, aim)
	local glass = findGlass(mirrorPart)
	if not glass then
		return nil
	end

	-- Anything left over from a previous session (or a reload in Studio).
	-- Named per mirror because all three now live side by side in PlayerGui
	-- rather than one under each glass part.
	local guiName = "MirrorView_" .. mirrorPart.Name
	local stale = playerGui:FindFirstChild(guiName)
	if stale then
		stale:Destroy()
	end

	local face = faceOf(mirrorPart, glass)
	local axes = FACE_AXES[face]

	-- The two in-face extents of the glass. Up is given; the other one is
	-- perpendicular to both it and the normal.
	local widthAxis = axes.Up:Cross(axes.Normal)
	local faceWidth = (glass.Size * widthAxis).Magnitude
	local faceHeight = (glass.Size * axes.Up).Magnitude
	local longestEdge = math.max(faceWidth, faceHeight, 0.01)

	local gui = Instance.new("SurfaceGui")
	gui.Name = guiName
	gui.Face = Enum.NormalId[face]
	gui.PixelsPerStud = glass:GetAttribute("MirrorPixelsPerStud")
		or math.clamp(TARGET_CANVAS_PIXELS / longestEdge, MIN_PIXELS_PER_STUD, MAX_PIXELS_PER_STUD)
	gui.MaxDistance = MAX_DISTANCE
	-- The viewport supplies its own lighting; letting world light multiply on
	-- top of it just makes the mirror go black at night.
	gui.LightInfluence = 0
	gui.AlwaysOnTop = SURFACE_ALWAYS_ON_TOP
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	-- It lives in PlayerGui now, where the default behaviour is to be wiped on
	-- respawn. Stop() owns its lifetime instead.
	gui.ResetOnSpawn = false

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "View"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundColor3 = VIEWPORT_BACKGROUND
	viewport.BackgroundTransparency = 0
	viewport.BorderSizePixel = 0
	viewport.Ambient = VIEWPORT_AMBIENT
	viewport.LightColor = VIEWPORT_LIGHT_COLOR
	viewport.LightDirection = VIEWPORT_LIGHT_DIRECTION
	viewport.Parent = gui

	local world = Instance.new("Folder")
	world.Name = "World"
	world.Parent = viewport

	local camera = Instance.new("Camera")
	camera.Name = "MirrorCamera"
	camera.Parent = viewport
	camera.CFrame = VIEWPORT_ANCHOR
	viewport.CurrentCamera = camera

	-- THE thing that makes a ViewportFrame work on a world surface, and it is
	-- not optional: a SurfaceGui parented directly to the BasePart renders 2D
	-- children (Frames, TextLabels) perfectly well, but any ViewportFrame
	-- inside it comes out blank. It has to live in PlayerGui with Adornee
	-- pointing at the part instead. If a mirror ever goes blank, check this
	-- first.
	--
	-- Enabled is held off until the tree has settled and the camera is
	-- assigned, so nothing is ever shown mid-construction.
	gui.Adornee = glass
	gui.Parent = playerGui
	task.defer(function()
		if gui.Parent then
			gui.Enabled = true
		end
	end)

	return {
		Glass = glass,
		Axes = axes,
		Gui = gui,
		Camera = camera,
		World = world,
		Aspect = faceWidth / math.max(faceHeight, 1e-6),
		FovScale = glass:GetAttribute("MirrorFovScale") or mirrorPart:GetAttribute("MirrorFovScale") or FOV_SCALE,
		Yaw = glass:GetAttribute("MirrorYaw") or mirrorPart:GetAttribute("MirrorYaw") or aim.Yaw or 0,
		Pitch = glass:GetAttribute("MirrorPitch") or mirrorPart:GetAttribute("MirrorPitch") or aim.Pitch or 0,
		-- [sourcePart] = { Clone = ..., LastSeen = t }. Entries stay here
		-- after leaving view; only Parent is cleared.
		Pool = {},
		-- [sourcePart] = clone, the subset currently parented into World.
		Active = {},
		-- Active, split by whether the source rides on the driven car. Only
		-- ActiveWorld is walked every frame; ActiveCar is written once and
		-- then left alone until the mirror moves relative to the chassis.
		ActiveCar = {},
		ActiveWorld = {},
		CarDirty = true,
		FrozenBasis = nil,
		NextUpdate = 0,
	}
end

-- =========================================================================
-- Cloning
-- =========================================================================

-- Everything that isn't geometry or surface appearance is dead weight inside a
-- ViewportFrame: welds, attachments, constraints, sounds, particles and lights
-- either do nothing there or actively cost. GUIs in particular MUST go, or a
-- cloned mirror would carry its own SurfaceGui and recurse.
local function makeClone(source)
	local ok, clone = pcall(function()
		return source:Clone()
	end)
	if not ok or not clone then
		return nil
	end

	for _, descendant in clone:GetDescendants() do
		if
			not (
				descendant:IsA("SurfaceAppearance")
				or descendant:IsA("Decal")
				or descendant:IsA("Texture")
				or descendant:IsA("SpecialMesh")
			)
		then
			descendant:Destroy()
		end
	end

	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.CastShadow = false
	clone.Massless = true
	return clone
end

-- =========================================================================
-- Scene selection
-- =========================================================================

-- One spatial query per refresh for all three mirrors, centred on the chassis.
-- Each mirror then filters this down to what is actually on its own reflective
-- side, so the expensive part happens once rather than three times.
local function queryNearby(state)
	local chassis = state.Chassis
	if not chassis or not chassis.Parent then
		return nil
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = state.Exclude
	params.MaxParts = MAX_QUERY_PARTS
	params.RespectCanCollide = false

	local ok, parts = pcall(function()
		return workspace:GetPartBoundsInRadius(chassis.Position, sceneRadius(), params)
	end)
	if not ok then
		return nil
	end
	return parts
end

local function isWorthCloning(part)
	if part.Transparency >= 1 then
		return false
	end
	local size = part.Size
	return size.X * size.Y * size.Z >= MIN_PART_VOLUME
end

-- Picks the best-looking MirrorDetail parts on the reflective side of this
-- mirror's plane, then diffs that against what is already in the scene:
-- newcomers get reparented in (cloned only if never seen before), leavers get
-- reparented out but kept. Nothing is created or destroyed in the steady
-- state, which is what keeps a refresh off the frame budget.
-- The nearest point of a part's box to a world position. Used for ranking:
-- distance to a part you are touching should read as ~0 whatever its size.
local function closestPointOnPart(part, worldPos)
	local cf = part.CFrame
	local localPos = cf:PointToObjectSpace(worldPos)
	local half = part.Size * 0.5
	return cf:PointToWorldSpace(Vector3.new(
		math.clamp(localPos.X, -half.X, half.X),
		math.clamp(localPos.Y, -half.Y, half.Y),
		math.clamp(localPos.Z, -half.Z, half.Z)
	))
end

-- How far the part reaches past the mirror plane, measured to the FURTHEST
-- corner of its box rather than to its centre. Positive means some of it is on
-- the reflective side and it belongs in the mirror.
--
-- The box's half-width along the plane normal is the sum of each local axis'
-- half-extent projected onto that normal - exact for an oriented box, and
-- cheap. This is what lets the ground in: the baseplate's centre is far off
-- and often on the wrong side, but it reaches hundreds of studs past the plane.
local function extentPastPlane(part, planePos, normal)
	local cf = part.CFrame
	local half = part.Size * 0.5
	local reach = math.abs(half.X * cf.RightVector:Dot(normal))
		+ math.abs(half.Y * cf.UpVector:Dot(normal))
		+ math.abs(half.Z * cf.LookVector:Dot(normal))
	return (part.Position - planePos):Dot(normal) + reach
end

-- Is the viewport camera inside this part, as this mode will actually render
-- it? A real mirror CLIPS geometry at its plane; a ViewportFrame has no user
-- clip plane, so a part straddling the plane arrives whole and can end up
-- wrapped around the lens, which renders as a flat wall of colour.
--
-- Testing box containment rather than a bounding SPHERE matters now that the
-- ground is allowed in: the baseplate's bounding sphere swallows everything
-- for a thousand studs and a sphere test would reject it outright, but the
-- camera is simply above it, comfortably outside the box.
--
-- Reflection is its own inverse, so rather than invert an improper matrix,
-- reflect the CAMERA and test it against the unreflected part.
local function swallowsPoint(part, worldPos, transform)
	local probe = if transform then transform * worldPos else worldPos
	local localPos = part.CFrame:PointToObjectSpace(probe)
	local half = part.Size * 0.5
	return math.abs(localPos.X) < half.X + NEAR_CLIP_MARGIN
		and math.abs(localPos.Y) < half.Y + NEAR_CLIP_MARGIN
		and math.abs(localPos.Z) < half.Z + NEAR_CLIP_MARGIN
end

-- Is any part of this box inside the mirror camera's view cone?
--
-- This is the cheapest large win available here. The half-space test above
-- keeps everything BEHIND the mirror - a full 180 degrees - but the mirror
-- only shows about 40 degrees vertically and 65 horizontally. Without this,
-- roughly six times more geometry is cloned than can ever appear, and all of
-- it competes for the same MirrorDetail budget as the things you can see.
--
-- Deliberately conservative: the part's bounding radius is added to the
-- frustum limits, so anything even partly in view is kept. Cheaper to clone a
-- few extra than to have scenery pop in at the edges of the glass.
local function insideFrustum(position, radius, view)
	local localPos = view.CF:PointToObjectSpace(position)
	local depth = -localPos.Z
	if depth < -radius then
		return false
	end
	return math.abs(localPos.X) <= depth * view.TanH + radius
		and math.abs(localPos.Y) <= depth * view.TanV + radius
end

-- Can the mirror actually SEE this part, or is a wall in the way? One ray from
-- the camera: if the first thing it meets is the part itself, it is visible.
--
-- Aimed at the NEAREST POINT of the part, not its centre. Aiming at the centre
-- works for props and fails badly for anything large: the floor's centre can be
-- hundreds of studs away with a building in between, so the ground under your
-- own wheels tests as hidden and the mirror loses its floor. The nearest point
-- of the floor is directly below the mirror, which is the honest question.
--
-- Parts bigger than OCCLUSION_MAX_RADIUS skip the test entirely. A single ray
-- cannot represent a 2000-stud baseplate at all, and structural geometry of
-- that size is what does the OCCLUDING - it is almost never the thing that
-- ought to be culled.
--
-- The car and the mirror hardware are excluded from the ray rather than
-- treated as occluders. They genuinely do block the view, but they are also
-- millimetres from the camera and would cull huge amounts of what you can
-- plainly see past them.
local function isVisible(part, view, params)
	if part.Size.Magnitude * 0.5 > OCCLUSION_MAX_RADIUS then
		return true
	end
	local target = closestPointOnPart(part, view.Origin)
	local direction = target - view.Origin
	local distance = direction.Magnitude
	if distance < 0.5 then
		return true
	end
	-- Overshoot slightly: the target sits exactly ON the surface, and a ray
	-- ending precisely there can miss it to floating point.
	local hit = workspace:Raycast(view.Origin, direction.Unit * (distance + 0.5), params)
	return hit == nil or hit.Instance == part
end

local candidates = {}
local pinned = {}
local function refreshScene(mirror, nearby, surfacePos, normal, now, camPos, transform, view)
	table.clear(candidates)
	table.clear(pinned)

	-- The driven car is PINNED: read straight off the model instead of out of
	-- the spatial query, and exempt from the MirrorDetail cap. Both halves matter.
	--
	-- Out of the query, it was subject to MAX_QUERY_PARTS, and that cap does
	-- not return the NEAREST parts - it returns an arbitrary subset. So every
	-- refresh handed back a different slice of the truck and its panels
	-- flickered in and out five times a second. That is the jitter.
	--
	-- Subject to the cap, it also lost its slots to whatever was closest: back
	-- up to a wall and a few hundred wall studs outrank your own bodywork and
	-- evict it. That is the car vanishing near walls. Your own car is the one
	-- thing in the mirror that must never blink, so it competes for nothing.
	for _, part in state.CarPartList do
		if
			part.Parent
			and isWorthCloning(part)
			and extentPastPlane(part, surfacePos, normal) > 0
			and not swallowsPoint(part, camPos, transform)
		then
			table.insert(pinned, part)
		end
	end

	for _, part in nearby do
		if isWorthCloning(part) and not state.CarParts[part] then
			-- Both tests below work on the part's BOX, not its centre point.
			-- Treating a part as its centre is fine for scenery and badly
			-- wrong for the two cases that matter most here: the baseplate,
			-- whose centre can be hundreds of studs away and on the wrong side
			-- of the mirror even though the ground directly under you is part
			-- of it, and your own truck, whose panels sit right on the plane.
			-- The lens guard applies ONLY when reflecting. It exists to
			-- compensate for the one thing a ViewportFrame cannot do - clip
			-- geometry at the mirror plane - so a part straddling that plane
			-- does not arrive whole and wrap itself around the camera.
			--
			-- Without a reflection there is nothing to compensate for:
			-- everything sits where it really sits, and if the camera is
			-- inside a wall then the mirror is genuinely inside a wall.
			-- Applying the guard there is what made a building vanish when you
			-- backed up against it: a building is often one big part, the
			-- mirror clipped into it, and the guard threw the whole thing out.
			local swallowed = transform ~= nil and swallowsPoint(part, camPos, transform)
			local renderedCentre = if transform then transform * part.Position else part.Position
			local radius = part.Size.Magnitude * 0.5
			if
				extentPastPlane(part, surfacePos, normal) > 0
				and not swallowed
				and insideFrustum(renderedCentre, radius, view)
			then
				-- Ranked by distance to the NEAREST POINT of the part's box,
				-- not to its centre. That single choice is what lets big
				-- things compete properly: a building's nearest face is close
				-- even though its centre is far, and the ground you are
				-- standing on reads as touching, which it is. An earlier
				-- version ranked by apparent size instead, and the effect was
				-- that raising render distance made small objects LESS likely
				-- to appear - a barrel twenty studs back lost its slot to
				-- every large thing newly in range, which is the opposite of
				-- what the setting promises.
				table.insert(candidates, {
					Part = part,
					Dist = (closestPointOnPart(part, surfacePos) - surfacePos).Magnitude,
				})
			end
		end
	end

	table.sort(candidates, function(a, b)
		return a.Dist < b.Dist
	end)

	local wanted = {}
	for _, part in pinned do
		wanted[part] = true
	end

	-- Whatever the car did not use, nearest first, skipping anything a wall is
	-- in front of.
	--
	-- The occlusion test walks the SORTED list and stops once the budget is
	-- full, so it costs at most one ray per slot rather than one per candidate.
	-- That ordering is the whole reason it is affordable: testing everything
	-- the query returned would be thousands of rays a tick, testing only what
	-- could actually be shown is a few hundred.
	local occlusionOn = GameSettings.Get("MirrorOcclusionCulling")
	local budget = math.max(maxSceneParts() - #pinned, 0)
	local filled = 0
	for index = 1, #candidates do
		if filled >= budget then
			break
		end
		local part = candidates[index].Part
		local entry = mirror.Pool[part]
		local visible = true
		if occlusionOn then
			if isVisible(part, view, state.OcclusionParams) then
				if entry then
					entry.LastVisible = now
				end
			else
				-- A grace period, because a single ray to a single point is a
				-- blunt test: a part can flick behind a lamp post for one tick
				-- and back. Dropping it instantly makes scenery blink. Only
				-- something hidden CONTINUOUSLY for this long actually goes.
				visible = entry ~= nil
					and entry.LastVisible ~= nil
					and (now - entry.LastVisible) < OCCLUSION_GRACE
			end
		end
		if visible then
			wanted[part] = true
			filled += 1
		end
	end

	-- Out: still pooled, just not rendered.
	for source, clone in mirror.Active do
		if not wanted[source] then
			clone.Parent = nil
			mirror.Active[source] = nil
			mirror.ActiveCar[source] = nil
			mirror.ActiveWorld[source] = nil
		end
	end

	-- In: reuse a pooled clone if we have one, otherwise build it - but only
	-- up to MAX_NEW_CLONES_PER_REFRESH of the latter.
	--
	-- Cloning is by far the most expensive thing this module does, and it
	-- arrives in bursts: raise the render distance, or drive into a dense
	-- street, and several hundred parts want cloning on the SAME tick. That is
	-- a frame hitch, and a frame hitch is not a cosmetic problem here - the
	-- raycast suspension integrates its spring and damper against the frame
	-- delta (see VehiclePhysics.Step), so a long frame makes the truck
	-- overshoot, bottom out and bounce. Mirrors must never be able to do that.
	--
	-- Spreading creation over ticks costs nothing visually: a part that has to
	-- wait a tick or two appears a fraction of a second late, which is
	-- invisible in a mirror, and everything already cloned keeps updating at
	-- full rate meanwhile.
	local newClones = 0
	for source in wanted do
		local entry = mirror.Pool[source]
		if not entry and newClones < MAX_NEW_CLONES_PER_REFRESH then
			local clone = makeClone(source)
			if clone then
				newClones += 1
				entry = { Clone = clone, LastSeen = now, LastVisible = now }
				mirror.Pool[source] = entry
			end
		end
		if entry then
			entry.LastSeen = now
			if not mirror.Active[source] then
				entry.Clone.Parent = mirror.World
				mirror.Active[source] = entry.Clone
				if state.FreezeCar and state.CarParts[source] then
					mirror.ActiveCar[source] = entry.Clone
					-- Never placed yet, so the frozen set owes it a position.
					mirror.CarDirty = true
				else
					mirror.ActiveWorld[source] = entry.Clone
				end
			end
		end
	end

	-- Finally release anything that has been out of the scene long enough that
	-- it is not coming back, and anything whose source has been destroyed.
	for source, entry in mirror.Pool do
		if source.Parent == nil or (not mirror.Active[source] and now - entry.LastSeen > POOL_TTL) then
			entry.Clone:Destroy()
			mirror.Pool[source] = nil
			mirror.Active[source] = nil
			mirror.ActiveCar[source] = nil
			mirror.ActiveWorld[source] = nil
		end
	end
end

-- =========================================================================
-- Per-frame update
-- =========================================================================

local reflectSupported = nil

-- A mirror off the edge of the screen still updates, just slowly - see
-- OFFSCREEN_HZ. Margin is deliberately generous so this never toggles for a
-- mirror the player is looking near.
local function isInView(camera, worldPos)
	local point = camera:WorldToViewportPoint(worldPos)
	if point.Z <= 0 then
		return false
	end
	local size = camera.ViewportSize
	local mx, my = size.X * VIEW_MARGIN, size.Y * VIEW_MARGIN
	return point.X > -mx and point.X < size.X + mx and point.Y > -my and point.Y < size.Y + my
end

local function updateMirror(mirror, nearby, camera, eye, now)
	local glass = mirror.Glass
	if not glass.Parent then
		return
	end

	-- The glass's placement relative to the chassis, which is a constant while
	-- the door is shut, re-applied to the SMOOTHED chassis frame. Reading
	-- glass.CFrame directly would put the suspension tremor straight back in.
	local basis = state.Chassis.CFrame:Inverse() * glass.CFrame
	local glassCF = state.SmoothChassisCF * basis
	local axes = mirror.Axes
	-- The reflective plane is the FACE of the glass, not its centre - on a
	-- thick part those differ by enough to skew the image noticeably.
	local halfDepth = (glass.Size * axes.Normal).Magnitude / 2
	local surfacePos = (glassCF * CFrame.new(axes.Normal * halfDepth)).Position
	local normal = glassCF:VectorToWorldSpace(axes.Normal).Unit
	local height = (glass.Size * axes.Up).Magnitude
	-- The viewport camera's up has to be the GLASS's up, not the world's, or
	-- the horizon inside the mirror stays level while the mirror frame around
	-- it rolls with the truck - which reads instantly as fake. (It is the same
	-- vector in both modes: an axis lying in the mirror plane is unchanged by
	-- reflecting across that plane.)
	local up = glassCF:VectorToWorldSpace(axes.Up).Unit

	local dist = (eye - surfacePos).Magnitude
	if dist < 0.05 then
		return
	end

	if CULL_WHEN_OFFSCREEN then
		local inView = isInView(camera, surfacePos)
		if not inView and now < mirror.NextUpdate then
			return
		end
		mirror.NextUpdate = if inView then 0 else now + 1 / OFFSCREEN_HZ
	end

	-- A flat mirror shows exactly the angular window its glass subtends from
	-- the eye; FovScale then widens that to fake a convex door mirror.
	--
	-- The unavoidable compromise: a real mirror needs an OBLIQUE (off-axis)
	-- projection and a ViewportFrame camera only does a symmetric one, so the
	-- further the eye sits off the mirror's axis the more the parallax drifts.
	-- At door-mirror size on screen it isn't visible.
	-- "Rearward" is a FIXED camera, so it gets a fixed FOV. Deriving it from
	-- eye-to-glass distance is only meaningful when the camera is at the eye
	-- ("Physical"); with a bolted-down camera it just makes the mirror breathe
	-- as the player's head drifts, which is the 58 -> 75 -> 58 swing in the
	-- debug log and is pure noise.
	local fov
	if AIM_MODE == "Rearward" then
		fov = MIRROR_FOV
	else
		fov = math.max(math.deg(2 * math.atan((height / 2) / dist)) * mirror.FovScale, MIN_FOV)
	end
	local viewCamera = mirror.Camera
	viewCamera.FieldOfView = math.clamp(fov, 5, 110)

	local transform
	local camPos
	local worldViewCF
	local filterNormal = normal
	if state.Mode == "Reflect" then
		-- World gets mirrored, camera stays at the player's real eye. This is
		-- the branch that produces a genuine left-right flip, and because the
		-- eye is where it really is, the car's own bodywork frames the shot
		-- exactly as it would in life.
		transform = reflectionCFrame(surfacePos, normal)
		camPos = eye
		worldViewCF = CFrame.lookAt(eye, surfacePos, up)
	else
		-- World is copied as-is and the camera does the work instead. Sitting
		-- it AT the glass rather than at the reflected eye matters: the
		-- reflected eye is behind the mirror, looking straight into the cab.
		local outDir
		if AIM_MODE == "Rearward" then
			-- Straight back off the chassis (carCFrame.LookVector is the car's
			-- forward - see VehiclePhysics), then yawed outward and pitched
			-- down. Deliberately ignores the glass's own orientation: see
			-- AIM_MODE. Adjust in the car config (see DEFAULT_MIRRORS).
			local back = -state.SmoothChassisCF.LookVector
			local yawed = (CFrame.fromAxisAngle(Vector3.yAxis, math.rad(mirror.Yaw)) * back).Unit
			-- Pitch about the horizontal axis perpendicular to the aim, so
			-- "down" stays down regardless of how far the mirror is yawed out.
			-- Negated because a positive rotation about that axis lifts the
			-- aim, and Pitch is written as degrees DOWN.
			local pitchAxis = yawed:Cross(Vector3.yAxis)
			if pitchAxis.Magnitude > 1e-4 then
				outDir = (CFrame.fromAxisAngle(pitchAxis.Unit, math.rad(-mirror.Pitch)) * yawed).Unit
			else
				outDir = yawed
			end
		else
			outDir = reflectVector((surfacePos - eye).Unit, normal)
		end
		camPos = surfacePos + normal * 0.05
		worldViewCF = CFrame.lookAt(camPos, camPos + outDir, up)
		-- The car is deliberately NOT excluded any more. It used to be, because
		-- with a centre-point plane test the dashboard landed on the lens; the
		-- box tests in refreshScene handle that properly now, rejecting only
		-- what is actually wrapped around the camera. Everything else sorts out
		-- by ordinary occlusion - the door hides the cab behind it, exactly as
		-- it does in life - and seeing your own bodywork is most of what makes
		-- a mirror read as real.
		-- Select the scene against where the camera actually LOOKS, not where
		-- the glass happens to face. With a rearward aim those are different
		-- directions, and filtering on the glass normal would throw away the
		-- very geometry the camera is pointed at.
		filterNormal = outDir
	end

	if nearby then
		-- The frustum the mirror camera actually sees, handed to refreshScene so
		-- it can reject anything outside it. TanH comes off the glass's own
		-- shape - a wide, short mirror sees a wide, short cone.
		local tanV = math.tan(math.rad(viewCamera.FieldOfView) * 0.5)
		refreshScene(mirror, nearby, surfacePos, filterNormal, now, camPos, transform, {
			CF = worldViewCF,
			Origin = camPos,
			TanV = tanV,
			TanH = tanV * mirror.Aspect,
		})
	end

	-- Everything is placed in the VIEWPORT's own space, not at real world
	-- coordinates: the camera stays parked at VIEWPORT_ANCHOR and clones are
	-- written relative to it. Two payoffs, both of which otherwise show up as
	-- jitter.
	--
	-- 1. The car becomes free. A part welded to the chassis and a mirror
	--    welded to that same chassis never move relative to each other, so the
	--    car's position IN VIEWPORT SPACE is a constant. Compute it once and
	--    it is correct forever. That is the snapshot idea done as arithmetic
	--    rather than as a captured image, which Roblox gives no way to take.
	-- 2. Precision. Clones sit near the origin instead of out at the map's
	--    real coordinates, so the multiply chain keeps far more significant
	--    figures. Error out there reads as shimmer at mirror magnification.
	local toViewport = VIEWPORT_ANCHOR * worldViewCF:Inverse()

	-- The frozen car is rebuilt only when the mirror has actually moved
	-- relative to the chassis - in practice, when the door it is mounted on
	-- swings open. One CFrame compare per mirror replaces ~50 multiplies.
	-- `basis` is the glass relative to the chassis, computed at the top of this
	-- function. It is constant while the door is shut, so a change in it means
	-- the door has swung and the frozen car has to be re-placed.
	if state.FreezeCar then
		if not (mirror.FrozenBasis and mirror.FrozenBasis:FuzzyEq(basis, FREEZE_EPSILON)) then
			mirror.FrozenBasis = basis
			mirror.CarDirty = true
		end
	end

	if transform then
		if mirror.CarDirty then
			for source, clone in mirror.ActiveCar do
				clone.CFrame = toViewport * transform * source.CFrame
			end
		end
		for source, clone in mirror.ActiveWorld do
			clone.CFrame = toViewport * transform * source.CFrame
		end
	else
		if mirror.CarDirty then
			for source, clone in mirror.ActiveCar do
				clone.CFrame = toViewport * source.CFrame
			end
		end
		for source, clone in mirror.ActiveWorld do
			clone.CFrame = toViewport * source.CFrame
		end
	end
	mirror.CarDirty = false
end

local function onRenderStep(dt)
	if not state then
		return
	end

	-- Switched off in the settings menu. The rigs are left standing rather
	-- than torn down: turning them back on is then a property write, with the
	-- scene already populated, instead of re-cloning a few hundred parts in
	-- one frame. CarDirty is set so the frozen car is re-placed on the way
	-- back in, since the world will have moved on underneath it.
	local enabled = GameSettings.Get("MirrorsEnabled")
	if enabled ~= state.Enabled then
		state.Enabled = enabled
		for _, mirror in state.Mirrors do
			mirror.Gui.Enabled = enabled
			mirror.CarDirty = true
		end
	end
	if not enabled then
		return
	end

	if not state.CarModel.Parent or not state.Chassis.Parent then
		VehicleMirrorViews.Stop()
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	-- One smoothed chassis frame per FRAME, shared by all three mirrors, so
	-- they cannot drift apart from each other.
	local chassisCF = state.Chassis.CFrame
	if
		not state.SmoothChassisCF
		or (chassisCF.Position - state.SmoothChassisCF.Position).Magnitude > AIM_SNAP_DISTANCE
	then
		state.SmoothChassisCF = chassisCF
	else
		-- Frame-rate independent: the same wall-clock smoothing whatever the
		-- framerate, rather than more smoothing on a faster machine.
		state.SmoothChassisCF = state.SmoothChassisCF:Lerp(chassisCF, 1 - math.exp(-dt / AIM_SMOOTHING_TAU))
	end

	local now = os.clock()
	-- One mirror per tick, ticking at the refresh rate x mirror count so each
	-- still refreshes at that rate. The query is shared, so it runs
	-- once here and only the mirror whose turn it is consumes it; the others
	-- get nil and keep the scene they already have.
	local nearby = nil
	local refreshIndex = nil
	if now >= state.NextQuery then
		state.NextQuery = now + 1 / (refreshHz() * #state.Mirrors)
		state.RefreshCursor = (state.RefreshCursor % #state.Mirrors) + 1
		refreshIndex = state.RefreshCursor
		nearby = queryNearby(state)
	end

	-- The driver's HEAD, not workspace.CurrentCamera. In first person the two
	-- are the same place, but in third person the camera sits twenty studs
	-- behind the truck - and every piece of geometry here is derived from the
	-- eye, so from out there the mirror is computed for a viewpoint that has
	-- the whole cab between it and the glass. The head is where a driver's eye
	-- actually is, it is stable, and it makes the mirror correct for the person
	-- driving no matter where the player has zoomed to.
	local eye = state.Head and state.Head.Parent and state.Head.Position or camera.CFrame.Position
	for index, mirror in state.Mirrors do
		updateMirror(mirror, if index == refreshIndex then nearby else nil, camera, eye, now)
	end
end

-- =========================================================================
-- Public API
-- =========================================================================

function VehicleMirrorViews.Start(carModel, config)
	VehicleMirrorViews.Stop()

	local mirrorFolder = carModel:FindFirstChild("Mirror")
	if not mirrorFolder then
		return
	end

	local chassis = carModel.PrimaryPart
	if not chassis then
		return
	end

	if reflectSupported == nil then
		reflectSupported = probeReflectionSupport()
		if not reflectSupported then
			warn("VehicleMirrorViews: mirrored CFrames aren't surviving here - falling back to unflipped 'Camera' mode.")
		end
	end

	-- Aim angles come from the car's own config (VehiclePhysics DEFAULT_MIRRORS
	-- merged with Configs/<name>.luau). The empty fallback keeps a caller that
	-- passes no config working - every mirror just reads 0/0 and looks straight
	-- back, which is wrong but harmless and obvious.
	local mirrorAims = (config and config.Mirrors) or {}

	local mirrors = {}
	for _, name in MIRROR_NAMES do
		local part = mirrorFolder:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local rig = buildRig(part, mirrorAims[name] or {})
			if rig then
				table.insert(mirrors, rig)
			end
		end
	end

	if #mirrors == 0 then
		return
	end

	-- Both shapes of the same thing: the array to iterate when pinning, the set
	-- to test against so the spatial query doesn't add them a second time.
	-- Mirror hardware is left out so a mirror never contains itself.
	local carPartList, carParts = {}, {}
	for _, descendant in carModel:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant:IsDescendantOf(mirrorFolder) then
			table.insert(carPartList, descendant)
			carParts[descendant] = true
		end
	end

	state = {
		CarModel = carModel,
		Chassis = chassis,
		Mirrors = mirrors,
		CarPartList = carPartList,
		CarParts = carParts,
		-- The mirror hardware must never appear in its own reflection, and the
		-- local character is excluded because in first person the camera sits
		-- inside its head - a full-size clone of it right at the eye would fill
		-- the rear-view mirror with the inside of a torso.
		Exclude = { mirrorFolder, player.Character },
		-- Reused every occlusion ray rather than rebuilt per cast. The car and
		-- the mirror are excluded as occluders on purpose - see isVisible.
		OcclusionParams = (function()
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { carModel, player.Character }
			return params
		end)(),
		Head = player.Character and player.Character:FindFirstChild("Head"),
		NextQuery = 0,
		RefreshCursor = 0,
		Enabled = true,
		Mode = if MIRROR_MODE == "Auto" then (if reflectSupported then "Reflect" else "Camera") else MIRROR_MODE,
		FreezeCar = FREEZE_OWN_CAR and AIM_MODE == "Rearward" and (
			if MIRROR_MODE == "Auto" then not reflectSupported else MIRROR_MODE == "Camera"
		),
	}

	-- After the camera has been placed for this frame, so the mirrors are
	-- rendered from where the player is actually looking rather than from one
	-- frame ago.
	RunService:BindToRenderStep("VehicleMirrorViews", Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

function VehicleMirrorViews.Stop()
	if not state then
		return
	end

	RunService:UnbindFromRenderStep("VehicleMirrorViews")

	for _, mirror in state.Mirrors do
		-- Destroying the SurfaceGui takes the viewport, its camera and every
		-- clone parented under World with it.
		mirror.Gui:Destroy()
		for source, entry in mirror.Pool do
			entry.Clone:Destroy()
			mirror.Pool[source] = nil
		end
		table.clear(mirror.Active)
		table.clear(mirror.ActiveCar)
		table.clear(mirror.ActiveWorld)
	end

	state = nil
end

return VehicleMirrorViews

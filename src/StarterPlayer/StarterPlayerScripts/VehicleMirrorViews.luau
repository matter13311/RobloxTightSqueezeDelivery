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
-- Two ways to produce the image, picked by MIRROR_MODE:
--
--   "Reflect" - a true mirror. Every clone gets its CFrame multiplied by the
--     reflection of the mirror plane, and the viewport camera sits at the
--     player's real eye looking at the glass. This is geometrically correct
--     AND horizontally flipped the way a real mirror is, and it costs no more
--     than the alternative because the reflection is a single CFrame multiply
--     done C-side. The catch is that it relies on Roblox accepting a
--     negative-determinant (improper) rotation matrix through CFrame's
--     12-argument constructor - see probeReflectionSupport below, which
--     checks that at runtime and falls back on its own if it doesn't hold.
--
--   "Camera" - the fallback, and what a reversing camera shows: clones are
--     copied straight across with no transform, and the CAMERA is placed at
--     the glass looking back along the reflected view direction. Correct
--     content, not flipped. Cheaper by a hair, and immune to any weirdness
--     from mirrored geometry (reversed winding order, inside-out shading).
--
-- If the mirrors look inside-out or oddly shaded, set MIRROR_MODE = "Camera".
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
-- Defaults to "Camera" because "Reflect" was tried here and does not render:
-- with a full scene correctly built and correctly placed (120 clones, nearest
-- 2.7 studs, nothing on the lens) the glass still came out flat dark grey.
-- That is the signature of reversed winding order - a mirrored transform flips
-- every triangle's facing, so backface culling draws the INSIDE of every part.
--
-- probeReflectionSupport below cannot catch this. It proves the improper
-- matrix survives being assigned to a part and read back, which it does; what
-- it cannot prove is that the renderer will draw the result. So "Auto" passes
-- its probe and then produces a grey wall, which is why it is not the default.
--
-- The cost of "Camera" is the horizontal flip: this is the view a reversing
-- camera gives, not a mirror. See the note above Stop() for why that is hard
-- to recover in a ViewportFrame, and why it is a soft loss.
local MIRROR_MODE = "Camera"

-- How far around the car to look for things worth putting in the mirror. The
-- query is centred on the chassis and shared by all three mirrors; each one
-- then keeps only what is actually behind its own glass.
local SCENE_RADIUS = 140
-- Cap on the spatial query itself, before per-mirror filtering.
--
-- Careful with this one: GetPartBoundsInRadius does NOT return the nearest
-- MaxParts, it returns an arbitrary MaxParts. So whenever the radius holds
-- more parts than this, every refresh gets a different arbitrary slice and
-- scenery flickers in and out at REFRESH_HZ. It wants to be comfortably above
-- the part count you expect within SCENE_RADIUS, not a performance knob -
-- MAX_SCENE_PARTS is the performance knob, and it picks by real distance.
local MAX_QUERY_PARTS = 1200
-- Cap on clones fed to a single mirror, nearest first. THE performance knob:
-- per-frame cost is this times three CFrame writes. Raised from 120 once the
-- car itself was allowed back in, since its own panels take ~50 slots. Drop to ~100 if mobile struggles.
local MAX_SCENE_PARTS = 180

-- Rebuilding "what is behind me" is the expensive half (a spatial query, a
-- sort and a set diff), and it does not need to happen every frame - things
-- entering and leaving a 140-stud radius is slow news. CFrames of whatever is
-- already in the scene still update at full rate, so nothing stutters.
local REFRESH_HZ = 5

-- A mirror outside the player's view keeps its scene alive and simply updates
-- more slowly - it is never torn down and never re-cloned. That is the whole
-- reason there is no blank frame when it comes back into view: the clones were
-- there the entire time, at most a sixth of a second stale.
local OFFSCREEN_HZ = 6
-- Slack on the frustum test, as a fraction of the viewport, so a mirror
-- hovering at the edge of the screen doesn't flicker between rates.
local VIEW_MARGIN = 0.25

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
		FovScale = glass:GetAttribute("MirrorFovScale") or mirrorPart:GetAttribute("MirrorFovScale") or FOV_SCALE,
		Yaw = glass:GetAttribute("MirrorYaw") or mirrorPart:GetAttribute("MirrorYaw") or aim.Yaw or 0,
		Pitch = glass:GetAttribute("MirrorPitch") or mirrorPart:GetAttribute("MirrorPitch") or aim.Pitch or 0,
		-- [sourcePart] = { Clone = ..., LastSeen = t }. Entries stay here
		-- after leaving view; only Parent is cleared.
		Pool = {},
		-- [sourcePart] = clone, the subset currently parented into World.
		Active = {},
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
		return workspace:GetPartBoundsInRadius(chassis.Position, SCENE_RADIUS, params)
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

-- Picks the nearest MAX_SCENE_PARTS parts lying on the reflective side of this
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

local candidates = {}
local pinned = {}
local function refreshScene(mirror, nearby, surfacePos, normal, now, camPos, transform)
	table.clear(candidates)
	table.clear(pinned)

	-- The driven car is PINNED: read straight off the model instead of out of
	-- the spatial query, and exempt from MAX_SCENE_PARTS. Both halves matter.
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
			if extentPastPlane(part, surfacePos, normal) > 0 and not swallowsPoint(part, camPos, transform) then
				table.insert(candidates, {
					Part = part,
					-- Sorted on the nearest point of the box, so a huge part
					-- you are standing on counts as close (which it is) rather
					-- than being ranked by its distant centre and cut by
					-- MAX_SCENE_PARTS. This is why the floor was missing.
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
	-- Whatever the car did not use, nearest first.
	local budget = math.max(MAX_SCENE_PARTS - #pinned, 0)
	for index = 1, math.min(#candidates, budget) do
		wanted[candidates[index].Part] = true
	end

	-- Out: still pooled, just not rendered.
	for source, clone in mirror.Active do
		if not wanted[source] then
			clone.Parent = nil
			mirror.Active[source] = nil
		end
	end

	-- In: reuse a pooled clone if we have one, otherwise build it.
	for source in wanted do
		local entry = mirror.Pool[source]
		if not entry then
			local clone = makeClone(source)
			if clone then
				entry = { Clone = clone, LastSeen = now }
				mirror.Pool[source] = entry
			end
		end
		if entry then
			entry.LastSeen = now
			if not mirror.Active[source] then
				entry.Clone.Parent = mirror.World
				mirror.Active[source] = entry.Clone
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

	local glassCF = glass.CFrame
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
	local filterNormal = normal
	if state.Mode == "Reflect" then
		-- World gets mirrored, camera stays at the player's real eye. This is
		-- the branch that produces a genuine left-right flip, and because the
		-- eye is where it really is, the car's own bodywork frames the shot
		-- exactly as it would in life.
		transform = reflectionCFrame(surfacePos, normal)
		camPos = eye
		viewCamera.CFrame = CFrame.lookAt(eye, surfacePos, up)
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
			local back = -state.Chassis.CFrame.LookVector
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
		viewCamera.CFrame = CFrame.lookAt(camPos, camPos + outDir, up)
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
		refreshScene(mirror, nearby, surfacePos, filterNormal, now, camPos, transform)
	end

	if transform then
		for source, clone in mirror.Active do
			clone.CFrame = transform * source.CFrame
		end
	else
		for source, clone in mirror.Active do
			clone.CFrame = source.CFrame
		end
	end
end

local function onRenderStep()
	if not state then
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

	local now = os.clock()
	-- One query shared by every mirror, at REFRESH_HZ. nil on the frames in
	-- between means "keep the scene you have and just move it".
	local nearby = nil
	if now >= state.NextQuery then
		state.NextQuery = now + 1 / REFRESH_HZ
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
	for _, mirror in state.Mirrors do
		updateMirror(mirror, nearby, camera, eye, now)
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
		Head = player.Character and player.Character:FindFirstChild("Head"),
		NextQuery = 0,
		Mode = if MIRROR_MODE == "Auto" then (if reflectSupported then "Reflect" else "Camera") else MIRROR_MODE,
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
	end

	state = nil
end

return VehicleMirrorViews

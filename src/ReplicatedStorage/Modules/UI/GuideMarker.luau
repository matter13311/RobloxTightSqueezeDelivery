-- "Go there." One target at a time, made impossible to miss.
--
-- Four things, split across two ranges by DEFAULT_NEAR_DISTANCE, because each
-- one answers a different question and each one fails on its own at exactly
-- the distance the other range's pair works:
--
--   THE BEAM - a neon column standing 300 studs out of the target. Answers
--   "where is it" from the far side of the map, over the rooftops, before the
--   player knows what they are looking for. It is the only part of this that
--   survives being a thousand studs away, and it is the part a distracted
--   player can see out of a side window without looking for it. On at every
--   range.
--
--   THE HIGHLIGHT - a glowing outline on the object itself, drawn with
--   DepthMode AlwaysOnTop so a wall in front of it changes nothing. Answers
--   "which one" once the player is close enough for there to be more than one
--   thing in view. A highlight alone is useless at range (it is the size of the
--   object, so at 400 studs it is a few pixels) and unbeatable up close, which
--   is precisely the opposite of the beam. On at every range.
--
--   THE SCREEN ARROW - a marker that sits over the target while it is on
--   screen and clamps to the edge of the screen, rotated to point, when it is
--   not. Answers "which way do I turn", which none of the other three can
--   answer at all: every one of them is invisible when the player is facing
--   the wrong way, and facing the wrong way is the entire problem. On only
--   BEYOND NearDistance.
--
--   THE BILLBOARD - a bouncing arrow and a name, pinned over the target, sized
--   in PIXELS rather than studs so it stays exactly as readable at 600 studs as
--   at 6. Answers "is that thing the thing", and names it, which is the part a
--   player has to be able to repeat back later with none of this on screen. On
--   only WITHIN NearDistance - see DEFAULT_NEAR_DISTANCE for why this and the
--   screen arrow are never both on: at range the screen arrow is already doing
--   the only useful work, and a second copy of the same label bouncing over a
--   target too small to read just reads as two different places.
--
-- WHAT IS DELIBERATELY NOT HERE: a painted route along the road. It is the
-- obvious fifth idea and it needs something this game does not have - a graph
-- of where the roads go. PathfindingService would have to be asked for a
-- humanoid-shaped path through a city built for cars, re-asked every few
-- seconds as the truck moves, and drawn as dozens of parts; it routes through
-- gaps a truck cannot fit and over kerbs it cannot climb, so at the one moment
-- it matters - a junction - it is as likely to be wrong as right. A confident
-- line that leads somewhere you cannot drive is worse than no line, because the
-- player believes it. The beam says WHERE without ever claiming to know how to
-- get there, and "how" is the part of a driving game that is the actual game.
--
-- Client-only (it reads workspace.CurrentCamera and parents a Frame into a
-- ScreenGui). Generic on purpose - it names nothing about tutorials or
-- deliveries, so a quest marker, a "your truck is over here" hint, or anything
-- else that has to point at one object can reuse it.

local RunService = game:GetService("RunService")

local GuideMarker = {}
GuideMarker.__index = GuideMarker

-- Tall enough to clear anything anyone is likely to build, thin enough not to
-- be a wall. Drawn from the target's TOP, so it never buries the object the
-- player is being pointed at.
local BEAM_HEIGHT = 300
local BEAM_WIDTH = 3.5
local BEAM_TRANSPARENCY = 0.55

-- How far above the target's top edge the billboard floats, before the bounce.
local BILLBOARD_LIFT = 4
local BOUNCE_STUDS = 0.9
local BOUNCE_SPEED = 3.4 -- radians/sec

-- The pulse everything shares, so the beam, the outline and the arrow breathe
-- together rather than reading as three separate effects that happen to be
-- near each other.
local PULSE_SPEED = 3.4

-- How far in from the screen edge the screen arrow parks when the target is off
-- screen - enough that the whole caption stays on screen rather than half a
-- word of it.
local SCREEN_MARGIN = 96
-- Deeper at the top, because the delivery HUD's job panel lives at top-centre.
local SCREEN_MARGIN_TOP = 130

-- Beyond this many studs, only the screen-space marker is on - it is the one
-- doing all the actual "which way" work at range anyway, and the billboard
-- is small enough at that distance to be pointless. Inside it, the billboard
-- takes over and the screen marker goes dark. Without this split, a target a
-- few hundred studs away showed a bouncing arrow over itself AND a diamond
-- pinned to the same spot on screen - two markers a viewer has no reason to
-- expect are describing one and the same place. Overridable per-target via
-- options.NearDistance (see SetTarget) for a marker whose target is unusually
-- large or small.
local DEFAULT_NEAR_DISTANCE = 100

local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)

--=============================================================================
-- Geometry
--=============================================================================

-- Centre and size of anything this module accepts as a target. Models and
-- BaseParts are handled separately rather than through GetPivot alone, because
-- a model's pivot is wherever the builder happened to leave it - often on the
-- floor, sometimes outside the model entirely - and the beam has to come out of
-- the top of the thing rather than out of an arbitrary point near it.
local function boundsOf(instance)
	if instance:IsA("Model") then
		local cframe, size = instance:GetBoundingBox()
		return cframe.Position, size
	end
	return instance.Position, instance.Size
end

--=============================================================================
-- Construction
--=============================================================================

-- config:
--   Parent  ScreenGui the screen arrow is drawn into (required)
--   Color   Color3 for all four elements (required)
--   Name    prefix for the instances, for anyone reading the explorer
function GuideMarker.new(config)
	local self = setmetatable({}, GuideMarker)

	self._color = config.Color
	self._target = nil
	self._options = {}

	-- One folder, so everything this marker owns can be found and destroyed in
	-- one move and the workspace root does not grow loose parts.
	local folder = Instance.new("Folder")
	folder.Name = (config.Name or "GuideMarker") .. "_World"
	folder.Parent = workspace
	self._folder = folder

	-- CanQuery = false on both parts matters more than it looks: the vehicle
	-- suspension is raycast-driven (see RayCastSuspension.client.luau), and a
	-- decorative column the wheels could feel would launch any truck that drove
	-- through the beam.
	local beam = Instance.new("Part")
	beam.Name = "Beam"
	-- A round column, via Part.Shape rather than a cylinder SpecialMesh. The
	-- shape's axis is X, so the height goes in Size.X and the PART is stood
	-- upright by _beamRotation below - which keeps the per-frame maths to one
	-- translation times one constant.
	beam.Shape = Enum.PartType.Cylinder
	beam.Size = Vector3.new(BEAM_HEIGHT, BEAM_WIDTH, BEAM_WIDTH)
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Locked = true
	beam.Material = Enum.Material.Neon
	beam.Color = self._color
	beam.Transparency = 1
	beam.Parent = folder
	self._beam = beam
	self._beamRotation = CFrame.Angles(0, 0, math.rad(90))

	-- The billboard hangs off its own tiny anchor rather than off the beam: a
	-- BillboardGui is positioned from its adornee's CENTRE, and the beam's
	-- centre is 150 studs in the air.
	local anchor = Instance.new("Part")
	anchor.Name = "BillboardAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Locked = true
	anchor.Transparency = 1
	anchor.Parent = folder
	self._anchor = anchor

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Billboard"
	-- Offset, not scale: a billboard sized in studs shrinks with distance,
	-- which makes it unreadable at exactly the range it is most needed. In
	-- pixels it is the same size on screen from anywhere.
	billboard.Size = UDim2.fromOffset(230, 96)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = math.huge
	billboard.Enabled = false
	billboard.Adornee = anchor
	billboard.Parent = anchor
	self._billboard = billboard

	local arrow = Instance.new("TextLabel")
	arrow.Name = "Arrow"
	arrow.Size = UDim2.new(1, 0, 0, 52)
	arrow.BackgroundTransparency = 1
	arrow.Font = Enum.Font.LuckiestGuy
	arrow.TextSize = 46
	arrow.TextColor3 = self._color
	arrow.Text = "\u{25BC}"
	arrow.Parent = billboard

	local arrowStroke = Instance.new("UIStroke")
	arrowStroke.Color = Color3.fromRGB(0, 0, 0)
	arrowStroke.Thickness = 3
	arrowStroke.Transparency = 0.25
	arrowStroke.Parent = arrow

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.Size = UDim2.new(1, 0, 0, 30)
	caption.Position = UDim2.fromOffset(0, 52)
	caption.BackgroundTransparency = 1
	caption.Font = Enum.Font.LuckiestGuy
	caption.TextSize = 24
	caption.TextColor3 = BRIGHT_TEXT
	caption.Text = ""
	caption.Parent = billboard
	self._caption = caption

	local captionStroke = Instance.new("UIStroke")
	captionStroke.Color = Color3.fromRGB(0, 0, 0)
	captionStroke.Thickness = 3
	captionStroke.Transparency = 0.15
	captionStroke.Parent = caption

	-- Lives in the folder for good and is aimed with Adornee, rather than being
	-- reparented onto whatever it is pointing at. Parenting a Highlight to its
	-- target is the more common idiom and it is a trap here: the ordinary case
	-- for this marker is pointing at the player's truck, and respawning a truck
	-- DESTROYS it - taking the Highlight with it and leaving every later write
	-- to a destroyed instance's Parent throwing "the Parent property is
	-- locked", every frame, for the rest of the session. Adornee simply goes
	-- inert instead.
	local highlight = Instance.new("Highlight")
	highlight.Name = "Highlight"
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = self._color
	highlight.OutlineColor = BRIGHT_TEXT
	highlight.FillTransparency = 0.7
	highlight.OutlineTransparency = 0
	highlight.Enabled = false
	highlight.Parent = folder
	self._highlight = highlight

	--=========================================================================
	-- The screen arrow
	--=========================================================================

	local screen = Instance.new("Frame")
	screen.Name = "ScreenArrow"
	screen.Size = UDim2.fromOffset(180, 78)
	screen.AnchorPoint = Vector2.new(0.5, 0.5)
	screen.BackgroundTransparency = 1
	screen.Visible = false
	-- Under everything clickable: the contract board and the tutorial banner
	-- both have to stay usable with this on screen.
	screen.ZIndex = 0
	screen.Parent = config.Parent
	self._screen = screen

	local screenArrow = Instance.new("TextLabel")
	screenArrow.Size = UDim2.fromOffset(44, 44)
	screenArrow.Position = UDim2.new(0.5, 0, 0, 0)
	screenArrow.AnchorPoint = Vector2.new(0.5, 0)
	screenArrow.BackgroundTransparency = 1
	screenArrow.Font = Enum.Font.LuckiestGuy
	screenArrow.TextSize = 40
	screenArrow.TextColor3 = self._color
	screenArrow.Text = "\u{25B2}"
	screenArrow.ZIndex = 0
	screenArrow.Parent = screen
	self._screenArrow = screenArrow

	local screenArrowStroke = Instance.new("UIStroke")
	screenArrowStroke.Color = Color3.fromRGB(0, 0, 0)
	screenArrowStroke.Thickness = 3
	screenArrowStroke.Transparency = 0.2
	screenArrowStroke.Parent = screenArrow

	local screenCaption = Instance.new("TextLabel")
	screenCaption.Position = UDim2.new(0.5, 0, 0, 44)
	screenCaption.Size = UDim2.new(1, 0, 0, 34)
	screenCaption.AnchorPoint = Vector2.new(0.5, 0)
	screenCaption.BackgroundTransparency = 1
	screenCaption.Font = Enum.Font.GothamBold
	screenCaption.TextSize = 14
	screenCaption.TextColor3 = BRIGHT_TEXT
	screenCaption.TextXAlignment = Enum.TextXAlignment.Center
	screenCaption.TextYAlignment = Enum.TextYAlignment.Top
	screenCaption.ZIndex = 0
	screenCaption.Text = ""
	screenCaption.Parent = screen
	self._screenCaption = screenCaption

	-- A stroke rather than a panel behind it: this sits over road and sky by
	-- turns, and a solid backing plate that size would be one more thing
	-- blocking the windscreen in first person. Same reasoning as DeliveryHud's
	-- waypoint caption.
	local screenCaptionStroke = Instance.new("UIStroke")
	screenCaptionStroke.Color = Color3.fromRGB(0, 0, 0)
	screenCaptionStroke.Thickness = 2
	screenCaptionStroke.Transparency = 0.3
	screenCaptionStroke.Parent = screenCaption

	self._connection = RunService.RenderStepped:Connect(function()
		self:_step()
	end)

	return self
end

--=============================================================================
-- Target
--=============================================================================

-- `instance` is a Model or a BasePart, or nil to go dark. Cheap and idempotent
-- - safe to call every poll with the same value, which is what lets a caller
-- recompute its target on a timer without tracking whether it changed.
--
-- options:
--   Label         text under the arrow. Defaults to the instance's name.
--   ScreenArrow   draw the screen-edge marker (default true). Turn it off when
--                 something else on screen already points at the same place -
--                 two arrows disagreeing by a few pixels is worse than one.
--   Beam          draw the column (default true). Worth turning off for a
--                 target the player is already standing next to.
--   NearDistance  studs at which the billboard takes over from the screen
--                 marker - see DEFAULT_NEAR_DISTANCE. Worth raising for an
--                 unusually large target (the billboard is legible from
--                 further away over something big) or lowering for a small
--                 one.
function GuideMarker:SetTarget(instance, options)
	if instance and not (instance:IsA("Model") or instance:IsA("BasePart")) then
		instance = nil
	end
	-- Checked even when the target is unchanged, so a destroyed target - a
	-- despawned truck, a rebuilt plot - can never leave a Highlight parented to
	-- an orphan.
	if instance and not instance:IsDescendantOf(workspace) then
		instance = nil
	end

	local changed = instance ~= self._target
	self._target = instance
	self._options = options or {}

	if not instance then
		self._highlight.Enabled = false
		self._highlight.Adornee = nil
		self._billboard.Enabled = false
		self._beam.Transparency = 1
		self._screen.Visible = false
		return
	end

	if changed then
		self._highlight.Adornee = instance
	end
	self._highlight.Enabled = true

	self._caption.Text = self._options.Label or instance.Name
	-- Not set here: _step decides every frame whether the billboard or the
	-- screen marker is the one actually on, based on distance.
end

function GuideMarker:ClearTarget()
	self:SetTarget(nil)
end

--=============================================================================
-- Per frame
--=============================================================================

function GuideMarker:_step()
	local target = self._target
	if not target then
		return
	end
	-- A target can be destroyed between polls - the player respawning the very
	-- truck being pointed at is the ordinary case. Everything goes dark rather
	-- than erroring every frame for the rest of the session; the owner's next
	-- SetTarget picks a live one.
	if not target:IsDescendantOf(workspace) then
		self:SetTarget(nil)
		return
	end

	local now = os.clock()
	local pulse = (math.sin(now * PULSE_SPEED) + 1) / 2 -- 0..1

	local centre, size = boundsOf(target)
	local top = centre + Vector3.new(0, size.Y / 2, 0)

	if self._options.Beam ~= false then
		self._beam.CFrame = CFrame.new(top + Vector3.new(0, BEAM_HEIGHT / 2, 0)) * self._beamRotation
		self._beam.Transparency = BEAM_TRANSPARENCY + 0.2 * pulse
	else
		self._beam.Transparency = 1
	end

	self._highlight.FillTransparency = 0.62 + 0.22 * pulse

	local camera = workspace.CurrentCamera
	local nearDistance = self._options.NearDistance or DEFAULT_NEAR_DISTANCE
	local near = camera and (centre - camera.CFrame.Position).Magnitude <= nearDistance

	-- Exactly one of the billboard and the screen marker is ever on - see
	-- DEFAULT_NEAR_DISTANCE above for why. Near, the billboard bounces right
	-- over the target; far, only the screen marker is doing anything useful,
	-- so the billboard goes dark instead of hanging a second, pointless copy
	-- of the same label over a target too small on screen to read anyway.
	if near then
		-- The billboard bounces. Motion is what a busy eye actually catches -
		-- a static marker of any size gets read once and then tuned out,
		-- which is the same reasoning behind the depot sign's pulsing
		-- chevrons.
		local bounce = math.sin(now * BOUNCE_SPEED) * BOUNCE_STUDS
		self._anchor.CFrame = CFrame.new(top + Vector3.new(0, BILLBOARD_LIFT + BOUNCE_STUDS + bounce, 0))
		self._billboard.Enabled = true
	else
		self._billboard.Enabled = false
	end

	if near or self._options.ScreenArrow == false or not camera then
		self._screen.Visible = false
		return
	end

	local point, onScreen = camera:WorldToViewportPoint(centre)
	local viewport = camera.ViewportSize

	-- Behind the camera comes back with a negative Z and coordinates mirrored
	-- through the centre. Flipping them back is what stops the arrow pointing
	-- left when the target is behind and to the right.
	local behind = point.Z <= 0
	local x = if behind then viewport.X - point.X else point.X
	local y = if behind then viewport.Y - point.Y else point.Y

	local clampedX = math.clamp(x, SCREEN_MARGIN, viewport.X - SCREEN_MARGIN)
	local clampedY = math.clamp(y, SCREEN_MARGIN_TOP, viewport.Y - SCREEN_MARGIN)
	local atEdge = behind or not onScreen or clampedX ~= x or clampedY ~= y

	self._screen.Position = UDim2.fromOffset(clampedX, clampedY)

	if atEdge then
		-- Point from the middle of the screen toward where the target actually
		-- is. The glyph is drawn pointing up, hence the +90.
		local dx, dy = x - viewport.X / 2, y - viewport.Y / 2
		self._screenArrow.Rotation = math.deg(math.atan2(dy, dx)) + 90
		self._screenArrow.Text = "\u{25B2}"
	else
		self._screenArrow.Rotation = 0
		self._screenArrow.Text = "\u{25C6}" -- a pin sitting on the spot, not a direction
	end

	self._screenCaption.Text = string.format(
		"%s\n%.0f studs",
		self._options.Label or target.Name,
		(centre - camera.CFrame.Position).Magnitude
	)
	self._screen.Visible = true
end

function GuideMarker:Destroy()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	-- The Highlight goes with the folder - it has never been parented anywhere
	-- else, which is the whole point of aiming it with Adornee.
	self._folder:Destroy()
	self._screen:Destroy()
end

return GuideMarker

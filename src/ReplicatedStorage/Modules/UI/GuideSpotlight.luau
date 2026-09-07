-- "Click THIS one." Dims a panel down to a single control, rings it, and puts
-- a white cursor on it that fades in and taps, with a ripple on the press.
--
-- The problem it solves is choice paralysis. The job board is a wall of
-- near-identical cards with numbers on them; the plot terminal is tabs, a
-- carousel and a column of upgrade sliders. A banner saying "click a job"
-- does not help when the honest reaction is "which one". Taking every choice
-- but one off the table for a few seconds is the whole intervention.
--
-- THIS USED TO POSITION EVERYTHING BY CONVERTING THE TARGET'S
-- AbsolutePosition/AbsoluteSize INTO SCREEN PIXELS, drawn in a separate
-- top-level ScreenGui of its own. That is cross-hierarchy math, and in
-- practice it never quite agreed with where the real control was - several
-- rewrites of the arithmetic never fixed it, because the arithmetic was never
-- the part that could be wrong in a way this module could see.
--
-- THE FIRST REPLACEMENT mirrored the target's own Position/AnchorPoint/Size
-- UDim2 properties onto a sibling frame, on the theory that copying the exact
-- values Roblox used to place the target must place a sibling identically.
-- That is true for a target positioned by hand - it is NOT true for a target
-- arranged by a UIListLayout, which is exactly what the job board's cards
-- are: a UIListLayout computes where a child renders WITHOUT ever writing
-- that back to the child's own Position property, which sits at whatever it
-- was before parenting (typically (0,0,0,0)) forever after. Mirroring that
-- property mirrored the wrong number - the cursor rendered at the top of the
-- list instead of on the first card.
--
-- SO THIS READS THE RESOLVED RECTANGLE INSTEAD: target.AbsolutePosition and
-- target.AbsoluteSize, which Roblox keeps correct for ANY layout mechanism,
-- manual or automatic. The cross-ScreenGui risk that AbsolutePosition carried
-- the first time around is avoided by never leaving the target's own GUI
-- tree: both the dimming and the cursor are parented into PANEL - the same
-- stable container for both, never the target itself - and every position is
-- written as target.AbsolutePosition MINUS panel's own AbsolutePosition, a
-- difference of two values read from the same screen, so whatever inset or
-- scale applies to one applies identically to the other and cancels out of
-- the subtraction. There is still no manual reasoning about GuiInset,
-- DisplayOrder or a viewport size anywhere in this file.
--
-- Parented to PANEL rather than to the target itself, on purpose - see
-- GuideMarker's header for why parenting effects onto the thing they are
-- pointing at is a trap: the job board destroys and rebuilds its cards, and a
-- child of a destroyed card is destroyed with it. Parented to panel rather
-- than to the target's own immediate parent, also on purpose: with Roblox's
-- default sibling-scoped ZIndex, two different branches of the tree are
-- layered branch-by-branch going down from their common ancestor, not by
-- ZIndex globally - so the cursor and the dim group need to be true siblings
-- under the same parent for "the cursor's ZIndex is higher" to actually mean
-- anything. Every panel this is used on (the terminal, the contract board) is
-- a stable container built once and never destroyed, so it is a safe place
-- for both to live.
--
-- ONE MORE THING THE SUBTRACTION DOES NOT SAVE YOU FROM: what you do with the
-- answer. PlotTerminal's whole panel gets a UIScale (see ResponsiveScale) so
-- it fits a phone screen, and a UIScale multiplies every OFFSET pixel value
-- of every descendant of the thing it is scaling - which includes whatever
-- this module draws, since it lives inside that same panel. The
-- target-relative rectangle computed above is already a POST-scale pixel
-- value (AbsolutePosition always is), so writing it back as an Offset would
-- run it through that same UIScale a SECOND time - shrinking it again on top
-- of the first shrink, which is exactly why the dimming and the cursor used
-- to visibly crawl toward the panel's top-left corner as the screen got
-- shorter and the panel's own auto-fit scale dropped further below 1. Scale
-- is the fix: a UDim2 Scale component is never touched by a UIScale, only
-- its Offset component is, so every position and size below is written as a
-- FRACTION of the panel's own current size rather than as a pixel count.
--
-- Client-only (it parents Frames inside whatever GUI the target and panel
-- live in). Generic on purpose: it names nothing about tutorials, jobs or
-- terminals.

local RunService = game:GetService("RunService")

local GuideSpotlight = {}
GuideSpotlight.__index = GuideSpotlight

local SCRIM_COLOR = Color3.fromRGB(6, 8, 12)
local SCRIM_TRANSPARENCY = 0.45

-- The ring around the target, and how far outside it sits.
local BORDER_PAD = 5
local BORDER_THICKNESS = 3
local BORDER_PULSE_SPEED = 4.2

-- One full fade-and-tap. Long enough not to read as a twitch, short enough
-- that a player glancing up catches a whole one.
local CURSOR_CYCLE = 1.9
-- Fractions of that cycle: fade in, press, hold, then fade out and reset.
local REACH_UNTIL = 0.45
local PRESS_UNTIL = 0.58
local HOLD_UNTIL = 0.84

-- Big enough to actually read as a cursor rather than a fleck - it used to be
-- 30px and got lost against a 520px-wide board.
local CURSOR_SIZE = 46
local CURSOR_PRESS_DIP = 5

local RIPPLE_MAX = 80

-- Roblox ships this texture with every client, so there is no asset to
-- upload and nothing to break in a fresh place file. Plain white rather than
-- the step's own accent colour - Spawn Vehicle and most of this UI's primary
-- buttons are filled with that exact accent colour, and a same-coloured
-- cursor all but disappears against the thing it is pointing at.
local CURSOR_IMAGE = "rbxasset://textures/Cursors/KeyboardMouse/ArrowCursor.png"
local CURSOR_COLOR = Color3.new(1, 1, 1)

-- Sits above the panel's own children without touching any of their ZIndex.
-- The cursor/ripple sit a tier above the dimming, so the tap is never itself
-- dimmed out.
local DIM_ZINDEX = 500
local EFFECT_ZINDEX = 1000

--=============================================================================
-- Helpers
--=============================================================================

-- Is this GuiObject actually being drawn right now?
--
-- Neither `Visible` nor `AbsoluteSize` answers this alone: a control inside a
-- hidden parent is still Visible itself, and a disabled ScreenGui leaves its
-- descendants' absolute geometry sitting at whatever it last computed. So the
-- whole chain gets walked, and reaching a ScreenGui is required - a target that
-- has been destroyed and reparented to nil has no ScreenGui above it and must
-- read as gone rather than as merely invisible.
local function isOnScreen(guiObject)
	if not guiObject or not guiObject:IsDescendantOf(game) then
		return false
	end
	if guiObject.AbsoluteSize.X <= 0 or guiObject.AbsoluteSize.Y <= 0 then
		return false
	end

	local node = guiObject
	while node do
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		if node:IsA("LayerCollector") then
			return node.Enabled
		end
		node = node.Parent
	end
	return false
end

local function easeOutCubic(t)
	local inverse = 1 - t
	return 1 - inverse * inverse * inverse
end

-- `child`'s on-screen rectangle, expressed as pixel offsets from `parent`'s
-- own on-screen top-left - not from `child`'s own Position property, which a
-- UIListLayout or UIGridLayout never updates. Both AbsolutePosition reads are
-- taken from the same screen, so this is safe from any inset/DisplayOrder
-- difference regardless of what ScreenGui either one actually lives in.
local function relativeRect(child, parent)
	local childPos, childSize = child.AbsolutePosition, child.AbsoluteSize
	local parentPos = parent.AbsolutePosition
	return childPos.X - parentPos.X, childPos.Y - parentPos.Y, childSize.X, childSize.Y
end

--=============================================================================
-- Construction
--=============================================================================

-- config:
--   Color  Color3 for the ring and the ripple (required)
--   Name   for anyone reading the explorer
function GuideSpotlight.new(config)
	local self = setmetatable({}, GuideSpotlight)

	self._panel = nil
	self._target = nil

	--=========================================================================
	-- The dimming: four scrim bands plus a border ring, parented inside
	-- whatever panel SetTarget is given, sized off that panel's own resolved
	-- rectangle every frame.
	--=========================================================================

	local dimGroup = Instance.new("Frame")
	dimGroup.Name = (config.Name or "GuideSpotlight") .. "Dim"
	dimGroup.BackgroundTransparency = 1
	dimGroup.Size = UDim2.fromScale(1, 1)
	dimGroup.Visible = false
	dimGroup.ZIndex = DIM_ZINDEX
	self._dimGroup = dimGroup

	-- Four of them: above the target, below it, and one to each side of it.
	-- TextButtons rather than Frames because a Frame does not absorb a click -
	-- and absorbing the click is half of what this is for: a player who
	-- cannot click the wrong card cannot get lost.
	self._scrims = {}
	for index = 1, 4 do
		local scrim = Instance.new("TextButton")
		scrim.Name = "Scrim" .. index
		scrim.Text = ""
		scrim.AutoButtonColor = false
		scrim.BackgroundColor3 = SCRIM_COLOR
		scrim.BackgroundTransparency = SCRIM_TRANSPARENCY
		scrim.BorderSizePixel = 0
		scrim.Size = UDim2.fromOffset(0, 0)
		scrim.ZIndex = DIM_ZINDEX
		scrim.Parent = dimGroup
		table.insert(self._scrims, scrim)
	end

	local border = Instance.new("Frame")
	border.Name = "Border"
	border.BackgroundTransparency = 1
	border.Visible = false
	border.ZIndex = DIM_ZINDEX
	border.Parent = dimGroup
	self._border = border

	Instance.new("UICorner", border).CornerRadius = UDim.new(0, 10)

	local borderStroke = Instance.new("UIStroke")
	borderStroke.Color = config.Color
	borderStroke.Thickness = BORDER_THICKNESS
	borderStroke.Parent = border
	self._borderStroke = borderStroke

	--=========================================================================
	-- The cursor: an anchor frame parented beside the target, sized off the
	-- target's own resolved rectangle every frame, with the ripple and the
	-- cursor image centred on it.
	--=========================================================================

	local anchor = Instance.new("Frame")
	anchor.Name = (config.Name or "GuideSpotlight") .. "Anchor"
	anchor.BackgroundTransparency = 1
	anchor.Visible = false
	anchor.ZIndex = EFFECT_ZINDEX
	self._anchor = anchor

	-- The tap ripple, under the cursor. Drawn as a stroke on a transparent
	-- frame rather than a filled circle, so it reads as a ring spreading out
	-- from the press rather than as a blob briefly covering the button.
	local ripple = Instance.new("Frame")
	ripple.Name = "Ripple"
	ripple.AnchorPoint = Vector2.new(0.5, 0.5)
	ripple.Position = UDim2.fromScale(0.5, 0.5)
	ripple.BackgroundTransparency = 1
	ripple.Visible = false
	ripple.ZIndex = EFFECT_ZINDEX
	ripple.Parent = anchor
	self._ripple = ripple

	local rippleCorner = Instance.new("UICorner")
	rippleCorner.CornerRadius = UDim.new(1, 0)
	rippleCorner.Parent = ripple

	local rippleStroke = Instance.new("UIStroke")
	rippleStroke.Color = config.Color
	rippleStroke.Thickness = 3
	rippleStroke.Parent = ripple
	self._rippleStroke = rippleStroke

	local cursor = Instance.new("ImageLabel")
	cursor.Name = "Cursor"
	cursor.AnchorPoint = Vector2.new(0.5, 0.5)
	cursor.Position = UDim2.fromScale(0.5, 0.5)
	cursor.BackgroundTransparency = 1
	cursor.Image = CURSOR_IMAGE
	cursor.ImageColor3 = CURSOR_COLOR
	cursor.Size = UDim2.fromOffset(CURSOR_SIZE, CURSOR_SIZE)
	cursor.Visible = false
	cursor.ZIndex = EFFECT_ZINDEX + 1
	cursor.Parent = anchor
	self._cursor = cursor

	self._connection = RunService.RenderStepped:Connect(function()
		self:_step()
	end)

	return self
end

--=============================================================================
-- Target
--=============================================================================

-- `panel` is the container to dim, `target` the one control inside it to
-- leave lit. Either being nil clears the whole overlay.
--
-- Cheap and idempotent, like GuideMarker's SetTarget and for the same reason:
-- the caller re-resolves both of these on a slow poll and should not have to
-- track whether they changed. Both are re-checked every frame anyway, since
-- the job board destroys and rebuilds its cards whenever the pool changes.
function GuideSpotlight:SetTarget(panel, target)
	self._panel = panel
	self._target = target
end

function GuideSpotlight:Clear()
	self:SetTarget(nil, nil)
end

--=============================================================================
-- Per frame
--=============================================================================

function GuideSpotlight:_hide()
	self._dimGroup.Visible = false
	self._anchor.Visible = false
end

function GuideSpotlight:_step()
	local panel, target = self._panel, self._target
	-- Both are checked every frame rather than trusted from SetTarget: the job
	-- board destroys and rebuilds its cards whenever the pool changes, so the
	-- target this is tracking can stop existing between one poll and the next.
	if not isOnScreen(panel) or not isOnScreen(target) then
		self:_hide()
		return
	end

	-- Both the dimming and the cursor are parented into PANEL, not into the
	-- target's own immediate parent - deliberately the same parent for both.
	-- With Roblox's default sibling-scoped ZIndex, ordering between two
	-- DIFFERENT branches of the tree is decided branch-by-branch going down
	-- from their common ancestor, not by ZIndex globally: a cursor buried a
	-- few levels inside the panel's content would still render under the dim
	-- group if the BRANCH it sits in lost that comparison higher up, no
	-- matter how high the cursor's own ZIndex was set. Making both of them
	-- true siblings under the same panel is what makes "the cursor's ZIndex is
	-- higher than the dim group's" an actual, reliable comparison. This is
	-- safe here because every panel this is used on (the terminal, the
	-- contract board) is a stable container that is built once and never
	-- destroyed - only things deeper inside it, like individual job cards,
	-- come and go.
	if self._dimGroup.Parent ~= panel then
		self._dimGroup.Parent = panel
	end
	if self._anchor.Parent ~= panel then
		self._anchor.Parent = panel
	end

	local panelSize = panel.AbsoluteSize
	if panelSize.X <= 0 or panelSize.Y <= 0 then
		self:_hide()
		return
	end

	local x, y, width, height = relativeRect(target, panel)

	self:_stepDim(panelSize, x, y, width, height)

	-- SCALE, not Offset - see the header on double-scaling for why. x/y/width/
	-- height here are already-resolved SCREEN pixels (post any UIScale on the
	-- panel), and the anchor lives INSIDE that same panel - assigning them
	-- back as Offset would run them through that UIScale a second time,
	-- shrinking (or growing) everything again on top of the first shrink.
	-- Scale is never touched by UIScale, only Offset is, so converting to a
	-- fraction of the panel's own current size is what makes this correct at
	-- any scale rather than only at 1.0.
	self._anchor.Position = UDim2.fromScale(x / panelSize.X, y / panelSize.Y)
	self._anchor.Size = UDim2.fromScale(width / panelSize.X, height / panelSize.Y)
	self._anchor.Visible = true

	self:_stepCursor(os.clock())
end

-- The panel's rectangle minus the target's, as four bands - all computed from
-- the RESOLVED rectangle (see the header for why not target.Position), and
-- all in SCALE rather than Offset (see _step's comment on double-scaling).
function GuideSpotlight:_stepDim(panelSize, holeX, holeY, holeW, holeH)
	self._dimGroup.Visible = true

	local holeRight, holeBottom = holeX + holeW, holeY + holeH

	local function scaleOf(px, axisSize)
		return px / axisSize
	end

	-- Every size is clamped at zero so a target hanging over the panel's edge
	-- - a card scrolled half out of its list, most likely - collapses the
	-- band it overhangs instead of drawing a negatively-sized one.
	local function place(scrim, px, py, width, height)
		scrim.Position = UDim2.fromScale(scaleOf(px, panelSize.X), scaleOf(py, panelSize.Y))
		scrim.Size = UDim2.fromScale(scaleOf(math.max(width, 0), panelSize.X), scaleOf(math.max(height, 0), panelSize.Y))
	end

	place(self._scrims[1], 0, 0, panelSize.X, holeY)
	place(self._scrims[2], 0, holeBottom, panelSize.X, panelSize.Y - holeBottom)
	place(self._scrims[3], 0, holeY, holeX, holeH)
	place(self._scrims[4], holeRight, holeY, panelSize.X - holeRight, holeH)

	self._border.Position =
		UDim2.fromScale(scaleOf(holeX - BORDER_PAD, panelSize.X), scaleOf(holeY - BORDER_PAD, panelSize.Y))
	self._border.Size = UDim2.fromScale(
		scaleOf(holeW + BORDER_PAD * 2, panelSize.X),
		scaleOf(holeH + BORDER_PAD * 2, panelSize.Y)
	)
	self._border.Visible = true

	-- The ring breathes on the same clock GuideMarker's beam and outline use,
	-- so the two halves of the tutorial pulse as one system.
	local pulse = (math.sin(os.clock() * BORDER_PULSE_SPEED) + 1) / 2
	self._borderStroke.Transparency = 0.15 + 0.35 * pulse
end

-- Fade in, tap, hold, fade out, repeat - driven entirely off the clock rather
-- than off tweens, so there is no animation state to leave running when the
-- target changes mid-cycle or the panel closes underneath it. Pinned to the
-- anchor's own centre the whole time (only the tiny press dip moves it at
-- all), because the anchor already IS the target's rectangle.
function GuideSpotlight:_stepCursor(now)
	local phase = (now % CURSOR_CYCLE) / CURSOR_CYCLE

	local transparency = 0
	local dip = 0

	if phase < REACH_UNTIL then
		transparency = 1 - math.min(easeOutCubic(phase / REACH_UNTIL) * 3, 1) -- fades in over the first third
	elseif phase < PRESS_UNTIL then
		dip = CURSOR_PRESS_DIP
	elseif phase < HOLD_UNTIL then
		dip = 0
	else
		transparency = (phase - HOLD_UNTIL) / (1 - HOLD_UNTIL)
	end

	self._cursor.Position = UDim2.new(0.5, dip, 0.5, dip)
	self._cursor.ImageTransparency = transparency
	self._cursor.Visible = true

	-- The ripple lives only across the press, expanding and fading as it goes.
	if phase >= REACH_UNTIL and phase < HOLD_UNTIL then
		local spread = (phase - REACH_UNTIL) / (HOLD_UNTIL - REACH_UNTIL)
		local diameter = RIPPLE_MAX * easeOutCubic(spread)
		self._ripple.Size = UDim2.fromOffset(diameter, diameter)
		self._rippleStroke.Transparency = spread
		self._ripple.Visible = true
	else
		self._ripple.Visible = false
	end
end

function GuideSpotlight:Destroy()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	self._dimGroup:Destroy()
	self._anchor:Destroy()
end

return GuideSpotlight

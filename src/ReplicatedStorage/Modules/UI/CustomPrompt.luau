-- A lightweight, ProximityPrompt-like interaction prompt built from a plain
-- BillboardGui instead of the real ProximityPrompt. Built for first-person:
-- ProximityPrompt's own on-screen highlight has a quirk where the mouse
-- cursor gets trapped/re-centered on it, which is exactly the wrong thing to
-- happen every time the camera swings past one.
--
-- Deliberately generic - not vehicle-specific - so any "walk up, press a key"
-- interaction can reuse it. See VehicleDoorPrompts.client.luau for a plain
-- press-to-trigger user, and PlotTerminal.client.luau for a press-and-hold
-- one. API mirrors ProximityPrompt's own shape on purpose (Triggered,
-- Enabled, MaxActivationDistance) so it's a familiar drop-in.
--
-- Instant vs. hold-to-trigger is one config field: `HoldDuration` (seconds).
-- Omit it (or pass 0) for the original instant-on-press behaviour; pass a
-- number and the key has to be held down that long, with a progress bar
-- filling in along the bottom of the prompt, before Triggered fires. Letting
-- go early cancels it with no penalty - it just resets to empty and can be
-- started again.
--
-- Client-only (reads Players.LocalPlayer and the local character) - do not
-- require this from a server script.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

-- Matches the dark-panel look already established by VehicleDashboard.luau,
-- so this reads as the same UI system rather than a one-off.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local KEY_BADGE = Color3.fromRGB(28, 31, 38)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)

local FADE_TIME = 0.15
local VISIBLE_TRANSPARENCY = 0.08

local CustomPrompt = {}
CustomPrompt.__index = CustomPrompt

-- Every live prompt, driven by one shared Heartbeat loop rather than one
-- connection per instance - cheap even with a dozen of these on screen.
local activePrompts = {}
local nextId = 0

-- Mobile activation. First attempt was a transparent GuiButton laid directly
-- over the billboard's own CanvasGroup - it never worked, because a
-- BillboardGui rendered in 3D world space does not reliably deliver touch
-- input to a GuiButton inside it (mouse clicks worked in Studio, which is
-- exactly what made it look fine until it was tested on an actual touch
-- device). ContextActionService's own createTouchButton was tried next and
-- also did not visibly appear in testing. What's known to work is a plain
-- TextButton in a ScreenGui - the same approach VehicleTouchControls.luau
-- already uses successfully - so that's what this is: one shared ScreenGui,
-- with one real screen-space button created per prompt while it's visible,
-- mirroring the KeyCode bind/unbind lifecycle in _setBound below.
local function isTouchInput(inputType)
	return inputType == Enum.UserInputType.Touch
end

-- Whether the world-space billboard itself should ever be drawn. On touch it
-- is pure redundancy on top of being a bug: the touch button above already
-- gives a touch player everything the billboard would (what this is, whether
-- it's in range), the key badge it shows ("F", "H"...) means nothing without
-- a keyboard, and BillboardGui.AlwaysOnTop draws in front of every ScreenGui
-- regardless of ZIndex - so it was rendering directly over the dedicated
-- mobile button meant to be pressed instead. Tracked live, same reasoning as
-- everywhere else in this file: a hybrid touchscreen device can switch modes
-- mid-session, and a prompt already on screen when it does should react
-- immediately rather than waiting for its next distance check.
local touchActive = isTouchInput(UserInputService:GetLastInputType())

local function refreshGuiForTouchChange()
	for prompt in activePrompts do
		if prompt.Gui and prompt.Visible then
			prompt.Gui.Enabled = not touchActive
		end
	end
end

UserInputService.LastInputTypeChanged:Connect(function(inputType)
	touchActive = isTouchInput(inputType)
	refreshGuiForTouchChange()
end)

local touchGui = nil
local touchButtonList = nil

local function ensureTouchGui()
	if touchGui then
		return touchButtonList
	end

	touchGui = Instance.new("ScreenGui")
	touchGui.Name = "CustomPromptTouchButtons"
	touchGui.ResetOnSpawn = false
	touchGui.IgnoreGuiInset = true
	touchGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	-- Only shown while the player is actively using touch, live - not decided
	-- once. A keyboard/mouse player standing right next to the same prompt
	-- never needs this; the billboard and its key badge are already theirs.
	touchGui.Enabled = isTouchInput(UserInputService:GetLastInputType())
	touchGui.Parent = player:WaitForChild("PlayerGui")

	touchButtonList = Instance.new("Frame")
	touchButtonList.Name = "List"
	touchButtonList.BackgroundTransparency = 1
	touchButtonList.AnchorPoint = Vector2.new(0.5, 1)
	touchButtonList.Position = UDim2.new(0.5, 0, 1, -150)
	touchButtonList.Size = UDim2.fromOffset(260, 300)
	touchButtonList.Parent = touchGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 10)
	layout.Parent = touchButtonList

	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		touchGui.Enabled = isTouchInput(inputType)
	end)

	return touchButtonList
end

-- Minimal custom signal - Triggered is client-only, so it doesn't need
-- BindableEvent's cross-script replication, just :Connect()/:Fire().
local function newSignal()
	local connections = {}
	-- A monotonic counter, not #connections: disconnecting leaves holes, and
	-- the length operator on a table with holes is undefined - it can hand
	-- back an id that is already in use, silently overwriting a live
	-- connection with a new one.
	local nextConnectionId = 0
	local signal = {}
	function signal:Connect(fn)
		nextConnectionId += 1
		local id = nextConnectionId
		connections[id] = fn
		return {
			Disconnect = function()
				connections[id] = nil
			end,
		}
	end
	function signal:Fire(...)
		for _, fn in connections do
			fn(...)
		end
	end
	return signal
end

-- Where a prompt measures distance from. Accepts a BasePart or an Attachment,
-- so a caller can point at hinge attachments (door openings) as readily as at
-- parts.
local function referencePosition(instance)
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	return instance.Position
end

-- `part` is what the prompt is anchored to - where the billboard floats.
-- `config`:
--   Text                  (string) the label
--   KeyText               (string) defaults to the KeyCode's name
--   KeyCode               (Enum.KeyCode) default F
--   MaxActivationDistance (studs) default 8
--   DistanceFrom          (array of BasePart/Attachment) what distance is
--                         measured to, nearest one wins. Defaults to `part`.
--                         A prompt that floats over a car's centre but should
--                         only appear near a DOOR is exactly why this exists.
--   HoldDuration          (seconds) default 0 (instant on press). > 0 means
--                         the key must be held this long - see the header.
--   ShouldShow            (function() -> boolean) re-asked EVERY frame while
--                         in range. Anything that can change without warning -
--                         occupancy, ownership, whether the local player is
--                         already sitting somewhere - belongs here rather than
--                         in an event handler calling SetEnabled. A predicate
--                         cannot be missed; a missed event leaves a prompt
--                         stuck on screen with no way to recover.
function CustomPrompt.new(part, config)
	config = config or {}
	local self = setmetatable({}, CustomPrompt)

	self.Part = part
	self.KeyCode = config.KeyCode or Enum.KeyCode.F
	self.MaxActivationDistance = config.MaxActivationDistance or 8
	self.DistanceFrom = config.DistanceFrom or { part }
	self.HoldDuration = config.HoldDuration or 0
	self.ShouldShow = config.ShouldShow
	self.Enabled = true
	self.Visible = false
	self.Triggered = newSignal()

	nextId += 1
	self._actionName = "CustomPrompt" .. nextId
	self._bound = false
	self._holding = false
	self._holdElapsed = 0
	self._holdThread = nil
	-- Doubles as the touch button's title (see _setBound) - what the mobile
	-- on-screen button is labelled with, so it reads the same as the panel.
	self._promptText = config.Text or "Interact"

	self:_buildGui(self._promptText, config.KeyText or self.KeyCode.Name)

	activePrompts[self] = true
	return self
end

-- The key is bound only while the prompt is actually on screen, rather than
-- for the prompt's whole lifetime. Two real bugs otherwise:
-- ContextActionService is a stack, so with a prompt per car only the most
-- recently created one ever received the key - including while it was hidden
-- and a different car was the one being looked at. And because the handler
-- returns Sink (so the key does not also reach whatever is behind it), a
-- hidden prompt was still swallowing F outright, which is enough to eat the
-- "press F to get out" binding the driving script puts up.
function CustomPrompt:_setBound(bound)
	if self._bound == bound then
		return
	end
	self._bound = bound
	if bound then
		ContextActionService:BindAction(self._actionName, function(_, inputState)
			if self.HoldDuration > 0 then
				if inputState == Enum.UserInputState.Begin then
					self:_startHold(true)
				elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
					self:_cancelHold()
				end
			elseif inputState == Enum.UserInputState.Begin then
				self.Triggered:Fire(player)
			end
			return Enum.ContextActionResult.Sink
		end, false, self.KeyCode)
		self:_showTouchButton()
	else
		ContextActionService:UnbindAction(self._actionName)
		self:_hideTouchButton()
		-- The prompt can go out of range, get disabled, or lose ShouldShow
		-- mid-hold (see the winner-by-key pass in the Heartbeat loop below) -
		-- none of those are an End/Cancel input, so the hold has to be
		-- cancelled here too or it would sit at whatever progress it had
		-- reached, unreachable, forever.
		self:_cancelHold()
	end
end

-- Screen-space equivalent of the billboard, built fresh each time the prompt
-- becomes bound (see _setBound) and thrown away when it isn't - same
-- lifetime as the key bind, so there's never a stray button left over for a
-- prompt the player has walked away from. Hidden (via the shared ScreenGui's
-- Enabled) unless the player is actually using touch right now.
function CustomPrompt:_showTouchButton()
	local list = ensureTouchGui()

	local button = Instance.new("TextButton")
	button.Name = "TouchPrompt"
	button.Size = UDim2.fromOffset(240, 56)
	button.BackgroundColor3 = PANEL
	button.BackgroundTransparency = 0.05
	button.AutoButtonColor = false
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.TextWrapped = true
	button.TextColor3 = BRIGHT_TEXT
	button.Text = self._promptText
	button.Parent = list

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = button

	local edge = Instance.new("UIStroke")
	edge.Color = ACCENT
	edge.Thickness = 1.5
	edge.Parent = button

	if self.HoldDuration > 0 then
		local track = Instance.new("Frame")
		track.Name = "ProgressTrack"
		track.Size = UDim2.new(1, 0, 0, 5)
		track.Position = UDim2.new(0, 0, 1, -5)
		track.BackgroundColor3 = KEY_BADGE
		track.BorderSizePixel = 0
		track.ZIndex = 2
		track.Parent = button

		local fill = Instance.new("Frame")
		fill.Name = "ProgressFill"
		fill.Size = UDim2.fromScale(0, 1)
		fill.BackgroundColor3 = ACCENT
		fill.BorderSizePixel = 0
		fill.ZIndex = 3
		fill.Parent = track

		self._touchProgressFill = fill

		-- MouseButton1Down/Up fire for touch too (GuiButton unifies the
		-- two) - MouseLeave is the safety net for a finger sliding off the
		-- button without a clean release.
		button.MouseButton1Down:Connect(function()
			self:_startHold(false)
		end)
		button.MouseButton1Up:Connect(function()
			self:_cancelHold()
		end)
		button.MouseLeave:Connect(function()
			self:_cancelHold()
		end)
	else
		button.Activated:Connect(function()
			self.Triggered:Fire(player)
		end)
	end

	self._touchButton = button
end

function CustomPrompt:_hideTouchButton()
	if self._touchButton then
		self._touchButton:Destroy()
		self._touchButton = nil
	end
	self._touchProgressFill = nil
end

-- Fraction is 0..1. No-ops for whichever bar doesn't currently exist -
-- ProgressFill only exists when the GUI was built expecting a hold, and
-- _touchProgressFill only while a touch button is actually up.
function CustomPrompt:_setHoldProgress(fraction)
	if self.ProgressFill then
		self.ProgressFill.Size = UDim2.fromScale(fraction, 1)
	end
	if self._touchProgressFill then
		self._touchProgressFill.Size = UDim2.fromScale(fraction, 1)
	end
end

-- `viaKey`: whether this hold should be safety-netted against the physical
-- key still being down (see below). The touch button (_showTouchButton)
-- starts a hold the exact same way a keyboard press does, but there is no
-- KeyCode to poll for a touch hold, so it opts out of that check with
-- `viaKey = false`.
function CustomPrompt:_startHold(viaKey)
	if self._holding or self.HoldDuration <= 0 then
		return
	end
	self._holding = true
	self._holdViaKey = viaKey ~= false
	self._holdElapsed = 0
	self:_setHoldProgress(0)

	self._holdThread = task.spawn(function()
		while self._holding do
			local delta = RunService.Heartbeat:Wait()
			-- Safety net for input states BindAction doesn't reliably deliver
			-- (e.g. the window losing focus mid-hold, an End that never
			-- arrives) - if the key genuinely isn't down any more, treat it
			-- the same as a normal release rather than leaving the hold stuck.
			-- Only meaningful for a keyboard-driven hold; a touch hold is
			-- released by its own button's Up/Leave events instead.
			if not self._holding or (self._holdViaKey and not UserInputService:IsKeyDown(self.KeyCode)) then
				self:_cancelHold()
				return
			end

			self._holdElapsed += delta
			local fraction = math.clamp(self._holdElapsed / self.HoldDuration, 0, 1)
			self:_setHoldProgress(fraction)

			if fraction >= 1 then
				self._holding = false
				self:_setHoldProgress(0)
				self.Triggered:Fire(player)
				return
			end
		end
	end)
end

function CustomPrompt:_cancelHold()
	if not self._holding then
		return
	end
	self._holding = false
	self:_setHoldProgress(0)
end

function CustomPrompt:_buildGui(text, keyText)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CustomPrompt"
	billboard.Size = UDim2.fromOffset(160, 46)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	-- Deliberately NOT BillboardGui.MaxDistance. That property measures from
	-- the CAMERA, not from the character, so it culls by where the player is
	-- looking from rather than where they are standing: in third person the
	-- camera sits well behind the character, so a prompt the player was
	-- standing right next to vanished, and from inside the cab in first person
	-- the camera is practically on top of the seat, so it stayed visible. The
	-- visibility rule here is entirely character-relative (see the Heartbeat
	-- loop) and `Enabled` below is what actually stops it being drawn.
	billboard.Enabled = false
	billboard.Parent = self.Part

	-- CanvasGroup so every child (badge, both labels, the stroke) fades
	-- together through one property instead of juggling several.
	local canvas = Instance.new("CanvasGroup")
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundColor3 = PANEL
	canvas.BorderSizePixel = 0
	canvas.GroupTransparency = 1 -- starts hidden
	canvas.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = canvas

	local edge = Instance.new("UIStroke")
	edge.Color = PANEL_EDGE
	edge.Parent = canvas

	local keyBadge = Instance.new("Frame")
	keyBadge.Size = UDim2.fromOffset(30, 30)
	keyBadge.Position = UDim2.fromOffset(8, 8)
	keyBadge.BackgroundColor3 = KEY_BADGE
	keyBadge.BorderSizePixel = 0
	keyBadge.Parent = canvas

	local keyCorner = Instance.new("UICorner")
	keyCorner.CornerRadius = UDim.new(0, 7)
	keyCorner.Parent = keyBadge

	local keyEdge = Instance.new("UIStroke")
	keyEdge.Color = ACCENT
	keyEdge.Thickness = 1.5
	keyEdge.Parent = keyBadge

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Size = UDim2.fromScale(1, 1)
	keyLabel.BackgroundTransparency = 1
	keyLabel.Text = keyText
	keyLabel.TextSize = 16
	keyLabel.Font = Enum.Font.GothamBold
	keyLabel.TextColor3 = BRIGHT_TEXT
	keyLabel.Parent = keyBadge

	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.new(1, -50, 1, 0)
	textLabel.Position = UDim2.fromOffset(46, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text
	textLabel.TextSize = 14
	textLabel.Font = Enum.Font.GothamMedium
	textLabel.TextColor3 = DIM_TEXT
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.TextWrapped = true
	textLabel.Parent = canvas

	if self.HoldDuration > 0 then
		local progressTrack = Instance.new("Frame")
		progressTrack.Name = "ProgressTrack"
		progressTrack.Size = UDim2.new(1, 0, 0, 4)
		progressTrack.Position = UDim2.new(0, 0, 1, -4)
		progressTrack.BackgroundColor3 = KEY_BADGE
		progressTrack.BorderSizePixel = 0
		progressTrack.ZIndex = 2
		progressTrack.Parent = canvas

		-- Fills left-to-right as the key is held - see _setHoldProgress. Starts
		-- at 0 width, not full, so an untouched hold prompt doesn't look like
		-- it's already partway done.
		local progressFill = Instance.new("Frame")
		progressFill.Name = "ProgressFill"
		progressFill.Size = UDim2.fromScale(0, 1)
		progressFill.BackgroundColor3 = ACCENT
		progressFill.BorderSizePixel = 0
		progressFill.ZIndex = 3
		progressFill.Parent = progressTrack

		self.ProgressFill = progressFill
	end

	self.Gui = billboard
	self.Canvas = canvas
end

function CustomPrompt:_setVisible(visible)
	if self.Visible == visible then
		return
	end
	self.Visible = visible
	self:_setBound(visible)

	-- Shown before the fade starts, hidden only after it finishes, so the
	-- fade is actually seen in both directions. Enabled (rather than
	-- transparency alone) is what guarantees a hidden prompt is not drawn -
	-- a fully transparent BillboardGui is still a live, laid-out, rendered
	-- object, and anything that leaves its transparency behind (an
	-- interrupted tween, a CanvasGroup that failed to build) leaves a
	-- visible panel with nothing left to hide it.
	--
	-- Never enabled at all on touch - see touchActive above.
	if visible and self.Gui then
		self.Gui.Enabled = not touchActive
	end
	TweenService:Create(self.Canvas, TweenInfo.new(FADE_TIME), {
		GroupTransparency = if visible then VISIBLE_TRANSPARENCY else 1,
	}):Play()
	if not visible then
		task.delay(FADE_TIME, function()
			-- Re-checked: it may have come back into range while fading out.
			if not self.Visible and self.Gui and self.Gui.Parent then
				self.Gui.Enabled = false
			end
		end)
	end
end

-- Hides immediately (e.g. the thing it's attached to just became
-- unavailable) rather than waiting for the next distance check to catch up.
function CustomPrompt:SetEnabled(enabled)
	self.Enabled = enabled
	if not enabled then
		self:_setVisible(false)
	end
end

function CustomPrompt:Destroy()
	activePrompts[self] = nil
	self:_setBound(false)
	if self.Gui then
		self.Gui:Destroy()
	end
end

-- Distance to the NEAREST of the prompt's reference instances, skipping any
-- that have been destroyed or unparented since setup.
local function nearestReferenceDistance(prompt, fromPosition)
	local nearest = math.huge
	for _, instance in prompt.DistanceFrom do
		if instance.Parent then
			nearest = math.min(nearest, (fromPosition - referencePosition(instance)).Magnitude)
		end
	end
	return nearest
end

RunService.Heartbeat:Connect(function()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	-- Nothing that puts the player inside something should leave a
	-- walk-up-to-it prompt on screen, and the local humanoid is the one place
	-- that is true for EVERY seat at once - their own car, someone else's, a
	-- bench. Checked here rather than left to each caller so that no prompt
	-- can forget it.
	local isAlive = humanoid ~= nil and humanoid.Health > 0
	-- Three overlapping tests rather than one, because they fail in different
	-- ways and none is reliable alone: SeatPart is the direct answer but is
	-- cleared a frame early on some unseat paths, Humanoid.Sit is the flag the
	-- engine itself drives the seated state from, and the Seated STATE covers
	-- the window where a seat weld exists but the properties have not caught
	-- up yet. Any one of them saying "seated" is enough to hide every prompt.
	local isSeated = humanoid ~= nil
		and (
			humanoid.SeatPart ~= nil
			or humanoid.Sit
			or humanoid:GetState() == Enum.HumanoidStateType.Seated
		)

	-- Two prompts in range at once that share a key (parking two cars next to
	-- each other is enough) would both bind it, and ContextActionService only
	-- ever hands the key to whichever bound last - so the one the player is
	-- standing at is not reliably the one that responds. Only the NEAREST
	-- in-range prompt per KeyCode is shown, which makes the answer both
	-- unambiguous on screen and unambiguous to the input stack. Prompts on
	-- different keys don't compete and can still show together.
	local winnerByKey = {}

	for prompt in activePrompts do
		local canShow = prompt.Enabled
			and rootPart ~= nil
			and isAlive
			and not isSeated
			and prompt.Part.Parent ~= nil
			and (prompt.ShouldShow == nil or prompt.ShouldShow() == true)

		local distance = if canShow then nearestReferenceDistance(prompt, rootPart.Position) else math.huge
		if distance <= prompt.MaxActivationDistance then
			local current = winnerByKey[prompt.KeyCode]
			if not current or distance < current.Distance then
				winnerByKey[prompt.KeyCode] = { Prompt = prompt, Distance = distance }
			end
		end
	end

	-- Applied in a second pass, never inline above: toggling a prompt off and
	-- straight back on within the same frame would restart its fade tween and
	-- rebind its key every single frame.
	for prompt in activePrompts do
		local winner = winnerByKey[prompt.KeyCode]
		prompt:_setVisible(winner ~= nil and winner.Prompt == prompt)
	end
end)

return CustomPrompt

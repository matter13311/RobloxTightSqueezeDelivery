-- A lightweight, ProximityPrompt-like interaction prompt built from a plain
-- BillboardGui instead of the real ProximityPrompt. Built for first-person:
-- ProximityPrompt's own on-screen highlight has a quirk where the mouse
-- cursor gets trapped/re-centered on it, which is exactly the wrong thing to
-- happen every time the camera swings past one.
--
-- Deliberately generic - not vehicle-specific - so any "walk up, press a key"
-- interaction can reuse it. See VehicleDoorPrompts.client.luau for the first
-- user. API mirrors ProximityPrompt's own shape on purpose (Triggered,
-- Enabled, MaxActivationDistance) so it's a familiar drop-in.
--
-- Client-only (reads Players.LocalPlayer and the local character) - do not
-- require this from a server script.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

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
	self.ShouldShow = config.ShouldShow
	self.Enabled = true
	self.Visible = false
	self.Triggered = newSignal()

	nextId += 1
	self._actionName = "CustomPrompt" .. nextId
	self._bound = false

	self:_buildGui(config.Text or "Interact", config.KeyText or self.KeyCode.Name)

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
			if inputState == Enum.UserInputState.Begin then
				self.Triggered:Fire(player)
			end
			return Enum.ContextActionResult.Sink
		end, false, self.KeyCode)
	else
		ContextActionService:UnbindAction(self._actionName)
	end
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
	if visible and self.Gui then
		self.Gui.Enabled = true
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

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
	local signal = {}
	function signal:Connect(fn)
		local id = #connections + 1
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

-- `part` is what the prompt is anchored to and measures distance from.
-- `config`: Text (string), KeyText (string, defaults to the KeyCode's name),
-- KeyCode (Enum.KeyCode, default F), MaxActivationDistance (studs, default 8).
function CustomPrompt.new(part, config)
	config = config or {}
	local self = setmetatable({}, CustomPrompt)

	self.Part = part
	self.KeyCode = config.KeyCode or Enum.KeyCode.F
	self.MaxActivationDistance = config.MaxActivationDistance or 8
	self.Enabled = true
	self.Visible = false
	self.Triggered = newSignal()

	nextId += 1
	self._actionName = "CustomPrompt" .. nextId

	self:_buildGui(config.Text or "Interact", config.KeyText or self.KeyCode.Name)

	ContextActionService:BindAction(self._actionName, function(_, inputState)
		if inputState == Enum.UserInputState.Begin and self.Visible and self.Enabled then
			self.Triggered:Fire(player)
		end
		return Enum.ContextActionResult.Sink
	end, false, self.KeyCode)

	activePrompts[self] = true
	return self
end

function CustomPrompt:_buildGui(text, keyText)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CustomPrompt"
	billboard.Size = UDim2.fromOffset(160, 46)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
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
	TweenService:Create(self.Canvas, TweenInfo.new(FADE_TIME), {
		GroupTransparency = if visible then VISIBLE_TRANSPARENCY else 1,
	}):Play()
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
	ContextActionService:UnbindAction(self._actionName)
	if self.Gui then
		self.Gui:Destroy()
	end
end

RunService.Heartbeat:Connect(function()
	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")

	for prompt in activePrompts do
		if not prompt.Enabled or not rootPart or not prompt.Part.Parent then
			prompt:_setVisible(false)
		else
			local distance = (rootPart.Position - prompt.Part.Position).Magnitude
			prompt:_setVisible(distance <= prompt.MaxActivationDistance)
		end
	end
end)

return CustomPrompt

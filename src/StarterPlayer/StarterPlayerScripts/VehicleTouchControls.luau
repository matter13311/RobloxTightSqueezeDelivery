-- On-screen buttons for the driving actions that otherwise only exist as
-- keybinds (RayCastSuspension.client.luau's bindDrivingControls): exit,
-- handbrake, horn, headlights, turn signals, and the third-person unlock
-- prompt. None of those have a walk-up CustomPrompt to make tappable the way
-- CustomPrompt.luau does for entering the car in the first place - while
-- actually driving there is nothing on screen a touch player can press, so
-- this exists purely to give touch input the same actions the keyboard has.
--
-- Built and destroyed once per drive session (see RayCastSuspension's
-- beginDrive/endDrive), same lifetime as VehicleDashboard/VehicleControlsHint.
-- Only shown while the player is actually using touch right now, tracked
-- live via LastInputTypeChanged rather than decided once at construction -
-- see CustomPrompt.luau's own listener for the same reasoning: TouchEnabled
-- says what the device HAS, not what the player is holding, and a hybrid
-- device (touchscreen laptop) can switch between mouse and touch mid-drive.

local UserInputService = game:GetService("UserInputService")

local PANEL = Color3.fromRGB(18, 20, 25)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)
local EXIT_COLOR = Color3.fromRGB(232, 138, 60)
local ACTIVE_COLOR = Color3.fromRGB(220, 90, 90)

local IDLE_TRANSPARENCY = 0.1
local ACTIVE_TRANSPARENCY = 0

local function isTouchInput(inputType)
	return inputType == Enum.UserInputType.Touch
end

local VehicleTouchControls = {}
VehicleTouchControls.__index = VehicleTouchControls

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1.5
	s.Parent = parent
	return s
end

-- One small round-ish button. `onPress`/`onRelease` are called for a held
-- control (handbrake, horn); a plain toggle (lights, blinkers, exit, third
-- person) only ever passes `onPress` and leaves `onRelease` nil.
local function newButton(parent, size, position, text, color, onPress, onRelease)
	local button = Instance.new("TextButton")
	button.Size = size
	button.Position = position
	button.BackgroundColor3 = PANEL
	button.BackgroundTransparency = IDLE_TRANSPARENCY
	button.AutoButtonColor = false
	button.Text = text
	button.TextSize = 13
	button.Font = Enum.Font.GothamBold
	button.TextColor3 = color
	button.TextWrapped = true
	button.Parent = parent
	corner(button, 999)
	local edge = stroke(button, color, 1.5)

	if onRelease then
		local function setActive(active)
			button.BackgroundTransparency = active and ACTIVE_TRANSPARENCY or IDLE_TRANSPARENCY
			button.BackgroundColor3 = active and color or PANEL
			button.TextColor3 = active and PANEL or color
		end
		button.MouseButton1Down:Connect(function()
			setActive(true)
			onPress()
		end)
		button.MouseButton1Up:Connect(function()
			setActive(false)
			onRelease()
		end)
		button.MouseLeave:Connect(function()
			setActive(false)
			onRelease()
		end)
	else
		button.Activated:Connect(onPress)
	end

	return button, edge
end

-- `handlers`:
--   OnExit()                    F - ask to get out
--   OnHandbrakeChanged(active)  Space - held
--   OnHeadlightsToggle()        L
--   OnTurnSignal(side)          Q/E - "Left"/"Right"
--   OnHornChanged(active)       H - held
--   OnThirdPersonShop()         T - only relevant without third-person access
--   ShowThirdPersonButton       (boolean) whether to build that button at all
function VehicleTouchControls.new(player, handlers)
	local self = setmetatable({}, VehicleTouchControls)
	self.Handlers = handlers

	local gui = Instance.new("ScreenGui")
	gui.Name = "VehicleTouchControls"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = isTouchInput(UserInputService:GetLastInputType())
	gui.Parent = player:WaitForChild("PlayerGui")
	self.Gui = gui

	-- Bottom-left: exit, on its own and bigger than the rest - the same
	-- "make sure this one can't be missed" reasoning VehicleControlsHint.luau
	-- gives F on the keyboard legend.
	newButton(
		gui,
		UDim2.fromOffset(64, 64),
		UDim2.new(0, 24, 1, -100),
		"EXIT",
		EXIT_COLOR,
		function()
			handlers.OnExit()
		end
	)

	-- Bottom-right: handbrake, the other held control worth a bigger target
	-- than a toggle since it gets mashed/held during a drift.
	newButton(
		gui,
		UDim2.fromOffset(72, 72),
		UDim2.new(1, -96, 1, -108),
		"BRAKE",
		ACTIVE_COLOR,
		function()
			handlers.OnHandbrakeChanged(true)
		end,
		function()
			handlers.OnHandbrakeChanged(false)
		end
	)

	-- A quieter row of secondary toggles above the handbrake - horn, lights,
	-- blinkers, third person - same "everything else, second" ordering
	-- VehicleControlsHint.luau uses for the keyboard legend.
	local secondaryRow = Instance.new("Frame")
	secondaryRow.BackgroundTransparency = 1
	secondaryRow.AnchorPoint = Vector2.new(1, 1)
	secondaryRow.Position = UDim2.new(1, -24, 1, -190)
	secondaryRow.Size = UDim2.fromOffset(280, 48)
	secondaryRow.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = secondaryRow

	newButton(secondaryRow, UDim2.fromOffset(48, 48), UDim2.new(), "◀", BRIGHT_TEXT, function()
		handlers.OnTurnSignal("Left")
	end)
	newButton(secondaryRow, UDim2.fromOffset(48, 48), UDim2.new(), "▶", BRIGHT_TEXT, function()
		handlers.OnTurnSignal("Right")
	end)
	newButton(secondaryRow, UDim2.fromOffset(48, 48), UDim2.new(), "LIGHTS", DIM_TEXT, function()
		handlers.OnHeadlightsToggle()
	end)
	newButton(
		secondaryRow,
		UDim2.fromOffset(48, 48),
		UDim2.new(),
		"HORN",
		ACCENT,
		function()
			handlers.OnHornChanged(true)
		end,
		function()
			handlers.OnHornChanged(false)
		end
	)
	if handlers.ShowThirdPersonButton then
		newButton(secondaryRow, UDim2.fromOffset(48, 48), UDim2.new(), "3RD", DIM_TEXT, function()
			handlers.OnThirdPersonShop()
		end)
	end

	self._inputConnection = UserInputService.LastInputTypeChanged:Connect(function(inputType)
		gui.Enabled = isTouchInput(inputType)
	end)

	return self
end

function VehicleTouchControls:Destroy()
	if self._inputConnection then
		self._inputConnection:Disconnect()
		self._inputConnection = nil
	end
	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end
end

return VehicleTouchControls

-- The settings menu, plus the gear button that advertises it.
--
-- Builds itself entirely from GameSettings.GetDefinitions(), so it never names
-- an individual setting: add one there and a row appears here, in its category,
-- with the right control. That is the whole point of the split - this file is
-- about layout and input, not about what the game can be configured to do.
--
-- THE MOUSE, and why this matters for a first-person game: when the camera is
-- in first person Roblox's own camera code locks the cursor to the centre of
-- the screen every frame, which makes any menu unclickable. Freeing it once on
-- open does not work - the camera controller simply puts it back. The fix is
-- to re-assert it every frame at RenderPriority.Last, which runs after the
-- camera has had its say, so ours is the value that survives the frame. See
-- applyMouseState.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GameSettings = require(script.Parent.GameSettings)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TOGGLE_ACTION = "ToggleSettingsMenu"
local MOUSE_STEP = "SettingsMenuMouse"

local COLORS = {
	Backdrop = Color3.fromRGB(0, 0, 0),
	Panel = Color3.fromRGB(28, 30, 34),
	Row = Color3.fromRGB(20, 22, 25),
	Category = Color3.fromRGB(150, 200, 255),
	Text = Color3.fromRGB(235, 237, 240),
	Muted = Color3.fromRGB(150, 155, 165),
	Track = Color3.fromRGB(55, 59, 66),
	Fill = Color3.fromRGB(90, 160, 245),
	ToggleOn = Color3.fromRGB(90, 160, 245),
	ToggleOff = Color3.fromRGB(70, 74, 82),
}

-- The slider's visible bar is thin, but the area that ACCEPTS a click is this
-- tall - the bar is centred inside it. Aiming at an 8-pixel line is miserable;
-- aiming at a 28-pixel band is not, and the two can look identical.
local SLIDER_HIT_HEIGHT = 28
local SLIDER_BAR_HEIGHT = 8
local SLIDER_KNOB = 20

local isOpen = false
local screenGui
local rowsParent
local renderers = {}

-- =========================================================================
-- Small builders
-- =========================================================================

local function corner(parent, radius)
	local instance = Instance.new("UICorner")
	instance.CornerRadius = UDim.new(0, radius)
	instance.Parent = parent
	return instance
end

local function label(parent, text, size, color, bold)
	local instance = Instance.new("TextLabel")
	instance.BackgroundTransparency = 1
	instance.Text = text
	instance.TextColor3 = color
	instance.TextSize = size
	instance.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	instance.TextXAlignment = Enum.TextXAlignment.Left
	instance.TextYAlignment = Enum.TextYAlignment.Top
	instance.Parent = parent
	return instance
end

-- Rows size themselves to their text rather than to a fixed height, so a long
-- description wraps and the row grows instead of clipping it. The left column
-- owns the wrapping; the row inherits its height through AutomaticSize.
local function buildRow(definition, order)
	local row = Instance.new("Frame")
	row.Name = definition.Key
	row.BackgroundColor3 = COLORS.Row
	row.BackgroundTransparency = 0.4
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.LayoutOrder = order
	-- Absorbs clicks so they never reach the backdrop behind the panel.
	row.Active = true
	row.Parent = rowsParent
	corner(row, 6)

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.Parent = row

	local minHeight = Instance.new("UISizeConstraint")
	minHeight.MinSize = Vector2.new(0, 52)
	minHeight.Parent = row

	local text = Instance.new("Frame")
	text.BackgroundTransparency = 1
	text.Size = UDim2.new(0.56, 0, 0, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.Parent = row

	local textLayout = Instance.new("UIListLayout")
	textLayout.Padding = UDim.new(0, 3)
	textLayout.SortOrder = Enum.SortOrder.LayoutOrder
	textLayout.Parent = text

	local title = label(text, definition.Label, 15, COLORS.Text, true)
	title.Size = UDim2.new(1, 0, 0, 18)
	title.LayoutOrder = 1

	if definition.Description then
		local description = label(text, definition.Description, 12, COLORS.Muted)
		description.Size = UDim2.new(1, 0, 0, 0)
		description.AutomaticSize = Enum.AutomaticSize.Y
		description.TextWrapped = true
		description.LayoutOrder = 2
	end

	local control = Instance.new("Frame")
	control.Name = "Control"
	control.BackgroundTransparency = 1
	control.AnchorPoint = Vector2.new(1, 0)
	control.Position = UDim2.new(1, 0, 0, 0)
	control.Size = UDim2.new(0.4, 0, 0, 44)
	control.Parent = row

	return control
end

-- =========================================================================
-- Controls
-- =========================================================================

local function buildToggle(definition, control)
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(1, 0)
	button.Position = UDim2.new(1, 0, 0, 4)
	button.Size = UDim2.new(0, 60, 0, 30)
	button.Text = ""
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Parent = control
	corner(button, 15)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.new(0, 24, 0, 24)
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.BackgroundColor3 = COLORS.Text
	knob.BorderSizePixel = 0
	knob.Parent = button
	corner(knob, 12)

	local function render()
		local on = GameSettings.Get(definition.Key)
		button.BackgroundColor3 = if on then COLORS.ToggleOn else COLORS.ToggleOff
		knob.Position = if on then UDim2.new(1, -27, 0.5, 0) else UDim2.new(0, 3, 0.5, 0)
	end

	button.Activated:Connect(function()
		GameSettings.Set(definition.Key, not GameSettings.Get(definition.Key))
	end)

	return render
end

local function buildSlider(definition, control)
	local readout = label(control, "", 13, COLORS.Muted, true)
	readout.Position = UDim2.new(0, 0, 0, 0)
	readout.Size = UDim2.new(1, 0, 0, 14)
	readout.TextXAlignment = Enum.TextXAlignment.Right

	-- The hit area is a TextButton so it captures input itself, and it is far
	-- taller than the bar drawn inside it. Clicking anywhere along it jumps
	-- the value, so the knob never has to be hit precisely.
	local hit = Instance.new("TextButton")
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.BackgroundTransparency = 1
	hit.AnchorPoint = Vector2.new(1, 1)
	hit.Position = UDim2.new(1, 0, 1, 0)
	hit.Size = UDim2.new(1, 0, 0, SLIDER_HIT_HEIGHT)
	hit.Parent = control

	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(0.5, 0.5)
	track.Position = UDim2.fromScale(0.5, 0.5)
	track.Size = UDim2.new(1, 0, 0, SLIDER_BAR_HEIGHT)
	track.BackgroundColor3 = COLORS.Track
	track.BorderSizePixel = 0
	track.Parent = hit
	corner(track, SLIDER_BAR_HEIGHT // 2)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = COLORS.Fill
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.Parent = track
	corner(fill, SLIDER_BAR_HEIGHT // 2)

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.new(0, SLIDER_KNOB, 0, SLIDER_KNOB)
	knob.BackgroundColor3 = COLORS.Text
	knob.BorderSizePixel = 0
	knob.ZIndex = 2
	knob.Parent = track
	corner(knob, SLIDER_KNOB // 2)

	local function render()
		local value = GameSettings.Get(definition.Key)
		local fraction = (value - definition.Min) / math.max(definition.Max - definition.Min, 1e-6)
		fill.Size = UDim2.new(fraction, 0, 1, 0)
		knob.Position = UDim2.new(fraction, 0, 0.5, 0)
		readout.Text = if definition.Format then definition.Format(value) else tostring(value)
	end

	local function setFromX(x)
		local left = track.AbsolutePosition.X
		local width = math.max(track.AbsoluteSize.X, 1)
		local fraction = math.clamp((x - left) / width, 0, 1)
		GameSettings.Set(definition.Key, definition.Min + fraction * (definition.Max - definition.Min))
	end

	local dragging = false
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	-- Tracked on the SERVICE, not on the button: once you are dragging, the
	-- pointer routinely leaves the control entirely, and a connection on the
	-- control would stop receiving movement the moment it did.
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	return render
end

-- =========================================================================
-- Menu construction
-- =========================================================================

local function buildMenu()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "SettingsMenu"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 100
	screenGui.Enabled = false
	screenGui.Parent = playerGui

	-- Only the backdrop closes on click. Everything above it sets Active so
	-- input stops there: a Frame does NOT block clicks by default, which is
	-- why stray clicks inside the panel used to fall through to here and shut
	-- the menu.
	local backdrop = Instance.new("TextButton")
	backdrop.Text = ""
	backdrop.AutoButtonColor = false
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = COLORS.Backdrop
	backdrop.BackgroundTransparency = 0.45
	backdrop.BorderSizePixel = 0
	backdrop.Parent = screenGui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0.5, 0, 0.72, 0)
	panel.BackgroundColor3 = COLORS.Panel
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.Parent = screenGui
	corner(panel, 10)

	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(420, 320)
	constraint.MaxSize = Vector2.new(620, 560)
	constraint.Parent = panel

	local header = label(panel, "Settings", 20, COLORS.Text, true)
	header.Position = UDim2.new(0, 20, 0, 16)
	header.Size = UDim2.new(1, -60, 0, 26)

	local hint = label(panel, "Press M to close", 12, COLORS.Muted)
	hint.Position = UDim2.new(0, 20, 0, 40)
	hint.Size = UDim2.new(1, -60, 0, 16)

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -14, 0, 14)
	close.Size = UDim2.new(0, 30, 0, 30)
	close.Text = "X"
	close.TextSize = 16
	close.Font = Enum.Font.GothamBold
	close.TextColor3 = COLORS.Text
	close.BackgroundColor3 = COLORS.ToggleOff
	close.BorderSizePixel = 0
	close.Parent = panel
	corner(close, 6)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.new(0, 14, 0, 68)
	scroll.Size = UDim2.new(1, -28, 1, -82)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Active = true
	scroll.Parent = panel
	rowsParent = scroll

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	-- Categories in the declared order first, then anything new alphabetically,
	-- so adding a category to GameSettings needs no change here.
	local seen, ordered = {}, {}
	for _, name in GameSettings.GetCategoryOrder() do
		seen[name] = true
		table.insert(ordered, name)
	end
	local extra = {}
	for _, definition in GameSettings.GetDefinitions() do
		local name = definition.Category or "General"
		if not seen[name] then
			seen[name] = true
			table.insert(extra, name)
		end
	end
	table.sort(extra)
	for _, name in extra do
		table.insert(ordered, name)
	end

	local order = 0
	for _, category in ordered do
		local heading = label(scroll, string.upper(category), 12, COLORS.Category, true)
		heading.Size = UDim2.new(1, 0, 0, 20)
		order += 1
		heading.LayoutOrder = order

		for _, definition in GameSettings.GetDefinitions() do
			if (definition.Category or "General") == category then
				order += 1
				local control = buildRow(definition, order)
				local render = if definition.Type == "Toggle"
					then buildToggle(definition, control)
					else buildSlider(definition, control)
				render()
				renderers[definition.Key] = render
			end
		end
	end

	return backdrop, close
end

-- A persistent corner button, so the menu is discoverable without having to
-- know the keybind. Its own ScreenGui rather than a child of the menu's, since
-- it has to stay visible exactly when the menu is NOT.
local function buildLauncher(onClick)
	local gui = Instance.new("ScreenGui")
	gui.Name = "SettingsLauncher"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 99
	gui.Parent = playerGui

	local holder = Instance.new("Frame")
	holder.AnchorPoint = Vector2.new(1, 1)
	holder.Position = UDim2.new(1, -18, 1, -18)
	holder.Size = UDim2.new(0, 52, 0, 70)
	holder.BackgroundTransparency = 1
	holder.Parent = gui

	local button = Instance.new("TextButton")
	button.Size = UDim2.new(0, 52, 0, 52)
	button.Position = UDim2.new(0, 0, 0, 0)
	button.BackgroundColor3 = COLORS.Panel
	button.BackgroundTransparency = 0.25
	button.BorderSizePixel = 0
	button.Text = "\u{2699}"
	button.TextSize = 26
	button.TextColor3 = COLORS.Text
	button.Font = Enum.Font.GothamBold
	button.Parent = holder
	corner(button, 26)

	local key = label(holder, "[M]", 12, COLORS.Muted, true)
	key.Position = UDim2.new(0, 0, 0, 54)
	key.Size = UDim2.new(1, 0, 0, 14)
	key.TextXAlignment = Enum.TextXAlignment.Center

	button.Activated:Connect(onClick)
	return gui
end

-- =========================================================================
-- Open / close
-- =========================================================================

-- Re-asserted every frame while open. Roblox's camera controller sets
-- MouseBehavior itself during its own update, so a single write on open gets
-- overwritten; running at Last means this is the value left standing.
local function applyMouseState()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local launcherGui

local function setOpen(open)
	if isOpen == open then
		return
	end
	isOpen = open
	screenGui.Enabled = open
	launcherGui.Enabled = not open

	if open then
		RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Last.Value, applyMouseState)
	else
		RunService:UnbindFromRenderStep(MOUSE_STEP)
		-- Handing control back rather than forcing LockCenter: the camera
		-- controller decides what the cursor should do based on how zoomed in
		-- the player is, and it re-locks on its own next frame if they are in
		-- first person.
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

local backdrop, close = buildMenu()
launcherGui = buildLauncher(function()
	setOpen(true)
end)

backdrop.Activated:Connect(function()
	setOpen(false)
end)
close.Activated:Connect(function()
	setOpen(false)
end)

GameSettings.OnChanged(function(key)
	local render = renderers[key]
	if render then
		render()
	end
end)

ContextActionService:BindAction(TOGGLE_ACTION, function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		setOpen(not isOpen)
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.M, Enum.KeyCode.ButtonStart)

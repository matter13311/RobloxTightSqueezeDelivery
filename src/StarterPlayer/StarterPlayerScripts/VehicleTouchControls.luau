-- On-screen buttons for the driving actions that otherwise only exist as
-- keybinds (RayCastSuspension.client.luau's bindDrivingControls): exit, gas,
-- brake, handbrake, horn, headlights, turn signals, and the third-person
-- unlock prompt. None of those have a walk-up CustomPrompt to make tappable
-- the way CustomPrompt.luau does for entering the car in the first place -
-- while actually driving there is nothing on screen a touch player can press,
-- so this exists purely to give touch input the same actions the keyboard has.
--
-- GAS and BRAKE exist alongside Roblox's own default vehicle touch joystick
-- (still there, still working - see throttleInput in RayCastSuspension) rather
-- than replacing it, because that joystick blends steering and throttle into
-- one diagonal drag, which is exactly the kind of imprecise input that makes
-- a new/young driver stall out or lurch. Two big, clearly-labelled pedals are
-- the same "make the intent unmistakable" reasoning EXIT already gets.
--
-- Built and destroyed once per drive session (see RayCastSuspension's
-- beginDrive/endDrive), same lifetime as VehicleDashboard/VehicleControlsHint.
-- Only shown while the player is actually using touch right now, tracked
-- live via LastInputTypeChanged rather than decided once at construction -
-- see CustomPrompt.luau's own listener for the same reasoning: TouchEnabled
-- says what the device HAS, not what the player is holding, and a hybrid
-- device (touchscreen laptop) can switch between mouse and touch mid-drive.

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local PANEL = Color3.fromRGB(18, 20, 25)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)
local EXIT_COLOR = Color3.fromRGB(232, 138, 60)
local ACTIVE_COLOR = Color3.fromRGB(220, 90, 90)
local BRAKE_COLOR = Color3.fromRGB(224, 178, 84)

local IDLE_TRANSPARENCY = 0.1
local ACTIVE_TRANSPARENCY = 0

-- Every size and margin below was tuned on an iPhone 6 Plus in landscape,
-- whose viewport is this many pixels. Other screens scale the whole layout
-- by how much bigger or smaller they are than it, so the buttons take up the
-- same share of the screen everywhere rather than the same pixel count -
-- which on a small phone crowded the thumbstick and on a tablet left them
-- tiny in the corners.
local DESIGN_LONG_SIDE = 736
local DESIGN_SHORT_SIDE = 414
-- Clamped so an extreme viewport (a tiny phone, a huge tablet) can't push the
-- buttons below a size a thumb can hit or up to one that covers the road.
local MIN_SCALE = 0.7
local MAX_SCALE = 1.5

local function isTouchInput(inputType)
	return inputType == Enum.UserInputType.Touch
end

local function isPressInput(input)
	return input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1
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
-- control (gas, brake, handbrake, horn); a plain toggle (lights, blinkers,
-- exit, third person) only ever passes `onPress` and leaves `onRelease` nil.
function VehicleTouchControls:_newButton(parent, size, position, text, color, onPress, onRelease)
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
		-- Held controls follow the one touch that pressed them, not the
		-- button's own MouseButton1Up/MouseLeave. Those only fire while the
		-- finger is still over the button, so a thumb that slid off GAS and
		-- lifted somewhere else never released it and the truck kept driving.
		-- UserInputService.InputEnded fires for every touch wherever it ends,
		-- and matching the exact InputObject means lifting a DIFFERENT finger
		-- (the steering thumb) never lets go of this one.
		local heldInput = nil

		local function setActive(active)
			button.BackgroundTransparency = active and ACTIVE_TRANSPARENCY or IDLE_TRANSPARENCY
			button.BackgroundColor3 = active and color or PANEL
			button.TextColor3 = active and PANEL or color
		end

		local function release()
			if heldInput then
				heldInput = nil
				setActive(false)
				onRelease()
			end
		end

		button.InputBegan:Connect(function(input)
			if heldInput or not isPressInput(input) then
				return
			end
			heldInput = input
			setActive(true)
			onPress()
		end)

		table.insert(
			self._connections,
			UserInputService.InputEnded:Connect(function(input)
				if not heldInput then
					return
				end
				-- Touches keep the same InputObject from start to end; the
				-- mouse isn't guaranteed to, so any left-button release counts.
				local matches = if heldInput.UserInputType == Enum.UserInputType.Touch
					then input == heldInput
					else input.UserInputType == Enum.UserInputType.MouseButton1
				if matches then
					release()
				end
			end)
		)

		table.insert(self._releasers, release)
	else
		button.Activated:Connect(onPress)
	end

	return button, edge
end

-- A transparent frame pinned to a screen corner, holding one cluster of
-- buttons laid out in design pixels. The UIScale on it grows or shrinks the
-- cluster about its anchor (the corner), and relayout scales the margin to
-- that corner by the same amount so clusters never drift into each other.
function VehicleTouchControls:_newGroup(anchor, margin, size)
	local group = Instance.new("Frame")
	group.BackgroundTransparency = 1
	group.AnchorPoint = anchor
	group.Size = size
	group.Parent = self.Gui

	local scale = Instance.new("UIScale")
	scale.Parent = group

	table.insert(self._groups, { Frame = group, Scale = scale, Anchor = anchor, Margin = margin })
	return group
end

function VehicleTouchControls:_relayout()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local viewport = camera.ViewportSize
	if viewport.X <= 0 or viewport.Y <= 0 then
		return
	end
	-- Long/short side rather than X/Y, so the same numbers hold whichever
	-- way the phone is turned.
	local long = math.max(viewport.X, viewport.Y)
	local short = math.min(viewport.X, viewport.Y)
	local s = math.clamp(math.min(long / DESIGN_LONG_SIDE, short / DESIGN_SHORT_SIDE), MIN_SCALE, MAX_SCALE)

	for _, group in self._groups do
		group.Scale.Scale = s
		-- Anchor 0 means measured from the left/top edge, 1 from the right/bottom.
		local x = if group.Anchor.X == 0 then group.Margin.X * s else -group.Margin.X * s
		local y = if group.Anchor.Y == 0 then group.Margin.Y * s else -group.Margin.Y * s
		group.Frame.Position = UDim2.new(group.Anchor.X, x, group.Anchor.Y, y)
	end
end

-- Lets go of every held control at once - used whenever the buttons stop
-- being reachable (switching to keyboard hides them, the drive ending
-- destroys them), since no touch can end on a button that isn't there.
function VehicleTouchControls:_releaseAll()
	for _, release in self._releasers do
		release()
	end
end

-- `handlers`:
--   OnExit()                    F - ask to get out
--   OnGasChanged(active)        W - held
--   OnBrakeChanged(active)      S - held
--   OnHandbrakeChanged(active)  Space - held
--   OnHeadlightsToggle()        L
--   OnTurnSignal(side)          Q/E - "Left"/"Right"
--   OnHornChanged(active)       H - held
--   OnThirdPersonShop()         T - only relevant without third-person access
--   ShowThirdPersonButton       (boolean) whether to build that button at all
function VehicleTouchControls.new(player, handlers)
	local self = setmetatable({}, VehicleTouchControls)
	self.Handlers = handlers
	self._connections = {}
	self._releasers = {}
	self._groups = {}

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
	local exitGroup = self:_newGroup(Vector2.new(0, 1), Vector2.new(24, 36), UDim2.fromOffset(64, 64))
	self:_newButton(exitGroup, UDim2.fromOffset(64, 64), UDim2.new(), "EXIT", EXIT_COLOR, function()
		handlers.OnExit()
	end)

	-- Bottom-right: three pedals in a row, all big enough to find without
	-- looking down - GAS closest to the corner since it's the one a thumb
	-- rests on by default, BRAKE next to it, E-BRAKE furthest in since it's
	-- reached for less often (mid-drift) than the other two (every second of
	-- driving).
	local pedals = self:_newGroup(Vector2.new(1, 1), Vector2.new(24, 36), UDim2.fromOffset(232, 72))

	self:_newButton(
		pedals,
		UDim2.fromOffset(72, 72),
		UDim2.fromOffset(0, 0),
		"E-BRAKE",
		ACTIVE_COLOR,
		function()
			handlers.OnHandbrakeChanged(true)
		end,
		function()
			handlers.OnHandbrakeChanged(false)
		end
	)

	self:_newButton(
		pedals,
		UDim2.fromOffset(72, 72),
		UDim2.fromOffset(80, 0),
		"BRAKE",
		BRAKE_COLOR,
		function()
			handlers.OnBrakeChanged(true)
		end,
		function()
			handlers.OnBrakeChanged(false)
		end
	)

	self:_newButton(
		pedals,
		UDim2.fromOffset(72, 72),
		UDim2.fromOffset(160, 0),
		"GAS",
		ACCENT,
		function()
			handlers.OnGasChanged(true)
		end,
		function()
			handlers.OnGasChanged(false)
		end
	)

	-- A quieter row of secondary toggles above the pedal cluster - horn,
	-- lights, blinkers, third person - same "everything else, second"
	-- ordering VehicleControlsHint.luau uses for the keyboard legend.
	local secondaryRow = self:_newGroup(Vector2.new(1, 1), Vector2.new(24, 190), UDim2.fromOffset(280, 48))

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 8)
	layout.Parent = secondaryRow

	self:_newButton(secondaryRow, UDim2.fromOffset(48, 48), UDim2.new(), "◀", BRIGHT_TEXT, function()
		handlers.OnTurnSignal("Left")
	end)
	self:_newButton(secondaryRow, UDim2.fromOffset(48, 48), UDim2.new(), "▶", BRIGHT_TEXT, function()
		handlers.OnTurnSignal("Right")
	end)
	self:_newButton(secondaryRow, UDim2.fromOffset(48, 48), UDim2.new(), "LIGHTS", DIM_TEXT, function()
		handlers.OnHeadlightsToggle()
	end)
	self:_newButton(
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
		self:_newButton(secondaryRow, UDim2.fromOffset(48, 48), UDim2.new(), "3RD", DIM_TEXT, function()
			handlers.OnThirdPersonShop()
		end)
	end

	table.insert(
		self._connections,
		UserInputService.LastInputTypeChanged:Connect(function(inputType)
			local touch = isTouchInput(inputType)
			if not touch then
				self:_releaseAll()
			end
			gui.Enabled = touch
		end)
	)

	-- CurrentCamera gets swapped out on respawn, so the ViewportSize hookup is
	-- redone whenever it is - same reasoning as ResponsiveScale.luau.
	local viewportConnection
	local function rehook()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				self:_relayout()
			end)
		end
		self:_relayout()
	end
	rehook()
	table.insert(self._connections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(rehook))
	self._disconnectViewport = function()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
	end

	return self
end

function VehicleTouchControls:Destroy()
	self:_releaseAll()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	if self._disconnectViewport then
		self._disconnectViewport()
		self._disconnectViewport = nil
	end
	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end
end

return VehicleTouchControls

-- The always-on entry point for VehicleThirdPersonShop.luau, and the owner of
-- its T key. Shown whether the player is walking around or driving: it is the
-- perk's only advertisement - the dashboard no longer carries a "press T" pill
-- of its own, so a player in first person with no idea the perk exists has
-- nowhere else to learn about it.
--
-- It says "3rd Person" beside a little camera rather than "Shop": the game has
-- no shop, this button sells exactly one thing, and a label that names the
-- thing tells a player what they would be buying before they click.
--
-- T is handled HERE, not in RayCastSuspension's driving bindings where it used
-- to live. Bound there it only existed for the length of a drive, so on foot
-- the button said "[T]" and the key did nothing.
--
-- Two layouts, picked live off UserInputService:GetLastInputType() the same
-- way VehicleTouchControls/CustomPrompt decide touch-only UI - because a
-- hybrid device (touchscreen laptop) can switch between mouse and touch
-- mid-session. On touch this moves up into the top-right stack alongside the
-- money pill and the settings gear (see SettingsMenu.client.luau) and shrinks
-- to match: VehicleTouchControls' GAS/BRAKE/E-BRAKE pedals now own the
-- bottom-right corner while actually driving, and a "[T]" keybind hint is
-- meaningless with no keyboard anyway.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local VehicleThirdPersonShop = require(script.Parent.VehicleThirdPersonShop)

local player = Players.LocalPlayer

local PANEL = Color3.fromRGB(28, 30, 34)
local TEXT = Color3.new(1, 1, 1)

local function isTouchInput(inputType)
	return inputType == Enum.UserInputType.Touch
end

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = instance
	return c
end

local gui = Instance.new("ScreenGui")
gui.Name = "VehicleShopButton"
gui.ResetOnSpawn = false
gui.DisplayOrder = 99
gui.Parent = player:WaitForChild("PlayerGui")

-- A TextButton with no text of its own: the icon and the label are children
-- in a centred row, so the pair stays centred together at either size.
local button = Instance.new("TextButton")
button.BackgroundColor3 = PANEL
button.BackgroundTransparency = 0.15
button.BorderSizePixel = 0
button.AutoButtonColor = true
button.Text = ""
button.Parent = gui
corner(button, 10)

local row = Instance.new("UIListLayout")
row.FillDirection = Enum.FillDirection.Horizontal
row.HorizontalAlignment = Enum.HorizontalAlignment.Center
row.VerticalAlignment = Enum.VerticalAlignment.Center
row.SortOrder = Enum.SortOrder.LayoutOrder
row.Padding = UDim.new(0, 7)
row.Parent = button

-- A camera drawn out of frames rather than an image asset: a body, a
-- viewfinder bump on top and a lens. Nothing to upload, nothing to fail to
-- load, and it scales with a UIScale for the smaller touch layout.
local icon = Instance.new("Frame")
icon.Name = "CameraIcon"
icon.Size = UDim2.fromOffset(20, 16)
icon.BackgroundTransparency = 1
icon.LayoutOrder = 1
icon.Parent = button

local iconScale = Instance.new("UIScale")
iconScale.Parent = icon

local cameraBump = Instance.new("Frame")
cameraBump.Position = UDim2.fromOffset(5, 0)
cameraBump.Size = UDim2.fromOffset(8, 5)
cameraBump.BackgroundColor3 = TEXT
cameraBump.BorderSizePixel = 0
cameraBump.Parent = icon
corner(cameraBump, 2)

local cameraBody = Instance.new("Frame")
cameraBody.Position = UDim2.fromOffset(0, 3)
cameraBody.Size = UDim2.fromOffset(20, 13)
cameraBody.BackgroundColor3 = TEXT
cameraBody.BorderSizePixel = 0
cameraBody.Parent = icon
corner(cameraBody, 3)

local cameraLens = Instance.new("Frame")
cameraLens.AnchorPoint = Vector2.new(0.5, 0.5)
cameraLens.Position = UDim2.fromScale(0.5, 0.5)
cameraLens.Size = UDim2.fromOffset(8, 8)
cameraLens.BackgroundColor3 = PANEL
cameraLens.BorderSizePixel = 0
cameraLens.Parent = cameraBody
corner(cameraLens, 4)

local label = Instance.new("TextLabel")
label.BackgroundTransparency = 1
label.AutomaticSize = Enum.AutomaticSize.X
label.Size = UDim2.fromScale(0, 1)
label.Font = Enum.Font.GothamBold
label.TextColor3 = TEXT
label.LayoutOrder = 2
label.Parent = button

local function layout(touch)
	if touch then
		-- Top-right, third in the stack under the gear button and the money
		-- pill - see SettingsMenu.client.luau for the other two and why
		-- 112 lines up under them. No keybind to show, so the label drops
		-- the "[T]".
		button.AnchorPoint = Vector2.new(1, 0)
		button.Position = UDim2.new(1, -14, 0, 112)
		button.Size = UDim2.new(0, 96, 0, 26)
		iconScale.Scale = 0.75
		label.TextSize = 11
		label.Text = "3rd Person"
	else
		-- Bottom-right, directly beneath the money pill - same column as the
		-- money it spends, one glance down from checking your balance.
		button.AnchorPoint = Vector2.new(1, 1)
		button.Position = UDim2.new(1, -82, 1, -18)
		button.Size = UDim2.new(0, 130, 0, 34)
		iconScale.Scale = 1
		label.TextSize = 12
		label.Text = "3rd Person  [T]"
	end
end

layout(isTouchInput(UserInputService:GetLastInputType()))
UserInputService.LastInputTypeChanged:Connect(function(inputType)
	layout(isTouchInput(inputType))
end)

button.Activated:Connect(function()
	VehicleThirdPersonShop.Open()
end)

-- A plain InputBegan rather than a ContextActionService binding: nothing else
-- wants T, so there is nothing to sink it away from, and `processed` already
-- covers the one case that matters - typing a "t" into chat.
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.T then
		VehicleThirdPersonShop.Toggle()
	end
end)

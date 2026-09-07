-- The always-on entry point for VehicleThirdPersonShop.luau. Shown whether
-- the player is walking around or driving: on foot it's the only way in (T
-- only does anything from behind the wheel - see RayCastSuspension's
-- THIRD_PERSON_SHOP_ACTION), and while driving it's now the perk's only
-- advertisement - the dashboard no longer carries a "press T" pill of its
-- own, so a player in first person with no idea the perk exists has nowhere
-- else to learn about it.
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

local button = Instance.new("TextButton")
button.BackgroundColor3 = PANEL
button.BackgroundTransparency = 0.15
button.BorderSizePixel = 0
button.Font = Enum.Font.GothamBold
button.TextColor3 = TEXT
button.Parent = gui
corner(button, 10)

local function layout(touch)
	if touch then
		-- Top-right, third in the stack under the gear button and the money
		-- pill - see SettingsMenu.client.luau for the other two and why
		-- 112 lines up under them. No keybind to show, so the label drops
		-- the "[T]".
		button.AnchorPoint = Vector2.new(1, 0)
		button.Position = UDim2.new(1, -14, 0, 112)
		button.Size = UDim2.new(0, 96, 0, 26)
		button.TextSize = 12
		button.Text = "Shop"
	else
		-- Bottom-right, directly beneath the money pill - same column as the
		-- money it spends, one glance down from checking your balance.
		button.AnchorPoint = Vector2.new(1, 1)
		button.Position = UDim2.new(1, -82, 1, -18)
		button.Size = UDim2.new(0, 130, 0, 34)
		button.TextSize = 14
		button.Text = "[T]  Shop"
	end
end

layout(isTouchInput(UserInputService:GetLastInputType()))
UserInputService.LastInputTypeChanged:Connect(function(inputType)
	layout(isTouchInput(inputType))
end)

button.Activated:Connect(function()
	VehicleThirdPersonShop.Open()
end)

-- The always-on entry point for VehicleThirdPersonShop.luau. Shown whether
-- the player is walking around or driving: on foot it's the only way in (T
-- only does anything from behind the wheel - see RayCastSuspension's
-- THIRD_PERSON_SHOP_ACTION), and while driving it's now the perk's only
-- advertisement - the dashboard no longer carries a "press T" pill of its
-- own, so a player in first person with no idea the perk exists has nowhere
-- else to learn about it.

local Players = game:GetService("Players")

local VehicleThirdPersonShop = require(script.Parent.VehicleThirdPersonShop)

local player = Players.LocalPlayer

local PANEL = Color3.fromRGB(28, 30, 34)
local TEXT = Color3.new(1, 1, 1)

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

-- Bottom-right, directly beneath the money pill (see SettingsMenu.client.luau's
-- buildMoneyDisplay, moved up to make room for this) - same column as the
-- money it spends, one glance down from checking your balance.
local button = Instance.new("TextButton")
button.AnchorPoint = Vector2.new(1, 1)
button.Position = UDim2.new(1, -82, 1, -18)
button.Size = UDim2.new(0, 130, 0, 34)
button.BackgroundColor3 = PANEL
button.BackgroundTransparency = 0.15
button.BorderSizePixel = 0
button.Font = Enum.Font.GothamBold
button.TextSize = 14
button.TextColor3 = TEXT
button.Text = "[T]  Shop"
button.Parent = gui
corner(button, 10)

button.Activated:Connect(function()
	VehicleThirdPersonShop.Open()
end)

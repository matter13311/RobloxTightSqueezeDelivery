-- Swaps the stock white arrow for a small white dot whenever Roblox's own
-- camera controller has locked the mouse to the centre of the screen -
-- which is exactly when it's in first person, walking or driving (see the
-- other scripts that fight this same lock: DeliveryHud, PlotTerminal,
-- SettingsMenu, VehicleThirdPersonShop). In that state the arrow icon just
-- sits frozen at the centre of the screen looking like a stray leftover
-- cursor rather than a first-person reticle.
--
-- Driven off MouseBehavior itself rather than VehicleViewMode or a
-- character/camera distance check, because MouseBehavior is the one signal
-- every one of those first-person cases (on foot, driving, and driving with
-- a menu open on top) already agrees on: the camera controller only holds
-- LockCenter while it actually wants mouse-look, and every menu above
-- forces it back to Default the instant it needs the cursor free - so this
-- never has to know about any of them individually.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "FirstPersonCursorGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 1000
gui.Parent = playerGui

-- Not tracked to the actual mouse position: while MouseBehavior is
-- LockCenter, Roblox pins the real cursor to the middle of the viewport, so
-- the dot only ever needs to sit there too.
local dot = Instance.new("Frame")
dot.Name = "Dot"
dot.AnchorPoint = Vector2.new(0.5, 0.5)
dot.Position = UDim2.fromScale(0.5, 0.5)
dot.Size = UDim2.fromOffset(6, 6)
dot.BackgroundColor3 = Color3.new(1, 1, 1)
dot.BorderSizePixel = 0
dot.Visible = false
dot.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(1, 0)
corner.Parent = dot

-- Thin dark outline so the dot stays visible over bright/white backgrounds,
-- where a plain white dot would otherwise disappear.
local stroke = Instance.new("UIStroke")
stroke.Color = Color3.new(0, 0, 0)
stroke.Transparency = 0.5
stroke.Thickness = 1
stroke.Parent = dot

local function updateCursor()
	local locked = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	dot.Visible = locked
	UserInputService.MouseIconEnabled = not locked
end

updateCursor()
UserInputService:GetPropertyChangedSignal("MouseBehavior"):Connect(updateCursor)

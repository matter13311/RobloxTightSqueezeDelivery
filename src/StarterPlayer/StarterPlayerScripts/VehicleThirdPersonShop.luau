-- The "buy third person" confirm panel. Two entry points open it: pressing T
-- while driving without the perk (RayCastSuspension's
-- THIRD_PERSON_SHOP_ACTION), and the lobby shop button while on foot
-- (VehicleShopButton.client.luau). Neither owns it exclusively, so this
-- module has no session of its own - it is just Open/Close/Toggle, safe to
-- call from either place at any time.
--
-- RayCastSuspension still calls Close() when a drive ends, purely so getting
-- out of the car (e.g. pressing F while the panel happens to be open) can't
-- strand it open with nothing left driving to have opened it for.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)

local player = Players.LocalPlayer

local VehicleThirdPersonShop = {}

-- Same palette as VehicleDashboard/DeliveryHud, so this reads as part of the
-- same HUD rather than a bolted-on popup.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local ACCENT = Color3.fromRGB(86, 200, 128)

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = instance
	return c
end

local function stroke(instance, color)
	local s = Instance.new("UIStroke")
	s.Color = color or PANEL_EDGE
	s.Parent = instance
	return s
end

-- Built once, lazily, the first time the panel is actually opened - most
-- drives never touch this, so there is no reason to pay for it every
-- session.
local gui = nil

local MOUSE_STEP = "ThirdPersonShopMouse"
local mouseBound = false

-- Same fix as DeliveryHud's contract board and PlotTerminal's terminal:
-- Roblox's camera controller re-asserts MouseBehavior = LockCenter every
-- frame in first person, so getting the cursor back takes winning that fight
-- every frame too, at a priority after the camera has had its say.
local function applyMouseState()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function setMouseFree(free)
	if free == mouseBound then
		return
	end
	mouseBound = free
	if free then
		RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Last.Value, applyMouseState)
	else
		RunService:UnbindFromRenderStep(MOUSE_STEP)
		-- Hand control back rather than forcing LockCenter ourselves - the
		-- camera controller decides what the cursor should do from whether
		-- the player is still in first person, and re-locks on its own next
		-- frame if so.
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

local function buildGui()
	if gui then
		return
	end

	gui = Instance.new("ScreenGui")
	gui.Name = "ThirdPersonShop"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Size = UDim2.fromOffset(340, 190)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = PANEL
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, 10)
	stroke(panel)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(20, 16)
	title.Size = UDim2.new(1, -60, 0, 26)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.TextColor3 = BRIGHT_TEXT
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Third-Person View"
	title.Parent = panel

	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.fromOffset(28, 28)
	closeButton.Position = UDim2.new(1, -44, 0, 14)
	closeButton.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
	closeButton.BorderSizePixel = 0
	closeButton.Font = Enum.Font.GothamBold
	closeButton.TextSize = 16
	closeButton.TextColor3 = DIM_TEXT
	closeButton.Text = "X"
	closeButton.Parent = panel
	corner(closeButton, 6)

	-- Rounded to the minute for the blurb - "20 minutes" reads better than
	-- "1200 seconds" and nothing here needs second-level precision.
	local minutes = math.floor(ProgressionConfig.Monetization.ThirdPersonDurationSeconds / 60 + 0.5)
	local body = Instance.new("TextLabel")
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(20, 50)
	body.Size = UDim2.new(1, -40, 0, 70)
	body.Font = Enum.Font.Gotham
	body.TextSize = 14
	body.TextColor3 = DIM_TEXT
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.Text = string.format(
		"See your truck from outside the cab for %d minutes. Buying again while it's still active adds more time on top.",
		minutes
	)
	body.Parent = panel

	local buyButton = Instance.new("TextButton")
	buyButton.AnchorPoint = Vector2.new(0.5, 1)
	buyButton.Position = UDim2.new(0.5, 0, 1, -16)
	buyButton.Size = UDim2.fromOffset(200, 40)
	buyButton.BackgroundColor3 = ACCENT
	buyButton.BorderSizePixel = 0
	buyButton.Font = Enum.Font.GothamBold
	buyButton.TextSize = 16
	buyButton.TextColor3 = Color3.fromRGB(18, 20, 25)
	-- No price on the button, matching the contract-refresh button in
	-- DeliveryHud - Roblox's own purchase prompt carries the real price, and
	-- a number typed here would just be one more place for it to go stale.
	buyButton.Text = "Unlock"
	buyButton.Parent = panel
	corner(buyButton, 8)

	closeButton.Activated:Connect(function()
		VehicleThirdPersonShop.Close()
	end)

	buyButton.Activated:Connect(function()
		-- Roblox owns the whole flow from here: the prompt, the payment, and
		-- telling the server. The panel closes on
		-- PromptProductPurchaseFinished below rather than on this click, so
		-- a cancelled purchase just leaves it open instead of dismissing
		-- itself for nothing.
		MarketplaceService:PromptProductPurchase(player, ProgressionConfig.Monetization.ThirdPersonProductId)
	end)
end

local open = false

function VehicleThirdPersonShop.Open()
	if open then
		return
	end
	buildGui()
	open = true
	gui.Enabled = true
	setMouseFree(true)
end

function VehicleThirdPersonShop.Close()
	if not open then
		return
	end
	open = false
	if gui then
		gui.Enabled = false
	end
	setMouseFree(false)
end

function VehicleThirdPersonShop.Toggle()
	if open then
		VehicleThirdPersonShop.Close()
	else
		VehicleThirdPersonShop.Open()
	end
end

-- Escape closes it, matching the delivery board and the plot terminal.
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape and open then
		VehicleThirdPersonShop.Close()
	end
end)

-- Closes itself the moment Roblox finishes the purchase flow (bought,
-- cancelled, or errored) rather than waiting on the server's attribute
-- update - the player just finished a native Roblox dialog and wants their
-- mouse-look back immediately, not on the next network round trip.
MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId)
	if userId == player.UserId and productId == ProgressionConfig.Monetization.ThirdPersonProductId then
		VehicleThirdPersonShop.Close()
	end
end)

return VehicleThirdPersonShop

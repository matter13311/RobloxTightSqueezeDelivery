-- Garage terminal: a full-screen garage view around a LIVE car.
--
-- Pressing F at the terminal no longer opens a box of UI with a photo of the
-- car in it. The camera flies over to the player's own bay and the actual car
-- is parked there (GarageStage.luau - local to this player, nobody else sees
-- it), and the UI frames it from the edges of the screen:
--
--   LEFT   the car being looked at, its main action (SPAWN / BUY), and the
--          list of every vehicle - the player's own first, then the shop.
--          Clicking a row parks that car in the bay, owned or not, so the
--          shop is a test drive for the eyes.
--   RIGHT  what can be done to the car: Upgrades (the same cards, icons and
--          Pro Tuning Pass as before) and Paint.
--   MIDDLE the car. Drag to turn it, scroll/pinch to zoom.
--
-- WHY. The car on screen IS the car, so a colour clicked in the Paint tab is
-- on it immediately - which a thumbnail could never show - and a new vehicle
-- needs no photo rendering, only a template. It also frees the whole screen
-- for UI instead of one 720x624 box.
--
-- THE AUDIENCE is still a nine-year-old with a short attention span who may
-- not read English well, so the upgrade cards keep what made them work: a big
-- icon first, a plain name, one-tap buying that applies immediately, and the
-- paid stats shown in gold under the free ones rather than hidden in a tab
-- (see UpgradePasses.luau for the split and why).
--
-- PAINT. Stock is the free option; the eight colours are bought once with
-- in-game money and then work on every car; the Custom Paint pass unlocks the
-- full picker. Anything can be PREVIEWED on the car for free - clicking a
-- locked colour puts it on the car and offers the purchase right under it,
-- and the picker drags live whether or not the pass is owned. Nothing is saved
-- until it is bought and applied; leaving the tab or the garage puts the
-- saved paint back. See VehiclePaint.luau.
--
-- THE TUTORIAL. Two constraints, both load-bearing:
--
--   The root frame is named TerminalPanel and the spawn button
--   SpawnVehicleButton, because TutorialGuide.client.luau finds both by name
--   (through PlayerGui.PlotTerminalGui) to dim the screen down to that one
--   button. Renaming either costs the tutorial's spotlight and nothing else.
--
--   The tutorial's banner is bottom-anchored, up to 580x106, and drawn OVER
--   this screen - so the spawn button sits at the TOP of the left panel, never
--   near the bottom edge. The right panel and the drag hint are not shown at
--   all while the tutorial runs: a player being told to press one button does
--   not need ten upgrade cards competing with the instruction.
--
-- Nothing here is a security boundary. Claiming, spawning, buying, tuning and
-- painting are all re-checked in PlotManager.server.luau.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local MarketplaceService = game:GetService("MarketplaceService")

local CustomPrompt = require(ReplicatedStorage.Modules.UI.CustomPrompt)
local ResponsiveScale = require(ReplicatedStorage.Modules.UI.ResponsiveScale)
local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)
local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)
local VehicleCatalog = require(ReplicatedStorage.Modules.Vehicles.VehicleCatalog)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleUpgrades = require(ReplicatedStorage.Modules.Vehicles.VehicleUpgrades)
local UpgradePasses = require(ReplicatedStorage.Modules.Vehicles.UpgradePasses)
local VehiclePaint = require(ReplicatedStorage.Modules.Vehicles.VehiclePaint)

local GarageStage = require(script.Parent:WaitForChild("GarageStage"))

local player = Players.LocalPlayer

local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")

local claimPlotEvent = ReplicatedStorage:WaitForChild("ClaimPlot")
local spawnVehicleEvent = ReplicatedStorage:WaitForChild("SpawnVehicle")
local selectVehicleEvent = ReplicatedStorage:WaitForChild("SelectVehicle")
local getPlotDataFunction = ReplicatedStorage:WaitForChild("GetPlotData")
local buyVehicleFunction = ReplicatedStorage:WaitForChild("BuyVehicle")
local buyUpgradeEvent = ReplicatedStorage:WaitForChild("BuyUpgrade")
local setCarConfigValueEvent = ReplicatedStorage:WaitForChild("SetCarConfigValue")
local buyPaintColorFunction = ReplicatedStorage:WaitForChild("BuyPaintColor")
local setVehiclePaintFunction = ReplicatedStorage:WaitForChild("SetVehiclePaint")
local setGarageOpenEvent = ReplicatedStorage:WaitForChild("SetGarageOpen")

--============================================================================
-- Palette
--============================================================================

-- Same dark-panel family as CustomPrompt / VehicleDashboard / DeliveryHud, so
-- this reads as one UI system. GOLD is the only addition, and it means exactly
-- one thing everywhere it appears: this costs Robux.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local CARD = Color3.fromRGB(28, 31, 38)
local CARD_HOVER = Color3.fromRGB(36, 40, 49)
local CARD_EDGE = Color3.fromRGB(44, 49, 60)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)
local LOCKED = Color3.fromRGB(48, 52, 62)
local OWNED_SEGMENT = Color3.fromRGB(78, 86, 102)
local CAUTION = Color3.fromRGB(224, 178, 84)
local GOLD = Color3.fromRGB(247, 196, 78)
local GOLD_DIM = Color3.fromRGB(122, 98, 42)

-- The side panels are slightly see-through so the bay reads as one space with
-- the car in it, rather than as a car in a letterbox.
local PANEL_TRANSPARENCY = 0.06

local LOCK_GLYPH = "\u{1F512}"
local TICK_GLYPH = "\u{2713}"

--============================================================================
-- Sound
--============================================================================

local function playSound(soundId)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	SoundService:PlayLocalSound(sound)
end

local playClaimSound, playClickSound
do
	local CLAIM_SOUND_ID = "rbxassetid://90420386076500"
	local TERMINAL_CLICK_SOUND_ID = "rbxassetid://127105730240202"

	playClaimSound = function()
		playSound(CLAIM_SOUND_ID)
	end
	playClickSound = function()
		playSound(TERMINAL_CLICK_SOUND_ID)
	end
end

--============================================================================
-- Small builders
--============================================================================

local function corner(instance, radius)
	Instance.new("UICorner", instance).CornerRadius = UDim.new(0, radius)
	return instance
end

local function stroke(instance, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = instance
	return s
end

-- Property-bag TextLabel. This file builds dozens of them and the five-line
-- Instance.new/BackgroundTransparency/Font/TextColor3/Parent preamble on each
-- one is what makes a layout hard to read out of the code.
local function label(parent, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Gotham
	l.TextColor3 = BRIGHT_TEXT
	l.Text = ""
	for key, value in props do
		l[key] = value
	end
	l.Parent = parent
	return l
end

local function button(parent, props)
	local b = Instance.new("TextButton")
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Font = Enum.Font.GothamBlack
	b.TextColor3 = PANEL
	b.BackgroundColor3 = ACCENT
	for key, value in props do
		b[key] = value
	end
	b.Parent = parent
	return b
end

local function formatMoney(amount)
	local digits = tostring(math.floor(amount or 0))
	local grouped = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if grouped:sub(1, 1) == "," then
		grouped = grouped:sub(2)
	end
	return "$" .. grouped
end

-- Set by TutorialGuide.client.luau for exactly as long as the tutorial is on
-- screen. A soft dependency: if that script never runs the attribute is nil,
-- this reads false, and the garage behaves as it does for everyone else.
local TUTORIAL_ACTIVE_ATTRIBUTE = "TutorialActive"

local function isTutorialActive()
	return player:GetAttribute(TUTORIAL_ACTIVE_ATTRIBUTE) == true
end

local function localPlayerOwnsAnyPlot()
	for _, plotModel in VehiclePlotsFolder:GetChildren() do
		if PlotOwnership.GetOwnerUserId(plotModel) == player.UserId then
			return true
		end
	end
	return false
end

--============================================================================
-- Screen and root
--============================================================================

local closeTerminal -- assigned near the bottom; spawning closes the garage

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlotTerminalGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
-- Kept OUT of Roblox's top bar, so the top-left title never sits under the
-- menu/chat buttons. Everything below lays out inside what is left.
screenGui.IgnoreGuiInset = false
screenGui.DisplayOrder = 5
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = player:WaitForChild("PlayerGui")

-- ONE uniformly scaled root, designed at 1280x720. The root's own size is
-- re-set to (screen / scale) on every resize, so after the UIScale it covers
-- exactly the screen - which means everything inside can be laid out with
-- ordinary Scale/Offset in design pixels and it lands the same on a monitor
-- and on a landscape phone (where the scale drops to ~0.55 and the design
-- canvas becomes wider than 1280, leaving more room for the car in the
-- middle rather than squashing the panels).
local DESIGN_WIDTH = 1280
local DESIGN_HEIGHT = 720
local MIN_SCALE = 0.5
local MAX_SCALE = 1.25

local root = Instance.new("Frame")
root.Name = "TerminalPanel" -- see the tutorial note in this file's header
root.BackgroundTransparency = 1
root.Size = UDim2.fromOffset(DESIGN_WIDTH, DESIGN_HEIGHT)
root.Parent = screenGui

local rootScale = Instance.new("UIScale")
rootScale.Parent = root

local function layoutRoot()
	local size = screenGui.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	local scale = math.clamp(math.min(size.X / DESIGN_WIDTH, size.Y / DESIGN_HEIGHT), MIN_SCALE, MAX_SCALE)
	rootScale.Scale = scale
	root.Size = UDim2.fromOffset(size.X / scale, size.Y / scale)
end
screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutRoot)
layoutRoot()

-- A panel swallows clicks and drags (Active), so dragging across a panel
-- scrolls or presses what is on it instead of spinning the car behind it.
local function makePanel(props)
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = PANEL
	frame.BackgroundTransparency = PANEL_TRANSPARENCY
	frame.BorderSizePixel = 0
	frame.Active = true
	for key, value in props do
		frame[key] = value
	end
	frame.Parent = root
	corner(frame, 14)
	stroke(frame, PANEL_EDGE)
	return frame
end

local MARGIN = 16
local LEFT_WIDTH = 300
-- Not a round number: it is what makes the upgrade grid land exactly - see
-- UPGRADE_CONTENT_WIDTH below.
local RIGHT_WIDTH = 364
local RIGHT_TOP = 84

--============================================================================
-- Top right: money and close
--============================================================================

local moneyLabel, deliveriesLabel
do
	local moneyPanel = makePanel({
		Size = UDim2.fromOffset(RIGHT_WIDTH - 56, 56),
		Position = UDim2.new(1, -MARGIN - 56, 0, MARGIN),
		AnchorPoint = Vector2.new(1, 0),
	})

	-- Money is the biggest number on the screen on purpose. It is the one thing a
	-- child checks before deciding whether any of this is for them right now.
	moneyLabel = label(moneyPanel, {
		Size = UDim2.new(1, -24, 0, 30),
		Position = UDim2.fromOffset(12, 4),
		Font = Enum.Font.GothamBlack,
		TextSize = 26,
		TextColor3 = ACCENT,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "$0",
	})

	-- Quieter: locked cars say "20 deliveries to go", so the player's own count
	-- has to appear somewhere for that to mean anything.
	deliveriesLabel = label(moneyPanel, {
		Size = UDim2.new(1, -24, 0, 16),
		Position = UDim2.fromOffset(12, 34),
		TextSize = 13,
		TextColor3 = DIM_TEXT,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
end

local closeButton = button(root, {
	Size = UDim2.fromOffset(48, 48),
	Position = UDim2.new(1, -MARGIN, 0, MARGIN + 4),
	AnchorPoint = Vector2.new(1, 0),
	BackgroundColor3 = PANEL,
	BackgroundTransparency = PANEL_TRANSPARENCY,
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	TextColor3 = BRIGHT_TEXT,
	Text = "X",
	AutoButtonColor = true,
})
corner(closeButton, 12)
stroke(closeButton, PANEL_EDGE)

--============================================================================
-- Left panel: the car being looked at, its action, and the vehicle list
--============================================================================

local leftPanel = makePanel({
	Name = "LeftPanel",
	Size = UDim2.new(0, LEFT_WIDTH, 1, -MARGIN * 2),
	Position = UDim2.fromOffset(MARGIN, MARGIN),
})

label(leftPanel, {
	Size = UDim2.new(1, -32, 0, 16),
	Position = UDim2.fromOffset(16, 14),
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = DIM_TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "MY GARAGE",
})

local vehicleNameLabel = label(leftPanel, {
	Size = UDim2.new(1, -32, 0, 30),
	Position = UDim2.fromOffset(16, 30),
	Font = Enum.Font.GothamBlack,
	TextSize = 24,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Text = "--",
})

local vehicleStatusLabel = label(leftPanel, {
	Size = UDim2.new(1, -32, 0, 18),
	Position = UDim2.fromOffset(16, 60),
	TextSize = 13,
	TextColor3 = DIM_TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
})

-- The one big button: SPAWN for a car you own, BUY for one you don't. Near
-- the top of the screen on purpose - see the tutorial note in the header.
local actionButton = button(leftPanel, {
	Name = "SpawnVehicleButton", -- see the tutorial note in the header
	Size = UDim2.new(1, -32, 0, 50),
	Position = UDim2.fromOffset(16, 86),
	TextSize = 19,
	Text = "SPAWN VEHICLE",
})
corner(actionButton, 12)

-- Spawning REPLACES whatever is parked here, and a truck carrying a contract
-- takes the contract with it - the crates are welded into that bed. That is the
-- intended rule, but it costs a contract slot, so it gets said BEFORE the click
-- rather than explained after it. Driven off the attribute DeliveryManager
-- mirrors onto the Player.
local ACTIVE_CONTRACT_ATTRIBUTE = "ActiveContractStop"

local contractWarning = label(leftPanel, {
	Size = UDim2.new(1, -32, 0, 30),
	Position = UDim2.fromOffset(16, 140),
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = CAUTION,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextWrapped = true,
	Visible = false,
})

local LIST_TOP = 176

label(leftPanel, {
	Size = UDim2.new(1, -32, 0, 16),
	Position = UDim2.fromOffset(16, LIST_TOP),
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = DIM_TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "VEHICLES",
})

local vehicleList = Instance.new("ScrollingFrame")
vehicleList.Name = "VehicleList"
vehicleList.Size = UDim2.new(1, -20, 1, -(LIST_TOP + 30))
vehicleList.Position = UDim2.fromOffset(12, LIST_TOP + 22)
vehicleList.BackgroundTransparency = 1
vehicleList.BorderSizePixel = 0
vehicleList.ScrollBarThickness = 6
vehicleList.ScrollBarImageColor3 = OWNED_SEGMENT
vehicleList.CanvasSize = UDim2.new()
vehicleList.AutomaticCanvasSize = Enum.AutomaticSize.Y
vehicleList.Parent = leftPanel

do
	local vehicleListLayout = Instance.new("UIListLayout", vehicleList)
	vehicleListLayout.Padding = UDim.new(0, 8)
	vehicleListLayout.SortOrder = Enum.SortOrder.LayoutOrder

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 4)
	padding.PaddingRight = UDim.new(0, 12)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.Parent = vehicleList
end

--============================================================================
-- Right panel: Upgrades / Paint for a car you own, shop info for one you don't
--============================================================================

local rightPanel = makePanel({
	Name = "RightPanel",
	Size = UDim2.new(0, RIGHT_WIDTH, 1, -(RIGHT_TOP + MARGIN)),
	Position = UDim2.new(1, -MARGIN, 0, RIGHT_TOP),
	AnchorPoint = Vector2.new(1, 0),
})

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -24, 0, 38)
tabBar.Position = UDim2.fromOffset(12, 12)
tabBar.BackgroundTransparency = 1
tabBar.Parent = rightPanel

do
	local tabLayout = Instance.new("UIListLayout", tabBar)
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
end

-- EVERY UIStroke IN THIS SCREEN DRAWS OUTSIDE ITS FRAME, and a ScrollingFrame
-- clips its descendants - so a card flush at x=0 loses the left half of its
-- outline. Both scroll canvases get 4px on the left for the stroke to live in,
-- and 12px on the right for the stroke plus the scrollbar.
local SCROLL_PAD_LEFT = 4
local SCROLL_PAD_RIGHT = 12
local SCROLL_WIDTH = RIGHT_WIDTH - 24
local UPGRADE_CONTENT_WIDTH = SCROLL_WIDTH - SCROLL_PAD_LEFT - SCROLL_PAD_RIGHT

local function makeRightScroll()
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(0, SCROLL_WIDTH, 1, -74)
	scroll.Position = UDim2.fromOffset(12, 62)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	-- Brighter than PANEL_EDGE, which on a CARD is nearly invisible - and the
	-- scrollbar is the only hint that there is more below.
	scroll.ScrollBarImageColor3 = OWNED_SEGMENT
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Visible = false
	scroll.Parent = rightPanel

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, SCROLL_PAD_LEFT)
	padding.PaddingRight = UDim.new(0, SCROLL_PAD_RIGHT)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.Parent = scroll

	local layout = Instance.new("UIListLayout", scroll)
	layout.Padding = UDim.new(0, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	return scroll
end

local upgradesScroll = makeRightScroll()
local paintScroll = makeRightScroll()
paintScroll.Name = "PaintPage"
upgradesScroll.Name = "UpgradesPage"

local rightTabs = {} -- [name] = { Button, Page }
local activeRightTab = "Upgrades"
local onLeavePaintTab -- assigned in the paint section

local function showRightTab(name)
	if activeRightTab == "Paint" and name ~= "Paint" and onLeavePaintTab then
		onLeavePaintTab()
	end
	activeRightTab = name
	for tabName, entry in rightTabs do
		local isActive = tabName == name
		entry.Page.Visible = isActive
		entry.Button.BackgroundColor3 = if isActive then ACCENT else CARD
		entry.Button.TextColor3 = if isActive then PANEL else DIM_TEXT
	end
end

local function addRightTab(name, page, order)
	local tab = button(tabBar, {
		Name = name .. "Tab",
		Size = UDim2.new(0.5, -4, 1, 0),
		BackgroundColor3 = CARD,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = DIM_TEXT,
		Text = name,
		LayoutOrder = order,
	})
	corner(tab, 10)
	rightTabs[name] = { Button = tab, Page = page }
	tab.MouseButton1Click:Connect(function()
		if activeRightTab ~= name then
			playClickSound()
			showRightTab(name)
		end
	end)
end

addRightTab("Upgrades", upgradesScroll, 1)
addRightTab("Paint", paintScroll, 2)

-- Shown in place of the tabs for a car the player does not own yet.
local shopInfo = Instance.new("Frame")
shopInfo.Size = UDim2.new(1, -24, 1, -24)
shopInfo.Position = UDim2.fromOffset(12, 12)
shopInfo.BackgroundTransparency = 1
shopInfo.Visible = false
shopInfo.Parent = rightPanel

label(shopInfo, {
	Size = UDim2.new(1, 0, 0, 16),
	Position = UDim2.fromOffset(4, 4),
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = DIM_TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "FOR SALE",
})

local shopPriceLabel = label(shopInfo, {
	Size = UDim2.new(1, -8, 0, 40),
	Position = UDim2.fromOffset(4, 22),
	Font = Enum.Font.GothamBlack,
	TextSize = 34,
	TextColor3 = ACCENT,
	TextXAlignment = Enum.TextXAlignment.Left,
})

local shopRequirementLabel = label(shopInfo, {
	Size = UDim2.new(1, -8, 0, 40),
	Position = UDim2.fromOffset(4, 66),
	Font = Enum.Font.GothamBold,
	TextSize = 15,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
})

label(shopInfo, {
	Size = UDim2.new(1, -8, 0, 60),
	Position = UDim2.fromOffset(4, 112),
	TextSize = 14,
	TextColor3 = DIM_TEXT,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextWrapped = true,
	Text = "Buy it to upgrade it and paint it any colour you own. Drag the car to look around it.",
})

-- Bottom middle, under the car. Hidden during the tutorial, whose banner sits
-- exactly here.
local dragHint = label(root, {
	Size = UDim2.fromOffset(360, 24),
	Position = UDim2.new(0.5, 0, 1, -MARGIN),
	AnchorPoint = Vector2.new(0.5, 1),
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextColor3 = BRIGHT_TEXT,
	TextStrokeTransparency = 0.6,
	TextTransparency = 0.2,
	Text = if UserInputService.TouchEnabled and not UserInputService.MouseEnabled
		then "Drag to turn  \u{2022}  Pinch to zoom"
		else "Drag to turn  \u{2022}  Scroll to zoom",
})

--============================================================================
-- Info modal - the (i) on each upgrade card
--============================================================================

local infoModal = Instance.new("Frame")
infoModal.Size = UDim2.fromScale(1, 1)
infoModal.BackgroundTransparency = 1
infoModal.Visible = false
infoModal.ZIndex = 10
infoModal.Parent = screenGui

local hideInfoModal, showInfoModal
do
	local infoBackdrop = Instance.new("TextButton")
	infoBackdrop.Size = UDim2.fromScale(1, 1)
	infoBackdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	infoBackdrop.BackgroundTransparency = 0.5
	infoBackdrop.BorderSizePixel = 0
	infoBackdrop.AutoButtonColor = false
	infoBackdrop.Text = ""
	infoBackdrop.ZIndex = 10
	infoBackdrop.Parent = infoModal

	local infoPanel = Instance.new("Frame")
	infoPanel.Size = UDim2.fromOffset(400, 300)
	infoPanel.Position = UDim2.fromScale(0.5, 0.5)
	infoPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	infoPanel.BackgroundColor3 = PANEL
	infoPanel.BorderSizePixel = 0
	infoPanel.ZIndex = 11
	infoPanel.Parent = infoModal
	ResponsiveScale.Fit(infoPanel, { Margin = 16 })
	corner(infoPanel, 14)
	stroke(infoPanel, PANEL_EDGE)

	-- The card's icon again, bigger. This modal is the one place a player who
	-- cannot read the card's name gets a second, larger look at what it is.
	local infoIcon = Instance.new("ImageLabel")
	infoIcon.Size = UDim2.fromOffset(88, 88)
	infoIcon.Position = UDim2.fromOffset(20, 20)
	infoIcon.BackgroundTransparency = 1
	infoIcon.ScaleType = Enum.ScaleType.Fit
	infoIcon.ZIndex = 11
	infoIcon.Parent = infoPanel

	local infoTitle = label(infoPanel, {
		Size = UDim2.new(1, -160, 0, 34),
		Position = UDim2.fromOffset(120, 44),
		Font = Enum.Font.GothamBlack,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 11,
	})

	local infoCloseButton = button(infoPanel, {
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(1, -46, 0, 16),
		BackgroundColor3 = CARD,
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextColor3 = BRIGHT_TEXT,
		Text = "X",
		ZIndex = 12,
	})
	corner(infoCloseButton, 8)

	-- The one block of real prose on the screen, aimed at someone still learning
	-- to read - bright and 16px, not dim decoration.
	local infoDescription = label(infoPanel, {
		Size = UDim2.new(1, -40, 1, -124),
		Position = UDim2.fromOffset(20, 108),
		TextSize = 16,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		ZIndex = 11,
	})

	hideInfoModal = function()
		infoModal.Visible = false
	end

	showInfoModal = function(titleText, description, iconId)
		local hasIcon = type(iconId) == "string" and iconId ~= ""
		infoIcon.Image = if hasIcon then iconId else ""
		infoIcon.Visible = hasIcon
		infoTitle.Text = titleText
		infoTitle.Position = if hasIcon then UDim2.fromOffset(120, 44) else UDim2.fromOffset(20, 40)
		infoDescription.Text = if description ~= "" then description else "No description available for this upgrade yet."
		infoModal.Visible = true
	end

	infoBackdrop.Activated:Connect(function()
		playClickSound()
		hideInfoModal()
	end)
	infoCloseButton.MouseButton1Click:Connect(function()
		playClickSound()
		hideInfoModal()
	end)
end

--============================================================================
-- State
--============================================================================

local latestData = nil -- last GetPlotData result
local viewedVehicleId = nil -- the car parked on the stage right now

-- Forward-declared: buy/tune/paint handlers re-render after a remote returns,
-- and rendering is what wires those handlers up.
local refreshTerminalData
local renderAll

local function ownsVehicle(data, vehicleId)
	for _, id in data.OwnedVehicleIds do
		if id == vehicleId then
			return true
		end
	end
	return false
end

local function savedPaintFor(data, vehicleId)
	return VehiclePaint.Sanitize((data.VehiclePaint or {})[vehicleId])
end

--============================================================================
-- Upgrade cards
--============================================================================

-- Two across in the right panel. CARD_WIDTH is derived from the panel, not
-- chosen, and asserted rather than trusted: a card a pixel too wide silently
-- wraps every row to one card and doubles the length of the scroll.
local GRID_COLUMNS = 2
local CARD_PADDING = 16
local CARD_WIDTH = 154
local ICON_SIZE = 76
local CARD_HEIGHT = 190
local SEGMENT_GAP = 3
local SEGMENT_INSET = 72 -- the two 28px tune arrows plus their margins

assert(GRID_COLUMNS * CARD_WIDTH + (GRID_COLUMNS - 1) * CARD_PADDING == UPGRADE_CONTENT_WIDTH,
	"upgrade grid no longer fills the right panel exactly - re-derive RIGHT_WIDTH from CARD_WIDTH")

-- Card interior, top to bottom. Named because these only mean anything
-- relative to each other.
local ICON_TOP = 10
local NAME_TOP = ICON_TOP + ICON_SIZE + 4
local TUNE_ROW_TOP = NAME_TOP + 26
local BAR_TOP = TUNE_ROW_TOP + 6
local BUTTON_TOP = TUNE_ROW_TOP + 34

-- Falls back to splitting the PascalCase config key if a stat has no
-- DisplayName, so a stat added to a Configs file and not yet named shows as
-- "Brake Friction" rather than as nothing at all.
local function statDisplayName(statName, spec)
	if type(spec.DisplayName) == "string" and spec.DisplayName ~= "" then
		return spec.DisplayName
	end
	return (statName:gsub("(%l)(%u)", "%1 %2"))
end

local function makeGridSection(layoutOrder)
	local section = Instance.new("Frame")
	section.BackgroundTransparency = 1
	section.Size = UDim2.new(1, 0, 0, 0)
	section.AutomaticSize = Enum.AutomaticSize.Y
	section.LayoutOrder = layoutOrder
	section.Parent = upgradesScroll
	local grid = Instance.new("UIGridLayout", section)
	grid.CellSize = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	grid.CellPadding = UDim2.fromOffset(CARD_PADDING, CARD_PADDING)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.FillDirectionMaxCells = GRID_COLUMNS
	return section
end

-- One block per buyable level. This is the level counter, the current setting
-- and the "there is more to buy" hint all at once, with no number anywhere:
-- green = turned on right now, grey = bought but turned down, dark = not bought
-- yet.
local function buildSegmentBar(parent, maxLevel, unlockedLevel, currentLevel, isLocked)
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, -SEGMENT_INSET, 0, 16)
	bar.Position = UDim2.fromOffset(36, BAR_TOP)
	bar.BackgroundTransparency = 1
	bar.Parent = parent

	local layout = Instance.new("UIListLayout", bar)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, SEGMENT_GAP)
	layout.VerticalAlignment = Enum.VerticalAlignment.Center

	-- A stat with no levels has nothing to show and would divide by zero below.
	if maxLevel <= 0 then
		return bar
	end

	local usable = (CARD_WIDTH - SEGMENT_INSET) - SEGMENT_GAP * (maxLevel - 1)
	local segmentWidth = math.max(3, math.floor(usable / maxLevel))

	for level = 1, maxLevel do
		local segment = Instance.new("Frame")
		segment.Size = UDim2.fromOffset(segmentWidth, 16)
		segment.BorderSizePixel = 0
		segment.LayoutOrder = level
		if isLocked then
			segment.BackgroundColor3 = GOLD_DIM
			segment.BackgroundTransparency = 0.55
		elseif level <= currentLevel then
			segment.BackgroundColor3 = ACCENT
		elseif level <= unlockedLevel then
			segment.BackgroundColor3 = OWNED_SEGMENT
		else
			segment.BackgroundColor3 = LOCKED
		end
		segment.Parent = bar
		corner(segment, 3)
	end
	return bar
end

-- Every locked upgrade surface routes here rather than calling
-- MarketplaceService itself, so there is one place that knows what happens when
-- a player asks to unlock something.
local function promptUpgradePass(vehicleId)
	local passId = UpgradePasses.PassIdFor(vehicleId)
	if not passId then
		return
	end
	playClickSound()
	MarketplaceService:PromptGamePassPurchase(player, passId)
end

local function makeUpgradeCard(section, vehicleId, statName, spec, unlockedLevel, currentValue, ownsPass, layoutOrder)
	local maxLevel = VehicleUpgrades.MaxLevel(spec)
	local currentLevel = VehicleUpgrades.ClampLevel(spec, math.round((currentValue - spec.Min) / spec.Step))
	-- THREE STATES, not two, and they are easy to collapse by accident.
	--
	-- passTerritory - a gated stat this player has no pass for. Drawn gold
	-- whatever else is true of it, because gold is what says "this one is
	-- behind the pass".
	--
	-- passLocked - passTerritory AND nothing bought in it yet. No controls at
	-- all: padlock, faded icon, UNLOCK, and no price, because money is not
	-- what is standing in the way and showing one would be a lie.
	--
	-- passTerritory but NOT passLocked - the grandfathered case. Levels bought
	-- with in-game money before the pass existed, so the arrows still work;
	-- only buying MORE is shut off. The server agrees on exactly this split -
	-- see UpgradePasses.CanTune and CanBuy.
	local passTerritory = UpgradePasses.IsGated(statName) and not ownsPass
	local passLocked = passTerritory and not UpgradePasses.CanTune(statName, ownsPass, unlockedLevel)
	local canBuy = UpgradePasses.CanBuy(statName, ownsPass)
	local displayName = statDisplayName(statName, spec)

	local card = Instance.new("Frame")
	card.Name = statName
	card.BackgroundColor3 = CARD
	card.BorderSizePixel = 0
	card.LayoutOrder = layoutOrder
	card.Parent = section
	corner(card, 12)
	stroke(card, if passTerritory then GOLD_DIM else CARD_EDGE, if passTerritory then 2 else 1)

	local icon = Instance.new("ImageLabel")
	icon.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
	icon.Position = UDim2.new(0.5, 0, 0, ICON_TOP)
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.BackgroundTransparency = 1
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Image = spec.IconId or ""
	-- Faded, not hidden. On a locked card the picture IS the pitch.
	icon.ImageTransparency = if passLocked then 0.45 else 0
	icon.Parent = card

	if passLocked then
		label(icon, {
			Size = UDim2.fromOffset(30, 30),
			Position = UDim2.new(1, 0, 1, 0),
			AnchorPoint = Vector2.new(1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 21,
			TextColor3 = GOLD,
			Text = LOCK_GLYPH,
			ZIndex = 3,
		})
	end

	label(card, {
		Size = UDim2.new(1, -12, 0, 22),
		Position = UDim2.fromOffset(6, NAME_TOP),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextColor3 = if passTerritory then GOLD else BRIGHT_TEXT,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = displayName,
	})

	-- The (i) is the only place the jargon-free name is expanded into a
	-- sentence, so it sits on every card including locked ones.
	local infoButton = button(card, {
		Size = UDim2.fromOffset(20, 20),
		Position = UDim2.new(1, -26, 0, 6),
		BackgroundColor3 = PANEL,
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		TextColor3 = DIM_TEXT,
		Text = "i",
		ZIndex = 4,
	})
	corner(infoButton, 10)
	infoButton.MouseEnter:Connect(function()
		infoButton.BackgroundColor3 = ACCENT
		infoButton.TextColor3 = PANEL
	end)
	infoButton.MouseLeave:Connect(function()
		infoButton.BackgroundColor3 = PANEL
		infoButton.TextColor3 = DIM_TEXT
	end)
	infoButton.MouseButton1Click:Connect(function()
		playClickSound()
		showInfoModal(displayName, spec.Description or "", spec.IconId)
	end)

	buildSegmentBar(card, maxLevel, unlockedLevel, currentLevel, passLocked)

	-- Locked by the pass: the whole card is one button that asks for it.
	if passLocked then
		local unlockButton = button(card, {
			Size = UDim2.new(1, -16, 0, 32),
			Position = UDim2.fromOffset(8, BUTTON_TOP),
			BackgroundColor3 = GOLD,
			TextSize = 14,
			Text = "UNLOCK",
			ZIndex = 3,
		})
		corner(unlockButton, 8)
		unlockButton.MouseButton1Click:Connect(function()
			promptUpgradePass(vehicleId)
		end)

		-- The card body too, not only the button. A child who taps the padlock
		-- or the picture means the same thing as one who taps the word.
		local cardHit = Instance.new("TextButton")
		cardHit.Size = UDim2.new(1, 0, 0, BUTTON_TOP - 6)
		cardHit.BackgroundTransparency = 1
		cardHit.AutoButtonColor = false
		cardHit.Text = ""
		cardHit.ZIndex = 2
		cardHit.Parent = card
		cardHit.MouseButton1Click:Connect(function()
			promptUpgradePass(vehicleId)
		end)
		return
	end

	-- Tuning arrows. Secondary by design: buying already applies the new
	-- level, so these only ever turn an upgrade the player already owns DOWN
	-- and back up - which a fragile load over bad ground genuinely wants.
	local function setLevel(newLevel)
		local clamped = math.clamp(newLevel, 0, unlockedLevel)
		if clamped == currentLevel then
			return
		end
		-- InvokeServer, not FireServer, so the tune is guaranteed applied
		-- before refreshTerminalData reads it back.
		setCarConfigValueEvent:InvokeServer(vehicleId, statName, VehicleUpgrades.ValueAtLevel(spec, clamped))
		refreshTerminalData()
	end

	local function makeTuneArrow(text, xOffset, delta)
		local enabled = unlockedLevel > 0
			and ((delta < 0 and currentLevel > 0) or (delta > 0 and currentLevel < unlockedLevel))
		local arrow = button(card, {
			Size = UDim2.fromOffset(28, 28),
			Position = UDim2.fromOffset(xOffset, TUNE_ROW_TOP),
			BackgroundColor3 = if enabled then PANEL else CARD,
			AutoButtonColor = enabled,
			Font = Enum.Font.GothamBold,
			TextSize = 18,
			TextColor3 = if enabled then BRIGHT_TEXT else OWNED_SEGMENT,
			Text = text,
		})
		corner(arrow, 14)
		if enabled then
			arrow.MouseButton1Click:Connect(function()
				playClickSound()
				setLevel(currentLevel + delta)
			end)
		end
	end

	makeTuneArrow("-", 6, -1)
	makeTuneArrow("+", CARD_WIDTH - 34, 1)

	local buyButton = button(card, {
		Size = UDim2.new(1, -16, 0, 32),
		Position = UDim2.fromOffset(8, BUTTON_TOP),
		TextSize = 14,
		BackgroundColor3 = LOCKED,
		TextColor3 = DIM_TEXT,
	})
	corner(buyButton, 8)

	if unlockedLevel >= maxLevel then
		buyButton.Text = "MAXED"
		return
	end

	-- Reachable only for a grandfathered gated stat.
	if not canBuy then
		buyButton.Text = "NEEDS PASS"
		buyButton.TextColor3 = GOLD
		buyButton.AutoButtonColor = true
		buyButton.MouseButton1Click:Connect(function()
			promptUpgradePass(vehicleId)
		end)
		return
	end

	local cost = VehicleUpgrades.CostForLevel(spec, unlockedLevel + 1)
	buyButton.Text = formatMoney(cost)

	if (latestData and latestData.Money or 0) < cost then
		-- No click handler at all: the server would refuse it anyway.
		return
	end

	buyButton.BackgroundColor3 = ACCENT
	buyButton.TextColor3 = PANEL
	buyButton.AutoButtonColor = true
	buyButton.MouseButton1Click:Connect(function()
		playClickSound()
		local bought = buyUpgradeEvent:InvokeServer(vehicleId, statName)
		if bought then
			-- Buying applies the new level immediately, so a child's first
			-- purchase visibly does something. The arrows are how you undo
			-- it, not how you complete it.
			setCarConfigValueEvent:InvokeServer(vehicleId, statName, VehicleUpgrades.ValueAtLevel(spec, unlockedLevel + 1))
		end
		refreshTerminalData()
	end)
end

-- The gold divider between the free upgrades and the paid ones. Stacked
-- (title over button) because the right panel is narrower than the old
-- terminal was.
local function makePassBanner(vehicleId, ownsPass, layoutOrder)
	local banner = Instance.new("Frame")
	banner.Size = UDim2.new(1, 0, 0, if ownsPass then 64 else 108)
	banner.BackgroundColor3 = CARD
	banner.BorderSizePixel = 0
	banner.LayoutOrder = layoutOrder
	banner.Parent = upgradesScroll
	corner(banner, 12)
	stroke(banner, if ownsPass then ACCENT else GOLD, 2)

	label(banner, {
		Size = UDim2.fromOffset(40, 60),
		Position = UDim2.fromOffset(8, 2),
		Font = Enum.Font.GothamBold,
		TextSize = 24,
		TextColor3 = if ownsPass then ACCENT else GOLD,
		Text = if ownsPass then TICK_GLYPH else LOCK_GLYPH,
	})

	label(banner, {
		Size = UDim2.new(1, -60, 0, 22),
		Position = UDim2.fromOffset(50, 10),
		Font = Enum.Font.GothamBlack,
		TextSize = 16,
		TextColor3 = if ownsPass then ACCENT else GOLD,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = if ownsPass
			then string.upper(UpgradePasses.DisplayName) .. " - UNLOCKED"
			else string.upper(UpgradePasses.DisplayName),
	})

	-- Says WHAT it does, not what it is - a promise a child can check against
	-- the gold cards directly underneath.
	label(banner, {
		Size = UDim2.new(1, -60, 0, 20),
		Position = UDim2.fromOffset(50, 32),
		TextSize = 13,
		TextColor3 = DIM_TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Text = if ownsPass
			then "Every upgrade on this vehicle is yours to buy."
			else "Unlock more upgrades for this vehicle.",
	})

	if ownsPass then
		return
	end

	local getButton = button(banner, {
		Size = UDim2.new(1, -24, 0, 38),
		Position = UDim2.fromOffset(12, 60),
		BackgroundColor3 = GOLD,
		TextSize = 16,
		Text = "GET IT",
		AutoButtonColor = true,
	})
	corner(getButton, 10)
	getButton.MouseButton1Click:Connect(function()
		promptUpgradePass(vehicleId)
	end)
end

-- Reading order within each half, most immediately understandable first.
local FREE_ORDER = { "Torque", "CargoCapacity", "BodyStrength", "SteerAngle" }
local PAID_ORDER = { "MaxSpeed", "BrakeFriction", "TractionSlipThreshold", "Stiffness", "Damper", "SuspensionMaxLength" }

-- Anything a Configs file adds later still appears, at the end of whichever
-- half UpgradePasses says it belongs to, alphabetically.
local function orderedStats(specs, preferred, gatedHalf)
	local seen = {}
	local ordered = {}
	for _, statName in preferred do
		if specs[statName] and UpgradePasses.IsGated(statName) == gatedHalf then
			table.insert(ordered, statName)
			seen[statName] = true
		end
	end
	local extras = {}
	for statName in specs do
		if not seen[statName] and UpgradePasses.IsGated(statName) == gatedHalf then
			table.insert(extras, statName)
		end
	end
	table.sort(extras)
	for _, statName in extras do
		table.insert(ordered, statName)
	end
	return ordered
end

local function clearChildren(container)
	for _, child in container:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function renderUpgrades(data, vehicleId)
	clearChildren(upgradesScroll)
	local def = VehicleCatalog.Get(vehicleId)
	local specs = def and VehiclePhysics.GetUpgradeSpecs(def.TemplateName)
	if not specs then
		label(upgradesScroll, {
			Size = UDim2.new(1, 0, 0, 40),
			TextSize = 14,
			TextColor3 = DIM_TEXT,
			Text = "This vehicle has no upgrades yet.",
		})
		return
	end

	local levels = data.UpgradeLevels[vehicleId] or {}
	local configValues = data.CarConfigs[vehicleId] or {}
	-- The server's answer, carried on the same round trip.
	local ownsPass = (data.UpgradePassOwned or {})[vehicleId] == true

	local function addCards(section, statNames)
		for index, statName in statNames do
			local spec = specs[statName]
			makeUpgradeCard(
				section,
				vehicleId,
				statName,
				spec,
				VehicleUpgrades.ClampLevel(spec, levels[statName] or 0),
				configValues[statName] or spec.Min,
				ownsPass,
				index
			)
		end
	end

	addCards(makeGridSection(1), orderedStats(specs, FREE_ORDER, false))

	local paidStats = orderedStats(specs, PAID_ORDER, true)
	if #paidStats == 0 then
		return -- a car with no gated stats has no pass to sell
	end
	makePassBanner(vehicleId, ownsPass, 2)
	addCards(makeGridSection(3), paidStats)
end

--============================================================================
-- Paint tab
--============================================================================

-- What is on the car right now, which may be a colour being tried on rather
-- than the saved one. `nil` = stock.
local previewPaint = nil

local function isPreviewing(data)
	return previewPaint ~= savedPaintFor(data, viewedVehicleId)
end

local function revertPreview()
	if latestData and viewedVehicleId then
		previewPaint = savedPaintFor(latestData, viewedVehicleId)
		GarageStage.SetPaint(previewPaint)
	end
end

onLeavePaintTab = revertPreview

local function sectionLabel(parent, text, order)
	return label(parent, {
		Size = UDim2.new(1, 0, 0, 16),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = DIM_TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		LayoutOrder = order,
	})
end

sectionLabel(paintScroll, "COLOURS", 1)

-- 5 x 56 + 4 x 11 == 324 == UPGRADE_CONTENT_WIDTH.
local SWATCH_SIZE = 56
local SWATCH_GAP = 11

local swatchGrid = Instance.new("Frame")
swatchGrid.Name = "Swatches"
swatchGrid.BackgroundTransparency = 1
swatchGrid.Size = UDim2.new(1, 0, 0, 0)
swatchGrid.AutomaticSize = Enum.AutomaticSize.Y
swatchGrid.LayoutOrder = 2
swatchGrid.Parent = paintScroll

-- The purchase for a colour being tried on. Only visible while previewing a
-- colour the player does not own.
local buyBar = Instance.new("Frame")
buyBar.Size = UDim2.new(1, 0, 0, 56)
buyBar.BackgroundColor3 = CARD
buyBar.BorderSizePixel = 0
buyBar.LayoutOrder = 3
buyBar.Visible = false
buyBar.Parent = paintScroll
corner(buyBar, 12)
stroke(buyBar, ACCENT, 1)

local buyBarSwatch = Instance.new("Frame")
buyBarSwatch.Size = UDim2.fromOffset(32, 32)
buyBarSwatch.Position = UDim2.fromOffset(12, 12)
buyBarSwatch.BorderSizePixel = 0
buyBarSwatch.Parent = buyBar
corner(buyBarSwatch, 8)

local buyBarName = label(buyBar, {
	Size = UDim2.new(1, -190, 1, 0),
	Position = UDim2.fromOffset(54, 0),
	Font = Enum.Font.GothamBold,
	TextSize = 16,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
})

local buyBarButton = button(buyBar, {
	Name = "BuyPaintButton",
	Size = UDim2.fromOffset(124, 38),
	Position = UDim2.new(1, -10, 0.5, 0),
	AnchorPoint = Vector2.new(1, 0.5),
	TextSize = 15,
})
corner(buyBarButton, 10)

sectionLabel(paintScroll, "CUSTOM COLOUR", 4)

local renderPaint -- forward: swatches, buy bar and apply button

-- The palette pass for the car being looked at, or nil if that car has no
-- pass created yet. Per car, like the tuning pass.
local function customPassId()
	return viewedVehicleId and VehiclePaint.CustomPaintPassIdFor(viewedVehicleId)
end

local function ownsCustomPaint(data)
	return viewedVehicleId ~= nil and (data.CustomPaintOwned or {})[viewedVehicleId] == true
end

local function commitPaint(value)
	local vehicleId = viewedVehicleId
	if not vehicleId then
		return
	end
	local ok = setVehiclePaintFunction:InvokeServer(vehicleId, value)
	if ok and latestData and viewedVehicleId == vehicleId then
		latestData.VehiclePaint = latestData.VehiclePaint or {}
		latestData.VehiclePaint[vehicleId] = value
		previewPaint = value
		GarageStage.SetPaint(value)
		renderAll()
	end
end

local function tryOnPaint(value)
	previewPaint = value
	GarageStage.SetPaint(value)
	renderPaint()
end

local customChipStroke, applyCustomButton, setPickerFromValue, cancelPickerDrag
do
	-- The picker. Built once and kept (not rebuilt on every render) so a redraw
	-- can never cut a drag off halfway.
	local customSection = Instance.new("Frame")
	customSection.BackgroundTransparency = 1
	customSection.Size = UDim2.new(1, 0, 0, 262)
	customSection.LayoutOrder = 5
	customSection.Parent = paintScroll

	local PICKER_HEIGHT = 150
	local HUE_HEIGHT = 22

	local satValBox = Instance.new("Frame")
	satValBox.Size = UDim2.new(1, 0, 0, PICKER_HEIGHT)
	satValBox.BackgroundColor3 = Color3.fromHSV(0, 1, 1)
	satValBox.BorderSizePixel = 0
	satValBox.Active = true
	satValBox.Parent = customSection
	corner(satValBox, 10)

	-- White fading out left-to-right over the hue, then black fading in
	-- top-to-bottom over that: the standard saturation/value square.
	do
		local white = Instance.new("Frame")
		white.Size = UDim2.fromScale(1, 1)
		white.BackgroundColor3 = Color3.new(1, 1, 1)
		white.BorderSizePixel = 0
		white.Parent = satValBox
		corner(white, 10)
		local whiteGradient = Instance.new("UIGradient")
		whiteGradient.Transparency = NumberSequence.new(0, 1)
		whiteGradient.Parent = white

		local black = Instance.new("Frame")
		black.Size = UDim2.fromScale(1, 1)
		black.BackgroundColor3 = Color3.new(0, 0, 0)
		black.BorderSizePixel = 0
		black.Parent = satValBox
		corner(black, 10)
		local blackGradient = Instance.new("UIGradient")
		blackGradient.Rotation = 90
		blackGradient.Transparency = NumberSequence.new(1, 0)
		blackGradient.Parent = black
	end

	local satValKnob = Instance.new("Frame")
	satValKnob.Size = UDim2.fromOffset(18, 18)
	satValKnob.AnchorPoint = Vector2.new(0.5, 0.5)
	satValKnob.BackgroundTransparency = 1
	satValKnob.ZIndex = 3
	satValKnob.Parent = satValBox
	corner(satValKnob, 9)
	stroke(satValKnob, Color3.new(1, 1, 1), 3)

	local hueBar = Instance.new("Frame")
	hueBar.Size = UDim2.new(1, 0, 0, HUE_HEIGHT)
	hueBar.Position = UDim2.fromOffset(0, PICKER_HEIGHT + 10)
	hueBar.BackgroundColor3 = Color3.new(1, 1, 1)
	hueBar.BorderSizePixel = 0
	hueBar.Active = true
	hueBar.Parent = customSection
	corner(hueBar, 8)

	do
		local keypoints = {}
		for i = 0, 6 do
			table.insert(keypoints, ColorSequenceKeypoint.new(i / 6, Color3.fromHSV((i / 6) % 1, 1, 1)))
		end
		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new(keypoints)
		gradient.Parent = hueBar
	end

	local hueKnob = Instance.new("Frame")
	hueKnob.Size = UDim2.new(0, 8, 1, 8)
	hueKnob.AnchorPoint = Vector2.new(0.5, 0.5)
	hueKnob.Position = UDim2.fromScale(0, 0.5)
	hueKnob.BackgroundColor3 = Color3.new(1, 1, 1)
	hueKnob.BorderSizePixel = 0
	hueKnob.ZIndex = 3
	hueKnob.Parent = hueBar
	corner(hueKnob, 4)
	stroke(hueKnob, PANEL, 2)

	local customRow = Instance.new("Frame")
	customRow.Size = UDim2.new(1, 0, 0, 70)
	customRow.Position = UDim2.fromOffset(0, PICKER_HEIGHT + HUE_HEIGHT + 20)
	customRow.BackgroundTransparency = 1
	customRow.Parent = customSection

	local customChip = Instance.new("Frame")
	customChip.Size = UDim2.fromOffset(40, 40)
	customChip.Position = UDim2.fromOffset(0, 0)
	customChip.BorderSizePixel = 0
	customChip.Parent = customRow
	corner(customChip, 10)
	customChipStroke = stroke(customChip, PANEL_EDGE, 2)

	local customHexLabel = label(customRow, {
		Size = UDim2.new(1, -52, 0, 40),
		Position = UDim2.fromOffset(52, 0),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	applyCustomButton = button(customRow, {
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 48),
		TextSize = 16,
		AutoButtonColor = true,
	})
	corner(applyCustomButton, 10)

	customSection.Size = UDim2.new(1, 0, 0, PICKER_HEIGHT + HUE_HEIGHT + 20 + 92)

	local pickerHue, pickerSat, pickerVal = 0, 0.85, 0.8

	local function pickerHex()
		return VehiclePaint.ToHex(Color3.fromHSV(pickerHue, pickerSat, pickerVal))
	end

	local function drawPicker()
		satValBox.BackgroundColor3 = Color3.fromHSV(pickerHue, 1, 1)
		satValKnob.Position = UDim2.fromScale(pickerSat, 1 - pickerVal)
		hueKnob.Position = UDim2.fromScale(pickerHue, 0.5)
		local color = Color3.fromHSV(pickerHue, pickerSat, pickerVal)
		customChip.BackgroundColor3 = color
		customHexLabel.Text = VehiclePaint.ToHex(color)
	end

	setPickerFromValue = function(value)
		local color = VehiclePaint.IsCustom(value) and VehiclePaint.ToColor(value)
		if color then
			pickerHue, pickerSat, pickerVal = color:ToHSV()
		end
		drawPicker()
	end

	-- Picker drags. Tracked through UserInputService rather than the frames' own
	-- InputChanged, because a finger inevitably slides off a 22px hue bar partway
	-- through a drag and the drag should keep going anyway.
	local pickerDrag = nil -- "SatVal" | "Hue" | nil
	local pickerDragInput = nil

	local function updatePickerDrag(position)
		if pickerDrag == "SatVal" then
			local topLeft, size = satValBox.AbsolutePosition, satValBox.AbsoluteSize
			pickerSat = math.clamp((position.X - topLeft.X) / size.X, 0, 1)
			pickerVal = 1 - math.clamp((position.Y - topLeft.Y) / size.Y, 0, 1)
		elseif pickerDrag == "Hue" then
			local topLeft, size = hueBar.AbsolutePosition, hueBar.AbsoluteSize
			pickerHue = math.clamp((position.X - topLeft.X) / size.X, 0, 0.999)
		end
		drawPicker()
		-- Only the car and the chip follow the drag frame by frame; the rest of
		-- the tab (swatch rings, the apply button) is redrawn on begin and end.
		previewPaint = pickerHex()
		GarageStage.SetPaint(previewPaint)
	end

	local function beginPickerDrag(kind, input)
		local inputType = input.UserInputType
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			return
		end
		pickerDrag = kind
		pickerDragInput = input
		updatePickerDrag(input.Position)
		renderPaint()
	end

	local function endPickerDrag()
		pickerDrag = nil
		pickerDragInput = nil
		renderPaint()
	end

	satValBox.InputBegan:Connect(function(input)
		beginPickerDrag("SatVal", input)
	end)
	hueBar.InputBegan:Connect(function(input)
		beginPickerDrag("Hue", input)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not pickerDrag then
			return
		end
		local isMouse = pickerDragInput.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement
		if isMouse or input == pickerDragInput then
			updatePickerDrag(input.Position)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if not pickerDrag then
			return
		end
		if input == pickerDragInput or (input.UserInputType == Enum.UserInputType.MouseButton1 and pickerDragInput.UserInputType == Enum.UserInputType.MouseButton1) then
			endPickerDrag()
		end
	end)

	applyCustomButton.MouseButton1Click:Connect(function()
		if not latestData then
			return
		end
		playClickSound()
		local passId = customPassId()
		if ownsCustomPaint(latestData) then
			commitPaint(pickerHex())
		elseif passId then
			MarketplaceService:PromptGamePassPurchase(player, passId)
		end
	end)

	cancelPickerDrag = function()
		pickerDrag = nil
		pickerDragInput = nil
	end
end

local function makeSwatch(value, order, ownedColors, savedPaint)
	local preset = value and VehiclePaint.ColorsById[value]
	local owned = value == nil or ownedColors[value] == true
	local isOn = previewPaint == value
	local isSaved = savedPaint == value

	local cell = Instance.new("Frame")
	cell.Name = value or "Stock"
	cell.Size = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE + 20)
	cell.BackgroundTransparency = 1
	cell.LayoutOrder = order
	cell.Parent = swatchGrid

	local swatch = button(cell, {
		Name = "Swatch",
		Size = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE),
		BackgroundColor3 = if preset then preset.Color else CARD,
		Text = if preset then "" else "STOCK",
		Font = Enum.Font.GothamBlack,
		TextSize = 11,
		TextColor3 = BRIGHT_TEXT,
	})
	corner(swatch, 12)
	stroke(swatch, if isOn then ACCENT else CARD_EDGE, if isOn then 3 else 1)

	if not owned then
		label(swatch, {
			Size = UDim2.fromOffset(22, 22),
			Position = UDim2.new(1, -2, 1, -2),
			AnchorPoint = Vector2.new(1, 1),
			TextSize = 13,
			Text = LOCK_GLYPH,
		})
	elseif isSaved then
		local tick = label(swatch, {
			Size = UDim2.fromOffset(22, 22),
			Position = UDim2.new(1, -3, 0, 3),
			AnchorPoint = Vector2.new(1, 0),
			BackgroundTransparency = 0,
			BackgroundColor3 = ACCENT,
			Font = Enum.Font.GothamBlack,
			TextSize = 14,
			TextColor3 = PANEL,
			Text = TICK_GLYPH,
		})
		corner(tick, 11)
	end

	label(cell, {
		Size = UDim2.new(1, 4, 0, 16),
		Position = UDim2.new(0.5, 0, 0, SWATCH_SIZE + 3),
		AnchorPoint = Vector2.new(0.5, 0),
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		TextColor3 = if owned then DIM_TEXT else ACCENT,
		Text = if owned then (if preset then preset.DisplayName else "Free") else formatMoney(preset.Price),
	})

	swatch.MouseButton1Click:Connect(function()
		playClickSound()
		if owned then
			if value ~= savedPaint then
				commitPaint(value)
			else
				tryOnPaint(value)
			end
		else
			tryOnPaint(value)
		end
	end)
end

renderPaint = function()
	local data = latestData
	if not data or not viewedVehicleId then
		return
	end
	clearChildren(swatchGrid)
	local grid = Instance.new("UIGridLayout", swatchGrid)
	grid.CellSize = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE + 20)
	grid.CellPadding = UDim2.fromOffset(SWATCH_GAP, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder

	local ownedColors = {}
	for _, id in data.PaintColors or {} do
		ownedColors[id] = true
	end
	local saved = savedPaintFor(data, viewedVehicleId)

	makeSwatch(nil, 0, ownedColors, saved)
	for index, entry in VehiclePaint.Colors do
		makeSwatch(entry.Id, index, ownedColors, saved)
	end

	-- The buy bar: only while trying on a colour you don't own.
	local preset = previewPaint and VehiclePaint.ColorsById[previewPaint]
	local tryingLocked = preset ~= nil and not ownedColors[preset.Id]
	buyBar.Visible = tryingLocked
	if tryingLocked then
		buyBarSwatch.BackgroundColor3 = preset.Color
		buyBarName.Text = preset.DisplayName
		local affordable = (data.Money or 0) >= preset.Price
		buyBarButton.Text = if affordable then "BUY " .. formatMoney(preset.Price) else "NEED " .. formatMoney(preset.Price - (data.Money or 0))
		buyBarButton.BackgroundColor3 = if affordable then ACCENT else LOCKED
		buyBarButton.TextColor3 = if affordable then PANEL else DIM_TEXT
		buyBarButton.AutoButtonColor = affordable
	end

	-- The custom row.
	local customOn = VehiclePaint.IsCustom(previewPaint)
	customChipStroke.Color = if customOn then ACCENT else PANEL_EDGE
	customChipStroke.Thickness = if customOn then 3 else 2
	if ownsCustomPaint(data) then
		local unchanged = customOn and previewPaint == saved
		applyCustomButton.Text = if unchanged then "APPLIED " .. TICK_GLYPH else "APPLY THIS COLOUR"
		applyCustomButton.BackgroundColor3 = if unchanged then LOCKED else ACCENT
		applyCustomButton.TextColor3 = if unchanged then DIM_TEXT else PANEL
	elseif customPassId() then
		applyCustomButton.Text = LOCK_GLYPH .. " GET " .. string.upper(VehiclePaint.CustomPaintDisplayName)
		applyCustomButton.BackgroundColor3 = GOLD
		applyCustomButton.TextColor3 = PANEL
	else
		applyCustomButton.Text = "CUSTOM PAINT - COMING SOON"
		applyCustomButton.BackgroundColor3 = LOCKED
		applyCustomButton.TextColor3 = DIM_TEXT
	end
end

buyBarButton.MouseButton1Click:Connect(function()
	local data = latestData
	local preset = previewPaint and VehiclePaint.ColorsById[previewPaint]
	if not data or not preset or (data.Money or 0) < preset.Price then
		return
	end
	playClickSound()
	local vehicleId = viewedVehicleId
	if buyPaintColorFunction:InvokeServer(preset.Id) then
		setVehiclePaintFunction:InvokeServer(vehicleId, preset.Id)
		playClaimSound()
	end
	refreshTerminalData()
end)

--============================================================================
-- Vehicle list
--============================================================================

local function listHeader(text, order)
	label(vehicleList, {
		Size = UDim2.new(1, 0, 0, 18),
		Font = Enum.Font.GothamBold,
		TextSize = 11,
		TextColor3 = DIM_TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = text,
		LayoutOrder = order,
	})
end

local showVehicle -- forward

local function makeVehicleRow(data, vehicleId, owned, order)
	local def = VehicleCatalog.Get(vehicleId)
	if not def then
		return
	end
	local isViewed = vehicleId == viewedVehicleId

	local row = button(vehicleList, {
		Name = vehicleId,
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundColor3 = if isViewed then CARD_HOVER else CARD,
		Text = "",
		LayoutOrder = order,
	})
	corner(row, 10)
	stroke(row, if isViewed then ACCENT else CARD_EDGE, if isViewed then 2 else 1)
	row.MouseEnter:Connect(function()
		if vehicleId ~= viewedVehicleId then
			row.BackgroundColor3 = CARD_HOVER
		end
	end)
	row.MouseLeave:Connect(function()
		if vehicleId ~= viewedVehicleId then
			row.BackgroundColor3 = CARD
		end
	end)

	-- A dot of the car's paint for your own, so the list doubles as a
	-- reminder of which car is which colour.
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(14, 14)
	dot.Position = UDim2.new(0, 12, 0.5, 0)
	dot.AnchorPoint = Vector2.new(0, 0.5)
	dot.BorderSizePixel = 0
	dot.Parent = row
	corner(dot, 7)
	local paintColor = owned and VehiclePaint.ToColor(savedPaintFor(data, vehicleId))
	if paintColor then
		dot.BackgroundColor3 = paintColor
	elseif owned then
		dot.BackgroundColor3 = OWNED_SEGMENT
	else
		dot.BackgroundTransparency = 1
		label(dot, { Size = UDim2.fromScale(1, 1), TextSize = 11, Text = LOCK_GLYPH })
	end

	label(row, {
		Size = UDim2.new(1, -44, 0, 20),
		Position = UDim2.fromOffset(34, 9),
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = def.DisplayName,
	})

	local subText, subColor
	if owned then
		subText, subColor = "Owned", DIM_TEXT
	else
		local required = VehicleCatalog.RequiredDeliveries(def)
		local deliveries = data.Deliveries or 0
		if deliveries < required then
			subText, subColor = ProgressionConfig.DeliveryCountText(required - deliveries) .. " to go", CAUTION
		else
			subText = formatMoney(def.Price)
			subColor = if (data.Money or 0) >= def.Price then ACCENT else DIM_TEXT
		end
	end
	label(row, {
		Size = UDim2.new(1, -44, 0, 16),
		Position = UDim2.fromOffset(34, 30),
		TextSize = 12,
		TextColor3 = subColor,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = subText,
	})

	row.MouseButton1Click:Connect(function()
		if vehicleId ~= viewedVehicleId then
			playClickSound()
			showVehicle(vehicleId)
		end
	end)
end

local function renderVehicleList(data)
	clearChildren(vehicleList)
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	listHeader("YOURS", nextOrder())
	local anyShop = false
	for _, vehicleId in VehicleCatalog.Order do
		if ownsVehicle(data, vehicleId) then
			makeVehicleRow(data, vehicleId, true, nextOrder())
		else
			anyShop = true
		end
	end
	if anyShop then
		listHeader("SHOP", nextOrder())
		for _, vehicleId in VehicleCatalog.Order do
			if not ownsVehicle(data, vehicleId) then
				makeVehicleRow(data, vehicleId, false, nextOrder())
			end
		end
	end
end

--============================================================================
-- Header + action button
--============================================================================

local function carryingContract()
	local stop = player:GetAttribute(ACTIVE_CONTRACT_ATTRIBUTE)
	return type(stop) == "string" and stop ~= "", stop
end

-- What the action button does right now; set by renderHeader.
local actionHandler = nil

local function setAction(text, color, handler)
	actionButton.Text = text
	actionButton.BackgroundColor3 = color
	actionButton.TextColor3 = if handler then PANEL else DIM_TEXT
	actionButton.AutoButtonColor = handler ~= nil
	actionHandler = handler
end

local function renderHeader(data)
	local vehicleId = viewedVehicleId
	local def = vehicleId and VehicleCatalog.Get(vehicleId)
	vehicleNameLabel.Text = def and def.DisplayName or "--"
	contractWarning.Visible = false
	if not def then
		vehicleStatusLabel.Text = ""
		setAction("--", LOCKED, nil)
		return
	end

	if ownsVehicle(data, vehicleId) then
		vehicleStatusLabel.Text = "Owned  \u{2022}  " .. VehiclePaint.DisplayName(savedPaintFor(data, vehicleId)) .. " paint"
		local carrying, stop = carryingContract()
		-- Recoloured with the warning so the two read as one object.
		setAction("SPAWN VEHICLE", if carrying then CAUTION else ACCENT, function()
			spawnVehicleEvent:FireServer(vehicleId)
			-- Nothing left to do at the terminal once the car is out.
			closeTerminal()
		end)
		if carrying then
			contractWarning.Text = string.format("Spawning scraps your load for %s.", stop)
			contractWarning.Visible = true
		end
		return
	end

	-- Not owned. A vehicle has TWO prices, money and lifetime deliveries (see
	-- VehicleCatalog's header); the deliveries one is checked first because it
	-- is the one the player cannot fix with money.
	local required = VehicleCatalog.RequiredDeliveries(def)
	local deliveries = data.Deliveries or 0
	if deliveries < required then
		vehicleStatusLabel.Text = "Requires " .. ProgressionConfig.DeliveryCountText(required)
		setAction(string.upper(ProgressionConfig.DeliveryCountText(required - deliveries)) .. " TO GO", LOCKED, nil)
		return
	end

	vehicleStatusLabel.Text = "For sale"
	if (data.Money or 0) < def.Price then
		setAction("NEED " .. formatMoney(def.Price - data.Money) .. " MORE", LOCKED, nil)
		return
	end
	setAction("BUY " .. formatMoney(def.Price), ACCENT, function()
		if buyVehicleFunction:InvokeServer(vehicleId) then
			playClaimSound()
		end
		refreshTerminalData()
	end)
end

actionButton.MouseButton1Click:Connect(function()
	if actionHandler then
		playClickSound()
		actionHandler()
	end
end)

player:GetAttributeChangedSignal(ACTIVE_CONTRACT_ATTRIBUTE):Connect(function()
	if screenGui.Enabled and latestData then
		renderHeader(latestData)
	end
end)

--============================================================================
-- Rendering
--============================================================================

local function renderShopInfo(data, vehicleId)
	local def = VehicleCatalog.Get(vehicleId)
	if not def then
		return
	end
	shopPriceLabel.Text = formatMoney(def.Price)
	local required = VehicleCatalog.RequiredDeliveries(def)
	local deliveries = data.Deliveries or 0
	if required <= 0 then
		shopRequirementLabel.Text = "No delivery requirement."
		shopRequirementLabel.TextColor3 = BRIGHT_TEXT
	elseif deliveries >= required then
		shopRequirementLabel.Text = "Requires " .. ProgressionConfig.DeliveryCountText(required) .. " " .. TICK_GLYPH
		shopRequirementLabel.TextColor3 = ACCENT
	else
		shopRequirementLabel.Text = string.format(
			"Requires %s\nYou have %d",
			ProgressionConfig.DeliveryCountText(required),
			deliveries
		)
		shopRequirementLabel.TextColor3 = CAUTION
	end
end

renderAll = function()
	local data = latestData
	if not data then
		return
	end
	moneyLabel.Text = formatMoney(data.Money)
	deliveriesLabel.Text = ProgressionConfig.DeliveryCountText(data.Deliveries or 0) .. " completed"

	renderHeader(data)
	renderVehicleList(data)

	-- THE TUTORIAL'S FIRST MINUTE: one button, nothing competing with it.
	-- Read off the attribute TutorialGuide publishes, NOT data.TutorialDone,
	-- which answers a different question ("ever finished it") and is wrong in
	-- both directions for a replay.
	local tutorialActive = isTutorialActive()
	rightPanel.Visible = not tutorialActive
	dragHint.Visible = not tutorialActive
	if tutorialActive or not viewedVehicleId then
		return
	end

	local owned = ownsVehicle(data, viewedVehicleId)
	tabBar.Visible = owned
	shopInfo.Visible = not owned
	if owned then
		renderUpgrades(data, viewedVehicleId)
		renderPaint()
		showRightTab(activeRightTab)
	else
		upgradesScroll.Visible = false
		paintScroll.Visible = false
		renderShopInfo(data, viewedVehicleId)
	end
end

-- Parks a vehicle on the stage and makes it the one the whole screen is about.
-- For an owned car this is also "select it", so Spawn spawns what is shown.
showVehicle = function(vehicleId)
	local data = latestData
	if not data then
		return
	end
	viewedVehicleId = vehicleId
	previewPaint = if ownsVehicle(data, vehicleId) then savedPaintFor(data, vehicleId) else nil
	setPickerFromValue(previewPaint)
	if ownsVehicle(data, vehicleId) and data.SelectedVehicleId ~= vehicleId then
		data.SelectedVehicleId = vehicleId
		selectVehicleEvent:FireServer(vehicleId)
	end
	renderAll()
	-- Last: building a preview for the first time can yield while its model
	-- replicates, and the UI should not wait on it.
	task.spawn(GarageStage.ShowVehicle, vehicleId, previewPaint)
end

refreshTerminalData = function()
	local data = getPlotDataFunction:InvokeServer()
	if not data then
		return nil
	end
	latestData = data
	if not viewedVehicleId or not VehicleCatalog.Get(viewedVehicleId) then
		viewedVehicleId = data.SelectedVehicleId
	end
	-- A purchase can change what is saved; whatever is on the car follows the
	-- save unless the player is mid-way through trying something on.
	if not (activeRightTab == "Paint" and isPreviewing(data)) or not ownsVehicle(data, viewedVehicleId) then
		previewPaint = if ownsVehicle(data, viewedVehicleId) then savedPaintFor(data, viewedVehicleId) else nil
	end
	if screenGui.Enabled then
		renderAll()
		GarageStage.SetPaint(previewPaint)
	end
	return data
end

-- The tutorial just started or ended while the garage was open.
player:GetAttributeChangedSignal(TUTORIAL_ACTIVE_ATTRIBUTE):Connect(function()
	if screenGui.Enabled then
		renderAll()
	end
end)

-- A pass just got bought. BOTH this client and the server hear this event and
-- nothing orders them, so a redraw on the same frame can beat the server's own
-- cache update and come back still locked. The delay is what makes the redraw
-- see the purchase.
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(_, _, wasPurchased)
	if not wasPurchased or not screenGui.Enabled then
		return
	end
	task.delay(1, function()
		if screenGui.Enabled then
			refreshTerminalData()
		end
	end)
end)

--============================================================================
-- Open / close
--============================================================================

-- Other scripts' HUDs that sit in the corners this screen now uses (the money
-- pill and shop/settings launchers bottom-right, the delivery HUD, the
-- first-person crosshair in the middle of the car). Hidden while the garage is
-- up and put back exactly as found. By name, and FindFirstChild'd: a HUD that
-- is renamed or removed is simply no longer hidden, nothing breaks.
local HUDS_HIDDEN_WHILE_OPEN = {
	"MoneyDisplay",
	"SettingsLauncher",
	"VehicleShopButton",
	"DeliveryGui",
	"FirstPersonCursorGui",
}
local hiddenHuds = {}

local function hideOtherHuds()
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return
	end
	for _, name in HUDS_HIDDEN_WHILE_OPEN do
		local gui = playerGui:FindFirstChild(name)
		if gui and gui:IsA("ScreenGui") and gui.Enabled then
			gui.Enabled = false
			table.insert(hiddenHuds, gui)
		end
	end
end

local function restoreOtherHuds()
	for _, gui in hiddenHuds do
		if gui.Parent then
			gui.Enabled = true
		end
	end
	table.clear(hiddenHuds)
end

local lifeConnections = {}

local function disconnectLife()
	for _, connection in lifeConnections do
		connection:Disconnect()
	end
	table.clear(lifeConnections)
end

-- Anything that takes the player away from the terminal ends the garage view:
-- dying, respawning, or somehow ending up in a seat.
local function watchCharacter()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	table.insert(lifeConnections, humanoid.Died:Connect(function()
		closeTerminal()
	end))
	table.insert(lifeConnections, humanoid.Seated:Connect(function(active)
		if active then
			closeTerminal()
		end
	end))
	table.insert(lifeConnections, player.CharacterRemoving:Connect(function()
		closeTerminal()
	end))
end

local opening = false

local function openTerminal(plotModel)
	-- The "Open Garage" prompt can fire again while it is up; one garage at a
	-- time.
	if screenGui.Enabled or opening then
		return
	end
	opening = true
	local data = refreshTerminalData()
	opening = false
	if not data or screenGui.Enabled then
		return
	end
	viewedVehicleId = data.SelectedVehicleId
	activeRightTab = "Upgrades"

	GarageStage.Open(plotModel)
	hideOtherHuds()
	screenGui.Enabled = true
	setGarageOpenEvent:FireServer(true)
	watchCharacter()
	showVehicle(viewedVehicleId)
end

closeTerminal = function()
	if not screenGui.Enabled then
		return
	end
	screenGui.Enabled = false
	hideInfoModal()
	disconnectLife()
	cancelPickerDrag()
	GarageStage.Close()
	restoreOtherHuds()
	setGarageOpenEvent:FireServer(false)
end

closeButton.MouseButton1Click:Connect(function()
	playClickSound()
	closeTerminal()
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.Escape or not screenGui.Enabled then
		return
	end
	-- Escape backs out one layer at a time.
	if infoModal.Visible then
		hideInfoModal()
	else
		closeTerminal()
	end
end)

--============================================================================
-- Per-plot prompts
--============================================================================

-- [plotModel] = true once its prompts exist, guarding against a second pair
-- being built for the same plot by the retry loop below.
local promptsBuilt = {}

-- Two CustomPrompt instances per plot rather than one whose text changes:
-- CustomPrompt builds its label once at construction and cannot relabel it. The
-- two are mutually exclusive - a plot is never both unclaimed and mine at once -
-- so only one of a pair is ever visible and both binding F is harmless.
local function setupPlotPrompts(plotModel)
	if promptsBuilt[plotModel] then
		return true
	end

	local terminal = plotModel:FindFirstChild("Terminal")
	local screen = terminal and terminal:FindFirstChild("Screen")
	if not screen then
		return false -- not fully replicated yet; the retry below catches it
	end

	local claimPrompt = CustomPrompt.new(screen, {
		Text = "Hold to Claim This Plot",
		KeyCode = Enum.KeyCode.F,
		-- Hold rather than tap: claiming cannot be undone for the rest of the
		-- server, so this guards against a stray press claiming the wrong plot.
		HoldDuration = 0.5,
		ShouldShow = function()
			return not PlotOwnership.IsClaimed(plotModel) and not localPlayerOwnsAnyPlot()
		end,
	})
	claimPrompt.Triggered:Connect(function()
		claimPlotEvent:FireServer(plotModel)
	end)

	local openPrompt = CustomPrompt.new(screen, {
		Text = "Open Garage",
		KeyCode = Enum.KeyCode.F,
		ShouldShow = function()
			return PlotOwnership.IsOwner(player, plotModel) and not screenGui.Enabled
		end,
	})
	openPrompt.Triggered:Connect(function()
		openTerminal(plotModel)
	end)

	promptsBuilt[plotModel] = true
	return true
end

-- A plot's Terminal/Screen may not have finished replicating the instant the
-- plot itself appears under VehiclePlotsFolder. Without this retry, a plot whose
-- Screen was one network tick late never gets a prompt at all for the rest of
-- the session, with nothing logged anywhere to explain why.
local SETUP_RETRY_INTERVAL = 1
local SETUP_RETRY_TIMEOUT = 60

local function trySetupPlotPrompts(plotModel)
	if setupPlotPrompts(plotModel) then
		return
	end
	task.spawn(function()
		local elapsed = 0
		while plotModel.Parent == VehiclePlotsFolder and not promptsBuilt[plotModel] and elapsed < SETUP_RETRY_TIMEOUT do
			task.wait(SETUP_RETRY_INTERVAL)
			elapsed += SETUP_RETRY_INTERVAL
			if plotModel.Parent == VehiclePlotsFolder and setupPlotPrompts(plotModel) then
				return
			end
		end
		if plotModel.Parent == VehiclePlotsFolder and not promptsBuilt[plotModel] then
			warn("PlotTerminal: gave up waiting for " .. plotModel:GetFullName() .. " to have a Terminal.Screen")
		end
	end)
end

--============================================================================
-- Claim feedback sound
--============================================================================

-- Watches the attribute rather than hooking claimPrompt.Triggered: Triggered
-- only means a claim request was SENT, not that the server accepted it.
local function watchForLocalClaim(plotModel)
	plotModel:GetAttributeChangedSignal(PlotOwnership.OWNER_USERID_ATTRIBUTE):Connect(function()
		if PlotOwnership.GetOwnerUserId(plotModel) == player.UserId then
			playClaimSound()
		end
	end)
end

local function setupPlot(plotModel)
	trySetupPlotPrompts(plotModel)
	watchForLocalClaim(plotModel)
end

for _, plotModel in VehiclePlotsFolder:GetChildren() do
	setupPlot(plotModel)
end
VehiclePlotsFolder.ChildAdded:Connect(setupPlot)

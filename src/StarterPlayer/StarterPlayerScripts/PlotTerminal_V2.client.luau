-- Garage terminal, redesigned for the actual audience: a nine-year-old with a
-- short attention span who may not read English well.
--
-- WHAT WAS WRONG WITH V1 (PlotTerminal.client.luau, still in the tree behind
-- TerminalVersion.luau while the two are compared):
--
--   TEN IDENTICAL GREY ROWS. Every upgrade looked the same - a name, a number,
--   a thin bar - so the eye had nothing to land on and the whole section read
--   as a settings menu. Nothing about it said "this is where the money goes".
--
--   TWO ACTIONS PER UPGRADE, and the wrong one first. Buying a level only
--   UNLOCKED a notch; the car did not change until the player also dragged a
--   slider. A child who spends their first $150 and sees nothing happen has
--   learned that upgrading does nothing. Here, buying applies immediately
--   (see the buy handler in makeUpgradeCard) and the arrows are an optional
--   way to turn it back DOWN.
--
--   A DRAG TARGET ON A PHONE. The slider knob was 16px and had to be dragged
--   along a 10px track, tracked through UserInputService because a finger
--   inevitably left the track. Replaced by two tap targets.
--
--   WORDS ONLY, and the words were jargon. "TractionSlipThreshold" means
--   nothing to the player paying for it. Every card now leads with a 240x240
--   icon (Configs/<Car>.luau's IconId) and a plain-English name (DisplayName),
--   so the card is navigable without reading.
--
-- THE PAYWALL. Six of the ten upgrades need a game pass (see
-- UpgradePasses.luau for which, and why those). They are NOT hidden behind a
-- second tab: a locked thing nobody sees is a locked thing nobody wants. They
-- sit in the same scroll, below a gold divider, drawn in gold with a padlock,
-- immediately under the four free ones - so the pitch is simply the player
-- looking at their own garage.
--
-- THE TUTORIAL. Two constraints, both load-bearing:
--
--   The panel is named TerminalPanel and the spawn button SpawnVehicleButton,
--   because TutorialGuide.client.luau finds both by name (through
--   PlayerGui.PlotTerminalGui) to dim the panel down to that one button.
--   Renaming either costs the tutorial's spotlight and nothing else.
--
--   The tutorial's banner is bottom-anchored, up to 580x106, and it is DRAWN
--   OVER this panel, so the panel's bottom edge is not a safe place for
--   anything the tutorial needs the player to press. The spawn button's bottom
--   edge sits at 324/624 of the panel - just past the halfway line - which survives
--   scaling because ResponsiveScale scales the panel uniformly and so preserves
--   that fraction exactly. Worst case is a landscape phone (the panel scales to
--   ~0.59 there and the banner eats the bottom 126px of the screen), where the
--   button still clears the banner by about 58px. The upgrade section, the only
--   thing that DOES reach the bottom edge, is not built at all until the
--   tutorial is done (see renderGarageForVehicle's tutorialActive).
--
-- Nothing here is a security boundary. Claiming, spawning, buying and tuning
-- are all re-checked in PlotManager.server.luau, including the game-pass wall.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")
local MarketplaceService = game:GetService("MarketplaceService")

local CustomPrompt = require(ReplicatedStorage.Modules.UI.CustomPrompt)
local ResponsiveScale = require(ReplicatedStorage.Modules.UI.ResponsiveScale)
local TerminalVersion = require(ReplicatedStorage.Modules.UI.TerminalVersion)
local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)
local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)
local VehicleCatalog = require(ReplicatedStorage.Modules.Vehicles.VehicleCatalog)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleUpgrades = require(ReplicatedStorage.Modules.Vehicles.VehicleUpgrades)
local UpgradePasses = require(ReplicatedStorage.Modules.Vehicles.UpgradePasses)

-- TEMPORARY, while this is compared against V1. Both scripts build a ScreenGui
-- called PlotTerminalGui and a prompt on every plot, so only one may run.
if TerminalVersion ~= 2 then
	return
end

local player = Players.LocalPlayer

local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")

local claimPlotEvent = ReplicatedStorage:WaitForChild("ClaimPlot")
local spawnVehicleEvent = ReplicatedStorage:WaitForChild("SpawnVehicle")
local selectVehicleEvent = ReplicatedStorage:WaitForChild("SelectVehicle")
local getPlotDataFunction = ReplicatedStorage:WaitForChild("GetPlotData")
local buyVehicleEvent = ReplicatedStorage:WaitForChild("BuyVehicle")
local buyUpgradeEvent = ReplicatedStorage:WaitForChild("BuyUpgrade")
local setCarConfigValueEvent = ReplicatedStorage:WaitForChild("SetCarConfigValue")

--============================================================================
-- Palette
--============================================================================

-- Same dark-panel family as CustomPrompt / VehicleDashboard / DeliveryHud, so
-- this reads as one UI system. GOLD is the only addition, and it means exactly
-- one thing everywhere it appears: this costs Robux.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local CARD = Color3.fromRGB(28, 31, 38)
local CARD_EDGE = Color3.fromRGB(44, 49, 60)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)
local LOCKED = Color3.fromRGB(48, 52, 62)
local OWNED_SEGMENT = Color3.fromRGB(78, 86, 102)
local CAUTION = Color3.fromRGB(224, 178, 84)
local STAMP_RED = Color3.fromRGB(214, 76, 76)
local GOLD = Color3.fromRGB(247, 196, 78)
local GOLD_DIM = Color3.fromRGB(122, 98, 42)

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

local CLAIM_SOUND_ID = "rbxassetid://90420386076500"
local TERMINAL_CLICK_SOUND_ID = "rbxassetid://127105730240202"

local function playClaimSound()
	playSound(CLAIM_SOUND_ID)
end
local function playClickSound()
	playSound(TERMINAL_CLICK_SOUND_ID)
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
	s.Parent = instance
	return s
end

-- Property-bag TextLabel. This file builds around forty of them and the
-- five-line Instance.new/BackgroundTransparency/Font/TextColor3/Parent preamble
-- on each one is what made V1 hard to read the layout out of.
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

-- Set by TutorialGuide.client.luau for exactly as long as the tutorial is on
-- screen. A FindFirstChild-style soft dependency: if that script never runs the
-- attribute is simply nil, this reads false, and the terminal behaves as it does
-- for any player who is not in the tutorial.
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
-- Panel shell
--============================================================================

local closeTerminal -- assigned near the bottom; the spawn button closes on click

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlotTerminalGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = player:WaitForChild("PlayerGui")

local main = Instance.new("Frame")
main.Name = "TerminalPanel" -- see the tutorial note in this file's header
main.Size = UDim2.fromOffset(720, 624)
main.Position = UDim2.fromScale(0.5, 0.5)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.BackgroundColor3 = PANEL
main.BorderSizePixel = 0
main.Parent = screenGui
corner(main, 14)
stroke(main, PANEL_EDGE)

-- Designed at a fixed 720x624. The HEIGHT is derived, not chosen: it is
-- exactly tall enough to show the car, the four free upgrade cards and the gold
-- pass banner, and not one row more (see UPGRADE_VIEWPORT_HEIGHT). Making the
-- panel taller would pull the first row of locked cards up into view and undo
-- the whole point of where the banner sits.
--
-- ResponsiveScale shrinks the whole thing (and
-- every descendant, uniformly) to fit a phone. MinScale is below the module's
-- default for the same reason V1's was: at 720 wide, the default 0.55 floor
-- still leaves this wider than the narrowest phones, and fitting matters more
-- here than the last bit of text size.
ResponsiveScale.Fit(main, { Margin = 16, MinScale = 0.42 })

label(main, {
	Size = UDim2.new(1, -110, 0, 40),
	Position = UDim2.fromOffset(20, 12),
	Font = Enum.Font.GothamBold,
	TextSize = 22,
	TextXAlignment = Enum.TextXAlignment.Left,
	Text = "My Garage",
})

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(36, 36)
closeButton.Position = UDim2.new(1, -50, 0, 14)
closeButton.BackgroundColor3 = CARD
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 18
closeButton.TextColor3 = BRIGHT_TEXT
closeButton.Text = "X"
closeButton.Parent = main
corner(closeButton, 10)

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -40, 0, 36)
tabBar.Position = UDim2.fromOffset(20, 58)
tabBar.BackgroundTransparency = 1
tabBar.Parent = main

local tabLayout = Instance.new("UIListLayout", tabBar)
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 8)

-- Siblings of tabBar, not children: tabBar's UIListLayout would otherwise pack
-- these in after the tab buttons instead of pinning them to the row's far edge.
--
-- Money is the biggest number on the panel on purpose. It is the one thing a
-- child checks before deciding whether any of this is for them right now.
local moneyLabel = label(main, {
	Size = UDim2.fromOffset(180, 36),
	Position = UDim2.new(1, -196, 0, 58),
	Font = Enum.Font.GothamBlack,
	TextSize = 22,
	TextColor3 = ACCENT,
	TextXAlignment = Enum.TextXAlignment.Right,
	Text = "$0",
})

-- Deliberately quieter: the shop's locked cards say "requires 20 deliveries",
-- so the player's own count has to appear somewhere for that to mean anything,
-- but this is the only screen where it matters and it never needs to be loud.
local deliveriesLabel = label(main, {
	Size = UDim2.fromOffset(200, 36),
	Position = UDim2.new(1, -400, 0, 58),
	TextSize = 13,
	TextColor3 = DIM_TEXT,
	TextXAlignment = Enum.TextXAlignment.Right,
	Text = "",
})

local contentFrame = Instance.new("Frame")
contentFrame.Size = UDim2.new(1, -40, 1, -116)
contentFrame.Position = UDim2.fromOffset(20, 104)
contentFrame.BackgroundTransparency = 1
contentFrame.Parent = main

--============================================================================
-- Info modal - the (i) on each upgrade card
--============================================================================

local infoModal = Instance.new("Frame")
infoModal.Size = UDim2.fromScale(1, 1)
infoModal.BackgroundTransparency = 1
infoModal.Visible = false
infoModal.ZIndex = 10
infoModal.Parent = screenGui

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

local infoCloseButton = Instance.new("TextButton")
infoCloseButton.Size = UDim2.fromOffset(30, 30)
infoCloseButton.Position = UDim2.new(1, -46, 0, 16)
infoCloseButton.BackgroundColor3 = CARD
infoCloseButton.BorderSizePixel = 0
infoCloseButton.Font = Enum.Font.GothamBold
infoCloseButton.TextSize = 15
infoCloseButton.TextColor3 = BRIGHT_TEXT
infoCloseButton.Text = "X"
infoCloseButton.ZIndex = 12
infoCloseButton.Parent = infoPanel
corner(infoCloseButton, 8)

-- Bigger than V1's 14px and in BRIGHT_TEXT rather than DIM: this is the one
-- block of real prose in the panel and it is aimed at someone still learning
-- to read. Dim grey body copy at 14px is decoration, not information.
local infoDescription = label(infoPanel, {
	Size = UDim2.new(1, -40, 1, -124),
	Position = UDim2.fromOffset(20, 108),
	TextSize = 16,
	TextWrapped = true,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	ZIndex = 11,
})

local function hideInfoModal()
	infoModal.Visible = false
end

local function showInfoModal(titleText, description, iconId)
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

--============================================================================
-- Tabs
--============================================================================

local tabs = {} -- [name] = { Button, Page }
local activeTabName = nil

local function showTab(name)
	if activeTabName == name then
		return
	end
	activeTabName = name
	for tabName, entry in tabs do
		local isActive = tabName == name
		entry.Page.Visible = isActive
		entry.Button.BackgroundColor3 = if isActive then ACCENT else CARD
		entry.Button.TextColor3 = if isActive then PANEL else DIM_TEXT
	end
end

local function addTab(name)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(130, 36)
	button.BackgroundColor3 = CARD
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 16
	button.TextColor3 = DIM_TEXT
	button.Text = name
	button.Parent = tabBar
	corner(button, 10)

	local page = Instance.new("Frame")
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.Visible = false
	page.Parent = contentFrame

	tabs[name] = { Button = button, Page = page }
	button.MouseButton1Click:Connect(function()
		playClickSound()
		showTab(name)
	end)
	return page
end

--============================================================================
-- Upgrade card geometry
--============================================================================

-- 4 across, which is what makes the four FREE upgrades land on exactly one row -
-- and one row is what lets the gold divider sit on the panel's bottom edge (see
-- UPGRADE_VIEWPORT_HEIGHT). That makes the column count a design decision
-- rather than a spacing one: at 3 columns the free stats wrap to two rows and
-- push the pass banner off the screen entirely.
--
-- ICON_SIZE is the number to change if the cards ever need to breathe more. It
-- is the largest thing on the card on purpose - for a player who cannot read
-- "Suspension", the picture is not decoration next to the label, it IS the
-- label, and everything else on the card is an annotation on it. CARD_HEIGHT is
-- derived from it: icon, name, the tune row, the button, and 8px of margin.
local GRID_COLUMNS = 4
local CARD_WIDTH = 154
local ICON_SIZE = 76
local CARD_HEIGHT = 190
local CARD_PADDING = 16
local SEGMENT_GAP = 3
local SEGMENT_INSET = 72 -- the two 28px tune arrows plus their margins

-- Card interior, top to bottom. Named rather than sprinkled through
-- makeUpgradeCard as literals, because these only mean anything relative to
-- each other - nudging the icon without nudging what follows it is how a card
-- ends up with its name overlapping its own artwork.
local ICON_TOP = 10
local NAME_TOP = ICON_TOP + ICON_SIZE + 4 -- 90
local TUNE_ROW_TOP = NAME_TOP + 26 -- 116
local BAR_TOP = TUNE_ROW_TOP + 6 -- 122
local BUTTON_TOP = TUNE_ROW_TOP + 34 -- 150

--============================================================================
-- Garage tab: the car up top, the upgrade cards below
--============================================================================

local garagePage = addTab("Garage")

-- Load-bearing, not taste: everything below this belongs to the upgrade
-- section, and this is what puts the spawn button's bottom edge just past the
-- panel's halfway line, clear of the tutorial banner (see header). Growing this
-- to fit a bigger car photo means growing the PANEL by the same amount - left
-- alone, the photo would eat the upgrade row rather than the empty space.
local CAROUSEL_HEIGHT = 220
local CAR_IMAGE_WIDTH = 264
local CAR_IMAGE_HEIGHT = 148

local carousel = Instance.new("Frame")
carousel.Size = UDim2.new(1, 0, 0, CAROUSEL_HEIGHT)
carousel.BackgroundTransparency = 1
carousel.Parent = garagePage

local carImage = Instance.new("ImageLabel")
carImage.Size = UDim2.fromOffset(CAR_IMAGE_WIDTH, CAR_IMAGE_HEIGHT)
carImage.Position = UDim2.new(0.5, 0, 0, 0)
carImage.AnchorPoint = Vector2.new(0.5, 0)
carImage.BackgroundColor3 = CARD
carImage.BorderSizePixel = 0
carImage.ScaleType = Enum.ScaleType.Fit
carImage.Parent = carousel
corner(carImage, 12)

-- Shown instead of a blank frame while a vehicle has no ImageId yet
-- (VehicleCatalog.luau) - toggled in renderGarageForVehicle.
local carImagePlaceholder = label(carImage, {
	Size = UDim2.fromScale(1, 1),
	Font = Enum.Font.GothamBold,
	TextSize = 14,
	TextColor3 = DIM_TEXT,
	TextWrapped = true,
	Text = "Image Coming Soon",
	Visible = false,
})

local function makeCarouselArrow(text, xOffset)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(44, 44)
	button.Position = UDim2.new(0.5, xOffset, 0, (CAR_IMAGE_HEIGHT - 44) // 2)
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.BackgroundColor3 = CARD
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 22
	button.TextColor3 = BRIGHT_TEXT
	button.Text = text
	button.Parent = carousel
	corner(button, 22)
	return button
end

-- Half the photo, plus half an arrow, plus 8px of air - so the arrows keep
-- clear of the image at whatever CAR_IMAGE_WIDTH is set to.
local CAROUSEL_ARROW_X = CAR_IMAGE_WIDTH // 2 + 22 + 8
local prevButton = makeCarouselArrow("<", -CAROUSEL_ARROW_X)
local nextButton = makeCarouselArrow(">", CAROUSEL_ARROW_X)

local vehicleNameLabel = label(carousel, {
	Size = UDim2.new(1, 0, 0, 24),
	Position = UDim2.fromOffset(0, CAR_IMAGE_HEIGHT + 4),
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	Text = "--",
})

local spawnButton = Instance.new("TextButton")
spawnButton.Name = "SpawnVehicleButton" -- see the tutorial note in the header
spawnButton.Size = UDim2.fromOffset(240, 42)
spawnButton.Position = UDim2.new(0.5, 0, 0, CAROUSEL_HEIGHT - 42)
spawnButton.AnchorPoint = Vector2.new(0.5, 0)
spawnButton.BackgroundColor3 = ACCENT
spawnButton.BorderSizePixel = 0
spawnButton.Font = Enum.Font.GothamBlack
spawnButton.TextSize = 18
spawnButton.TextColor3 = PANEL
spawnButton.Text = "SPAWN VEHICLE"
spawnButton.Parent = carousel
corner(spawnButton, 10)
spawnButton.MouseButton1Click:Connect(function()
	playClickSound()
	spawnVehicleEvent:FireServer()
	-- Nothing left to do at the terminal once the car is out; closing means the
	-- player is not stuck hunting for X before they can go drive.
	closeTerminal()
end)

-- Spawning REPLACES whatever is parked here, and a truck carrying a contract
-- takes the contract with it - the crates are welded into that bed. That is the
-- intended rule, but it costs a contract slot, so it gets said BEFORE the click
-- rather than explained after it. Driven off the attribute DeliveryManager
-- mirrors onto the Player, which is already there when the terminal opens - so
-- the warning is on screen with the first frame rather than a round trip later.
local ACTIVE_CONTRACT_ATTRIBUTE = "ActiveContractStop"

local contractWarning = label(carousel, {
	Size = UDim2.fromOffset(180, 46),
	Position = UDim2.new(0.5, 130, 0, CAROUSEL_HEIGHT - 44),
	Font = Enum.Font.GothamBold,
	TextSize = 12,
	TextColor3 = CAUTION,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextWrapped = true,
	Visible = false,
})

local function refreshContractWarning()
	local stop = player:GetAttribute(ACTIVE_CONTRACT_ATTRIBUTE)
	local carrying = type(stop) == "string" and stop ~= ""
	contractWarning.Visible = carrying
	if carrying then
		contractWarning.Text = string.format("Spawning scraps your load for %s.", stop)
	end
	-- Recolouring the button is what makes the label and the thing it warns
	-- about read as one object; the label alone is easy to look past.
	spawnButton.BackgroundColor3 = if carrying then CAUTION else ACCENT
end

player:GetAttributeChangedSignal(ACTIVE_CONTRACT_ATTRIBUTE):Connect(refreshContractWarning)
refreshContractWarning()

-- WHERE THE PAY WALL SITS, and the reason the panel is the height it is.
--
-- The scroll viewport is sized so that the last thing visible before scrolling
-- is the gold pass banner, sitting on the bottom edge: one row of four free
-- cards (CARD_HEIGHT), the list's own padding, the 64px banner, and 4px of
-- slack. No locked card peeks above the fold.
--
-- That ordering is the pitch. A child opening this sees their car, the button
-- that gets it out, the four upgrades they already own - and then, as the last
-- thing on the screen, one gold bar telling them there is more. Showing a row
-- of padlocked cards up front instead makes the panel read as mostly-locked,
-- which is the version that gets closed rather than scrolled.
--
-- It holds because there are exactly four free stats and four columns. A fifth
-- free stat wraps to a second row and pushes the banner below the fold, which
-- is the correct-looking failure - the free upgrades stay first either way.
-- EVERY UIStroke IN THIS PANEL DRAWS OUTSIDE ITS FRAME, and a ScrollingFrame
-- clips its descendants - so anything sitting flush at x=0 loses the left half
-- of its outline while the right side, which has slack before the frame edge,
-- keeps all of its. It reads as the container being off-centre when it is
-- actually centred and shaved. Most visible on the gold pass banner, whose
-- stroke is 2px and bright; the cards have the same wound at 1px in a dark
-- colour, which is why it looked like a banner-only bug.
--
-- So both scroll canvases get side padding: 4px on the left for the stroke to
-- live in, and 12px on the right for the stroke PLUS the 6px scrollbar, which
-- overlays the frame's right edge and would otherwise sit on top of the last
-- card in each row.
local SCROLL_PAD_LEFT = 4
local SCROLL_PAD_RIGHT = 12
local SCROLL_CONTENT_WIDTH = 680 - SCROLL_PAD_LEFT - SCROLL_PAD_RIGHT

-- The width the 4-column grid has to land in exactly, which is what sets
-- CARD_WIDTH at 154: 4 * 154 + 3 * 16 == 664. Asserted rather than trusted,
-- because the failure is silent - a column too wide simply wraps the fourth
-- card onto its own row and quietly pushes the pass banner off the screen.
assert(GRID_COLUMNS * CARD_WIDTH + (GRID_COLUMNS - 1) * CARD_PADDING == SCROLL_CONTENT_WIDTH,
	"upgrade grid no longer fills the scroll canvas exactly - re-derive CARD_WIDTH from SCROLL_CONTENT_WIDTH")

local function padScroll(scrollingFrame)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, SCROLL_PAD_LEFT)
	padding.PaddingRight = UDim.new(0, SCROLL_PAD_RIGHT)
	padding.Parent = scrollingFrame
end

-- The sliver of the first locked row left showing under the banner. Without it
-- the banner sits flush on the bottom edge with nothing past it, and there is
-- no cue anywhere that the panel scrolls at all - so the six cards the pass
-- actually sells are invisible to a player who never thinks to drag. Small
-- enough to read as "there is more below" rather than as another row competing
-- with the free upgrades, which is what a full peeking row did before.
local PAID_ROW_PEEK = 16

local UPGRADE_VIEWPORT_HEIGHT = CARD_HEIGHT + 12 + 64 + PAID_ROW_PEEK

local upgradesScroll = Instance.new("ScrollingFrame")
upgradesScroll.Size = UDim2.fromOffset(680, UPGRADE_VIEWPORT_HEIGHT)
upgradesScroll.Position = UDim2.fromOffset(0, CAROUSEL_HEIGHT + 6)
upgradesScroll.BackgroundTransparency = 1
upgradesScroll.BorderSizePixel = 0
upgradesScroll.ScrollBarThickness = 8
-- Brighter than PANEL_EDGE, which at 52,58,70 on a 28,31,38 card is nearly
-- invisible - and this is the panel's only other hint that it scrolls.
upgradesScroll.ScrollBarImageColor3 = OWNED_SEGMENT
upgradesScroll.CanvasSize = UDim2.fromScale(0, 0) -- grown by the UIListLayout below
upgradesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
upgradesScroll.Parent = garagePage

local upgradesLayout = Instance.new("UIListLayout", upgradesScroll)
upgradesLayout.Padding = UDim.new(0, 12)
upgradesLayout.SortOrder = Enum.SortOrder.LayoutOrder
padScroll(upgradesScroll)

--============================================================================
-- Shop tab: every catalog vehicle as a card
--============================================================================

local shopPage = addTab("Shop")

local shopScroll = Instance.new("ScrollingFrame")
shopScroll.Size = UDim2.fromScale(1, 1)
shopScroll.BackgroundTransparency = 1
shopScroll.BorderSizePixel = 0
shopScroll.ScrollBarThickness = 6
shopScroll.ScrollBarImageColor3 = PANEL_EDGE
shopScroll.CanvasSize = UDim2.fromScale(0, 0)
shopScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
shopScroll.Parent = shopPage

local shopGrid = Instance.new("UIGridLayout", shopScroll)
shopGrid.CellSize = UDim2.fromOffset(212, 190)
shopGrid.CellPadding = UDim2.fromOffset(12, 12)
padScroll(shopScroll)

showTab("Garage")

--============================================================================
-- Data
--============================================================================

-- Which owned vehicle the carousel is showing. Not necessarily the server's
-- SelectedVehicleId until the player lands on it - see setCarouselIndex, which
-- fires SelectVehicle the moment they do.
local carouselIndex = 1
local latestData = nil -- last GetPlotData result; card handlers read Money from it

-- Forward-declared: buy/tune handlers re-render after firing a remote, and
-- rendering is what wires those handlers up - mutual recursion, not ordering.
local refreshTerminalData

local function ownedIdsInCatalogOrder(data)
	local ownedSet = {}
	for _, id in data.OwnedVehicleIds do
		ownedSet[id] = true
	end
	local ordered = {}
	for _, id in VehicleCatalog.Order do
		if ownedSet[id] then
			table.insert(ordered, id)
		end
	end
	return ordered
end

-- Falls back to splitting the PascalCase config key if a stat has no
-- DisplayName, so a stat added to a Configs file and not yet named shows as
-- "Brake Friction" rather than as nothing at all.
local function statDisplayName(statName, spec)
	if type(spec.DisplayName) == "string" and spec.DisplayName ~= "" then
		return spec.DisplayName
	end
	return (statName:gsub("(%l)(%u)", "%1 %2"))
end

--============================================================================
-- The upgrade card
--============================================================================

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
-- yet. It replaces V1's draggable slider entirely.
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
	-- GetUpgradeSpecs already warns about a config in that shape.
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

-- Every locked surface in the panel routes here rather than calling
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
	-- behind the pass" and a card that says NEEDS PASS while looking like an
	-- ordinary free card is telling the player two different things at once.
	--
	-- passLocked - passTerritory AND nothing bought in it yet, which is every
	-- gated stat for anyone who started after the pass shipped. No controls at
	-- all: padlock, faded icon, UNLOCK, and no price, because money is not what
	-- is standing in the way and showing one would be a lie.
	--
	-- passTerritory but NOT passLocked - the grandfathered case. Levels bought
	-- with in-game money before the pass existed, so the arrows still work and
	-- the segment bar still shows what was paid for; only buying MORE is shut
	-- off (the NEEDS PASS button below). The server agrees on exactly this
	-- split - see UpgradePasses.CanTune and CanBuy, which are the same two
	-- predicates asked here.
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
	-- Faded, not hidden. On a locked card the picture IS the pitch, so it stays
	-- legible; the padlock over it is what says it is not yours yet.
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
	-- sentence, so it sits on every card including locked ones - a player
	-- deciding whether to spend Robux is exactly who needs to read it.
	local infoButton = Instance.new("TextButton")
	infoButton.Size = UDim2.fromOffset(20, 20)
	infoButton.Position = UDim2.new(1, -26, 0, 6)
	infoButton.BackgroundColor3 = PANEL
	infoButton.BorderSizePixel = 0
	infoButton.AutoButtonColor = false
	infoButton.Font = Enum.Font.GothamBold
	infoButton.TextSize = 13
	infoButton.TextColor3 = DIM_TEXT
	infoButton.Text = "i"
	infoButton.ZIndex = 4
	infoButton.Parent = card
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

	--------------------------------------------------------------------------
	-- Locked by the pass: the whole card is one button that asks for it. No
	-- price and no arrows - nothing that invites a tap which then does nothing.
	--------------------------------------------------------------------------
	if passLocked then
		local unlockButton = Instance.new("TextButton")
		unlockButton.Size = UDim2.new(1, -16, 0, 32)
		unlockButton.Position = UDim2.fromOffset(8, BUTTON_TOP)
		unlockButton.BackgroundColor3 = GOLD
		unlockButton.BorderSizePixel = 0
		unlockButton.Font = Enum.Font.GothamBlack
		unlockButton.TextSize = 14
		unlockButton.TextColor3 = PANEL
		unlockButton.Text = "UNLOCK"
		unlockButton.ZIndex = 3
		unlockButton.Parent = card
		corner(unlockButton, 8)
		unlockButton.MouseButton1Click:Connect(function()
			promptUpgradePass(vehicleId)
		end)

		-- The card body too, not only the button. A child who taps the padlock
		-- or the picture means the same thing as one who taps the word, and
		-- covering only the top 120px leaves the (i) reachable above it and the
		-- UNLOCK button (ZIndex 3) reachable below.
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

	--------------------------------------------------------------------------
	-- Tuning arrows. Secondary by design: buying already applies the new level
	-- (see the buy handler), so these only ever turn an upgrade the player
	-- already owns DOWN and back up. Most players will never touch them, which
	-- is why they are small and greyed out whenever they cannot move.
	--
	-- Turning a stat down is not pointless, which is why they exist at all: a
	-- fragile load over bad ground genuinely wants less power and a softer
	-- ride, and the cargo is what the run pays for.
	--------------------------------------------------------------------------
	local function setLevel(newLevel)
		local clamped = math.clamp(newLevel, 0, unlockedLevel)
		if clamped == currentLevel then
			return
		end
		setCarConfigValueEvent:FireServer(vehicleId, statName, VehicleUpgrades.ValueAtLevel(spec, clamped))
		refreshTerminalData()
	end

	local function makeTuneArrow(text, xOffset, delta)
		local enabled = unlockedLevel > 0
			and ((delta < 0 and currentLevel > 0) or (delta > 0 and currentLevel < unlockedLevel))
		local button = Instance.new("TextButton")
		button.Size = UDim2.fromOffset(28, 28)
		button.Position = UDim2.fromOffset(xOffset, TUNE_ROW_TOP)
		button.BackgroundColor3 = if enabled then PANEL else CARD
		button.BorderSizePixel = 0
		button.AutoButtonColor = enabled
		button.Font = Enum.Font.GothamBold
		button.TextSize = 18
		button.TextColor3 = if enabled then BRIGHT_TEXT else OWNED_SEGMENT
		button.Text = text
		button.Parent = card
		corner(button, 14)
		if enabled then
			button.MouseButton1Click:Connect(function()
				playClickSound()
				setLevel(currentLevel + delta)
			end)
		end
		return button
	end

	makeTuneArrow("-", 6, -1)
	makeTuneArrow("+", CARD_WIDTH - 34, 1)

	--------------------------------------------------------------------------
	-- Buy
	--------------------------------------------------------------------------
	local buyButton = Instance.new("TextButton")
	buyButton.Size = UDim2.new(1, -16, 0, 32)
	buyButton.Position = UDim2.fromOffset(8, BUTTON_TOP)
	buyButton.BorderSizePixel = 0
	buyButton.Font = Enum.Font.GothamBlack
	buyButton.TextSize = 14
	buyButton.AutoButtonColor = false
	buyButton.BackgroundColor3 = LOCKED
	buyButton.TextColor3 = DIM_TEXT
	buyButton.Parent = card
	corner(buyButton, 8)

	if unlockedLevel >= maxLevel then
		buyButton.Text = "MAXED"
		return
	end

	-- Reachable only for a grandfathered gated stat: levels already bought, but
	-- no pass, so it can still be tuned and can no longer be climbed.
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
	buyButton.Text = "$" .. cost

	if (latestData and latestData.Money or 0) < cost then
		-- No click handler at all. The server refuses the purchase anyway, so
		-- wiring one up would only produce a button that silently does nothing.
		return
	end

	buyButton.BackgroundColor3 = ACCENT
	buyButton.TextColor3 = PANEL
	buyButton.AutoButtonColor = true
	buyButton.MouseButton1Click:Connect(function()
		playClickSound()
		-- BuyUpgrade is a RemoteFunction so this blocks until the server has
		-- actually applied the purchase; refreshing only after it returns is
		-- what stops this redraw racing ahead and showing stale levels.
		local bought = buyUpgradeEvent:InvokeServer(vehicleId, statName)
		if bought then
			-- THE FIX V1 NEEDED MOST. Buying used to only unlock a notch,
			-- leaving the car exactly as it was until the player also found and
			-- dragged a slider - so a child's first purchase appeared to do
			-- nothing at all. Turning the new level on immediately makes buying
			-- one action with a visible result; the arrows above are how you
			-- undo it, not how you complete it.
			setCarConfigValueEvent:FireServer(vehicleId, statName, VehicleUpgrades.ValueAtLevel(spec, unlockedLevel + 1))
		end
		refreshTerminalData()
	end)
end

--============================================================================
-- The gold divider between the free upgrades and the paid ones
--============================================================================

local function makePassBanner(vehicleId, ownsPass, layoutOrder)
	local banner = Instance.new("Frame")
	banner.Size = UDim2.new(1, 0, 0, 64)
	banner.BackgroundColor3 = CARD
	banner.BorderSizePixel = 0
	banner.LayoutOrder = layoutOrder
	banner.Parent = upgradesScroll
	corner(banner, 12)
	stroke(banner, if ownsPass then ACCENT else GOLD, 2)

	label(banner, {
		Size = UDim2.fromOffset(44, 64),
		Position = UDim2.fromOffset(10, 0),
		Font = Enum.Font.GothamBold,
		TextSize = 26,
		TextColor3 = if ownsPass then ACCENT else GOLD,
		Text = if ownsPass then TICK_GLYPH else LOCK_GLYPH,
	})

	label(banner, {
		Size = UDim2.new(1, -220, 0, 22),
		Position = UDim2.fromOffset(58, 12),
		Font = Enum.Font.GothamBlack,
		TextSize = 17,
		TextColor3 = if ownsPass then ACCENT else GOLD,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = if ownsPass
			then string.upper(UpgradePasses.DisplayName) .. " - UNLOCKED"
			else string.upper(UpgradePasses.DisplayName),
	})

	-- Says WHAT it does, not what it is. "Unlock 6 more upgrades" is a promise a
	-- child can check against the six gold cards directly underneath it; naming
	-- the stats would be six pieces of jargon in a caption.
	label(banner, {
		Size = UDim2.new(1, -220, 0, 20),
		Position = UDim2.fromOffset(58, 34),
		TextSize = 13,
		TextColor3 = DIM_TEXT,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Text = if ownsPass
			then "Every upgrade on this vehicle is yours to buy."
			else "Unlock 6 more upgrades for this vehicle.",
	})

	if ownsPass then
		return
	end

	local getButton = Instance.new("TextButton")
	getButton.Size = UDim2.fromOffset(132, 40)
	getButton.Position = UDim2.new(1, -148, 0.5, 0)
	getButton.AnchorPoint = Vector2.new(0, 0.5)
	getButton.BackgroundColor3 = GOLD
	getButton.BorderSizePixel = 0
	getButton.Font = Enum.Font.GothamBlack
	getButton.TextSize = 16
	getButton.TextColor3 = PANEL
	getButton.Text = "GET IT"
	getButton.Parent = banner
	corner(getButton, 10)
	getButton.MouseButton1Click:Connect(function()
		promptUpgradePass(vehicleId)
	end)
end

--============================================================================
-- Rendering the garage
--============================================================================

-- Reading order within each half, most immediately understandable first. The
-- free half leads with Torque because acceleration is the upgrade every child
-- feels on the very next drive; the paid half leads with Top Speed for the
-- mirror-image reason - it is the one gated stat that sells the pass on its own
-- (see UpgradePasses' header for the whole split).
local FREE_ORDER = { "Torque", "CargoCapacity", "BodyStrength", "SteerAngle" }
local PAID_ORDER = { "MaxSpeed", "BrakeFriction", "TractionSlipThreshold", "Stiffness", "Damper", "SuspensionMaxLength" }

-- Anything a Configs file adds later that this file has not been told about
-- still appears, at the end of whichever half UpgradePasses says it belongs to,
-- alphabetically - rather than silently vanishing from the terminal.
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

local function clearUpgrades()
	for _, child in upgradesScroll:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function renderGarageForVehicle(data, vehicleId)
	local def = VehicleCatalog.Get(vehicleId)
	vehicleNameLabel.Text = def and def.DisplayName or vehicleId
	carImage.Image = def and def.ImageId or ""
	carImagePlaceholder.Visible = not (def and def.ImageId and def.ImageId ~= "")

	clearUpgrades()

	-- THE TUTORIAL'S FIRST MINUTE. A brand-new player is being told to press one
	-- button, and everything else on this panel is noise competing with that
	-- instruction - noise the tutorial's own banner is partly sitting on top of
	-- anyway. So the upgrade section does not exist yet. The intended shape of
	-- the opening is: spawn a car, drive it, earn money, and only THEN come back
	-- wondering what the money is for. A child who meets ten upgrade cards
	-- before their first delivery skips the whole thing.
	--
	-- Read off the attribute TutorialGuide publishes, NOT off data.TutorialDone.
	-- The save flag answers "has this player ever finished it", which is a
	-- different question and wrong in both directions: replaying from the
	-- settings menu runs the tutorial with the flag already true, and
	-- flushPlayerData sets the flag on every disconnect, so from a player's
	-- second session on it is true forever. Keying off it meant the upgrades
	-- showed straight through the tutorial for everybody except a genuine
	-- first-timer. See TUTORIAL_ACTIVE_ATTRIBUTE in TutorialGuide.client.luau.
	local tutorialActive = isTutorialActive()
	upgradesScroll.Visible = not tutorialActive
	if tutorialActive then
		return
	end

	local specs = def and VehiclePhysics.GetUpgradeSpecs(def.TemplateName)
	if not specs then
		return
	end

	local levels = data.UpgradeLevels[vehicleId] or {}
	local configValues = data.CarConfigs[vehicleId] or {}
	-- The server's answer, not a guess made here: PlotManager resolves game-pass
	-- ownership and carries it on this same round trip (see its GetPlotData).
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

local function setCarouselIndex(data, index)
	local ordered = ownedIdsInCatalogOrder(data)
	if #ordered == 0 then
		vehicleNameLabel.Text = "--"
		carImage.Image = ""
		carImagePlaceholder.Visible = false
		clearUpgrades()
		return
	end
	carouselIndex = ((index - 1) % #ordered) + 1
	local vehicleId = ordered[carouselIndex]
	renderGarageForVehicle(data, vehicleId)
	if data.SelectedVehicleId ~= vehicleId then
		selectVehicleEvent:FireServer(vehicleId)
	end
end

prevButton.MouseButton1Click:Connect(function()
	playClickSound()
	if latestData then
		setCarouselIndex(latestData, carouselIndex - 1)
	end
end)
nextButton.MouseButton1Click:Connect(function()
	playClickSound()
	if latestData then
		setCarouselIndex(latestData, carouselIndex + 1)
	end
end)

--============================================================================
-- Shop cards
--============================================================================

local function makeShopCard(data, vehicleId, ownedSet)
	local def = VehicleCatalog.Get(vehicleId)
	if not def then
		return
	end

	local card = Instance.new("Frame")
	card.BackgroundColor3 = CARD
	card.BorderSizePixel = 0
	card.Parent = shopScroll
	corner(card, 12)
	stroke(card, CARD_EDGE)

	local image = Instance.new("ImageLabel")
	image.Size = UDim2.new(1, -16, 0, 100)
	image.Position = UDim2.fromOffset(8, 8)
	image.BackgroundColor3 = PANEL
	image.BorderSizePixel = 0
	image.ScaleType = Enum.ScaleType.Fit
	image.Image = def.ImageId or ""
	image.Parent = card
	corner(image, 8)

	if not (def.ImageId and def.ImageId ~= "") then
		label(image, {
			Size = UDim2.fromScale(1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 13,
			TextColor3 = DIM_TEXT,
			TextWrapped = true,
			Text = "Image Coming Soon",
			ZIndex = 2,
		})
	end

	label(card, {
		Size = UDim2.new(1, -16, 0, 22),
		Position = UDim2.fromOffset(8, 112),
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = def.DisplayName,
	})

	local buyButton = Instance.new("TextButton")
	buyButton.Size = UDim2.new(1, -16, 0, 32)
	buyButton.Position = UDim2.fromOffset(8, 144)
	buyButton.BorderSizePixel = 0
	buyButton.Font = Enum.Font.GothamBold
	buyButton.TextSize = 14
	buyButton.AutoButtonColor = false
	buyButton.BackgroundColor3 = LOCKED
	buyButton.TextColor3 = DIM_TEXT
	buyButton.Parent = card
	corner(buyButton, 8)

	if ownedSet[vehicleId] then
		local stamp = label(image, {
			Size = UDim2.fromOffset(150, 34),
			Position = UDim2.new(0.5, 0, 0, 46),
			AnchorPoint = Vector2.new(0.5, 0),
			Rotation = -18,
			Font = Enum.Font.GothamBlack,
			TextSize = 28,
			TextColor3 = STAMP_RED,
			TextTransparency = 0.15,
			Text = "OWNED",
			ZIndex = 5,
		})
		stroke(stamp, STAMP_RED, 2)
		buyButton.Text = "Owned"
		return
	end

	-- A vehicle has TWO prices, money and lifetime deliveries (see
	-- VehicleCatalog's header). The deliveries one is checked first because it
	-- is the one the player cannot fix by driving to the bank: a card they can
	-- afford but are not yet allowed to buy has to say so, or it looks broken.
	local requiredDeliveries = VehicleCatalog.RequiredDeliveries(def)
	local deliveries = data.Deliveries or 0

	if deliveries < requiredDeliveries then
		-- Greyed and captioned rather than hidden. A vehicle nobody can see is a
		-- vehicle nobody is working toward, and this ladder only does anything
		-- if the player knows what is at the top of it.
		local veil = Instance.new("Frame")
		veil.Size = UDim2.fromScale(1, 1)
		veil.BackgroundColor3 = PANEL
		veil.BackgroundTransparency = 0.25
		veil.BorderSizePixel = 0
		veil.ZIndex = 3
		veil.Parent = image
		corner(veil, 8)

		label(veil, {
			Size = UDim2.fromScale(1, 1),
			Font = Enum.Font.GothamBold,
			TextSize = 16,
			TextWrapped = true,
			ZIndex = 4,
			Text = "Requires\n" .. ProgressionConfig.DeliveryCountText(requiredDeliveries),
		})

		-- The requirement on the veil, the distance still to go on the button,
		-- both in deliveries - the same unit as the player's own count in the
		-- header, so there is nothing to convert and no second number to learn.
		buyButton.Text = ProgressionConfig.DeliveryCountText(requiredDeliveries - deliveries) .. " to go"
		return
	end

	buyButton.Text = "Buy $" .. def.Price
	if data.Money < def.Price then
		return -- priced, but no handler; the server would refuse it anyway
	end

	buyButton.BackgroundColor3 = ACCENT
	buyButton.TextColor3 = PANEL
	buyButton.AutoButtonColor = true
	buyButton.MouseButton1Click:Connect(function()
		playClickSound()
		buyVehicleEvent:FireServer(vehicleId)
		refreshTerminalData()
	end)
end

local function renderShop(data)
	for _, child in shopScroll:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local ownedSet = {}
	for _, id in data.OwnedVehicleIds do
		ownedSet[id] = true
	end
	for _, vehicleId in VehicleCatalog.Order do
		makeShopCard(data, vehicleId, ownedSet)
	end
end

refreshTerminalData = function()
	local data = getPlotDataFunction:InvokeServer()
	if not data then
		return
	end
	latestData = data

	moneyLabel.Text = "$" .. tostring(data.Money)
	deliveriesLabel.Text = ProgressionConfig.DeliveryCountText(data.Deliveries or 0) .. " completed"

	local ordered = ownedIdsInCatalogOrder(data)
	local selectedIndex = 1
	for i, id in ordered do
		if id == data.SelectedVehicleId then
			selectedIndex = i
			break
		end
	end
	carouselIndex = math.clamp(selectedIndex, 1, math.max(#ordered, 1))
	if ordered[carouselIndex] then
		renderGarageForVehicle(data, ordered[carouselIndex])
	else
		clearUpgrades()
	end

	-- Nothing to cycle to with one car; arrows that can never do anything just
	-- invite clicking them to find out why.
	local canCycle = #ordered > 1
	prevButton.Visible = canCycle
	nextButton.Visible = canCycle

	renderShop(data)
end

-- The tutorial just started or ended while the panel was open. Redrawing rather
-- than only toggling upgradesScroll.Visible because the render is what decides
-- whether the cards exist at all - and this way the upgrades appear the instant
-- the tutorial's last step is satisfied, rather than the next time the player
-- happens to reopen the terminal.
player:GetAttributeChangedSignal(TUTORIAL_ACTIVE_ATTRIBUTE):Connect(function()
	if screenGui.Enabled then
		refreshTerminalData()
	end
end)

-- The pass just got bought. BOTH this client and the server hear this event and
-- nothing orders them, so a redraw fired on the same frame can beat the server's
-- own cache update and come back still locked - which, to the player, reads as
-- having paid for nothing. The delay is what makes the redraw see the purchase.
-- Worst case if it is still not through, the panel is one manual reopen away
-- from correct, because GetPlotData is the only thing that knows the answer.
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

-- THE MOUSE, in first person: Roblox's camera controller re-locks MouseBehavior
-- to LockCenter every frame, so setting it once on open does not stick and the
-- cursor stays pinned to the middle of the screen - on top of this panel, where
-- the player then cannot move it off to reach anything. Re-asserting Default
-- every frame at RenderPriority.Last (same fix and same reasoning as
-- SettingsMenu.client.luau's applyMouseState) means this script's value is the
-- one still standing after the camera has had its say.
local MOUSE_STEP = "PlotTerminalV2Mouse"

local function applyMouseState()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

local function openTerminal()
	refreshTerminalData()
	screenGui.Enabled = true
	RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Last.Value, applyMouseState)
end

closeTerminal = function()
	screenGui.Enabled = false
	hideInfoModal()
	RunService:UnbindFromRenderStep(MOUSE_STEP)
	-- Hand control back rather than forcing LockCenter ourselves: the camera
	-- controller re-locks on its own next frame if the player is in first person.
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

closeButton.MouseButton1Click:Connect(function()
	playClickSound()
	closeTerminal()
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.Escape or not screenGui.Enabled then
		return
	end
	-- Escape backs out one layer at a time. Closing the whole terminal from
	-- inside the info modal would throw away the card the player was reading
	-- about, which is never what Escape meant.
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
			return PlotOwnership.IsOwner(player, plotModel)
		end,
	})
	openPrompt.Triggered:Connect(openTerminal)

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
			warn("PlotTerminal_V2: gave up waiting for " .. plotModel:GetFullName() .. " to have a Terminal.Screen")
		end
	end)
end

--============================================================================
-- Claim feedback sound
--============================================================================

-- Watches the attribute rather than hooking claimPrompt.Triggered: Triggered
-- only means a claim request was SENT, not that the server accepted it (too far
-- away, already hold a plot, someone else got there first). OwnerUserId actually
-- turning into MY id is the one unambiguous signal that the claim went through.
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

-- Client side of the garage plot terminals: shows a CustomPrompt (see
-- CustomPrompt.luau's header for why not a real ProximityPrompt) at each
-- plot's Terminal.Screen, and the management GUI that opens once you're
-- standing at your own claimed plot.
--
-- Nothing here is a security boundary - claiming, spawning and selecting a
-- vehicle are all re-checked server-side in PlotManager.server.luau. This
-- script only decides what to show and fires the remotes it decides on.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")

local CustomPrompt = require(ReplicatedStorage.Modules.UI.CustomPrompt)
local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)
local VehicleCatalog = require(ReplicatedStorage.Modules.Vehicles.VehicleCatalog)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleUpgrades = require(ReplicatedStorage.Modules.Vehicles.VehicleUpgrades)

local player = Players.LocalPlayer

-- WaitForChild, not direct indexing: Workspace isn't guaranteed to have
-- replicated to this client the instant PlayerScripts starts running (see
-- VehicleDoorPrompts.client.luau's header for the same caveat) - a direct
-- `workspace.Spawn.VehiclePlots` here would throw and kill this entire
-- script before a single prompt got created, with no visible symptom beyond
-- "nothing ever shows up".
local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")

local claimPlotEvent = ReplicatedStorage:WaitForChild("ClaimPlot")
local spawnVehicleEvent = ReplicatedStorage:WaitForChild("SpawnVehicle")
local selectVehicleEvent = ReplicatedStorage:WaitForChild("SelectVehicle")
local getPlotDataFunction = ReplicatedStorage:WaitForChild("GetPlotData")
local buyVehicleEvent = ReplicatedStorage:WaitForChild("BuyVehicle")
local buyUpgradeEvent = ReplicatedStorage:WaitForChild("BuyUpgrade")
local setCarConfigValueEvent = ReplicatedStorage:WaitForChild("SetCarConfigValue")

-- Matches CustomPrompt.luau / VehicleDashboard's dark-panel palette so this
-- reads as the same UI system rather than a one-off.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local TAB_OFF = Color3.fromRGB(28, 31, 38)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)
local LOCKED = Color3.fromRGB(48, 52, 62)
local STAMP_RED = Color3.fromRGB(214, 76, 76)

--============================================================================
-- Sound
--============================================================================

-- Reusable one-shot local sound player. PlayLocalSound plays without ever
-- putting the Sound instance into the DataModel, so this is inherently
-- client-only (nobody else hears it) and needs no Workspace cleanup.
local function playSound(soundId)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	SoundService:PlayLocalSound(sound)
end

local CLAIM_SOUND_ID = "rbxassetid://90420386076500"
local playClaimSound = function()
	playSound(CLAIM_SOUND_ID)
end

-- Fires on every button press inside the terminal (tabs, spawn, buy/upgrade,
-- carousel arrows, the info modal, close) - deliberately NOT on every click
-- while the terminal is open, which would include drag-slider input and
-- would read as noise rather than feedback. A click-only cue on the actions
-- that actually DO something is what makes it feel like confirmation instead
-- of a distraction.
local TERMINAL_CLICK_SOUND_ID = "rbxassetid://127105730240202"
local function playClickSound()
	playSound(TERMINAL_CLICK_SOUND_ID)
end

--============================================================================
-- Whether the local player already owns a plot (claiming is one-per-server -
-- see PlotManager.server.luau's header)
--============================================================================

local function localPlayerOwnsAnyPlot()
	for _, plotModel in VehiclePlotsFolder:GetChildren() do
		if PlotOwnership.GetOwnerUserId(plotModel) == player.UserId then
			return true
		end
	end
	return false
end

--============================================================================
-- Terminal GUI (opened at the plot the local player owns)
--============================================================================

-- Forward-declared: several buttons built below (spawn, the info modal's own
-- backdrop) close the terminal on click, but the actual closeTerminal
-- function isn't defined until after refreshTerminalData near the bottom of
-- this section. Assigning it there (rather than declaring it there) is what
-- lets everything above already reference the same upvalue.
local closeTerminal

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlotTerminalGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = player:WaitForChild("PlayerGui")

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(720, 700)
main.Position = UDim2.fromScale(0.5, 0.5)
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.BackgroundColor3 = PANEL
main.BorderSizePixel = 0
main.Parent = screenGui

Instance.new("UICorner", main).CornerRadius = UDim.new(0, 12)
local mainEdge = Instance.new("UIStroke", main)
mainEdge.Color = PANEL_EDGE

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -110, 0, 40)
title.Position = UDim2.fromOffset(20, 12)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 20
title.TextColor3 = BRIGHT_TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Garage Terminal"
title.Parent = main

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(32, 32)
closeButton.Position = UDim2.new(1, -44, 0, 12)
closeButton.BackgroundColor3 = TAB_OFF
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 16
closeButton.TextColor3 = BRIGHT_TEXT
closeButton.Text = "X"
closeButton.Parent = main
Instance.new("UICorner", closeButton).CornerRadius = UDim.new(0, 8)

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -40, 0, 34)
tabBar.Position = UDim2.fromOffset(20, 60)
tabBar.BackgroundTransparency = 1
tabBar.Parent = main

local tabLayout = Instance.new("UIListLayout", tabBar)
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 8)

-- Sibling of tabBar, not a child of it - tabBar's own UIListLayout would
-- otherwise pack this in right after the tab buttons instead of pinning it
-- to the row's far edge. Lives on the tab row (rather than up by the title,
-- where it used to be) because that row was overlapping the close button at
-- the terminal's new, wider size.
local moneyLabel = Instance.new("TextLabel")
moneyLabel.Size = UDim2.fromOffset(160, 34)
moneyLabel.Position = UDim2.new(1, -176, 0, 60)
moneyLabel.BackgroundTransparency = 1
moneyLabel.Font = Enum.Font.GothamBold
moneyLabel.TextSize = 18
moneyLabel.TextColor3 = ACCENT
moneyLabel.TextXAlignment = Enum.TextXAlignment.Right
moneyLabel.TextYAlignment = Enum.TextYAlignment.Center
moneyLabel.Text = "$0"
moneyLabel.Parent = main

local contentFrame = Instance.new("Frame")
contentFrame.Size = UDim2.new(1, -40, 1, -110)
contentFrame.Position = UDim2.fromOffset(20, 104)
contentFrame.BackgroundTransparency = 1
contentFrame.Parent = main

--============================================================================
-- Upgrade info modal - the (i) button on each slider row (see makeSliderRow)
-- opens this with that stat's plain-language Description from its
-- Configs/<Name>.luau spec.
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
infoPanel.Size = UDim2.fromOffset(380, 210)
infoPanel.Position = UDim2.fromScale(0.5, 0.5)
infoPanel.AnchorPoint = Vector2.new(0.5, 0.5)
infoPanel.BackgroundColor3 = PANEL
infoPanel.BorderSizePixel = 0
infoPanel.ZIndex = 11
infoPanel.Parent = infoModal
Instance.new("UICorner", infoPanel).CornerRadius = UDim.new(0, 12)
Instance.new("UIStroke", infoPanel).Color = PANEL_EDGE

local infoTitle = Instance.new("TextLabel")
infoTitle.Size = UDim2.new(1, -60, 0, 30)
infoTitle.Position = UDim2.fromOffset(20, 16)
infoTitle.BackgroundTransparency = 1
infoTitle.Font = Enum.Font.GothamBold
infoTitle.TextSize = 18
infoTitle.TextColor3 = BRIGHT_TEXT
infoTitle.TextXAlignment = Enum.TextXAlignment.Left
infoTitle.ZIndex = 11
infoTitle.Text = ""
infoTitle.Parent = infoPanel

local infoCloseButton = Instance.new("TextButton")
infoCloseButton.Size = UDim2.fromOffset(28, 28)
infoCloseButton.Position = UDim2.new(1, -44, 0, 14)
infoCloseButton.BackgroundColor3 = TAB_OFF
infoCloseButton.BorderSizePixel = 0
infoCloseButton.Font = Enum.Font.GothamBold
infoCloseButton.TextSize = 14
infoCloseButton.TextColor3 = BRIGHT_TEXT
infoCloseButton.Text = "X"
infoCloseButton.ZIndex = 11
infoCloseButton.Parent = infoPanel
Instance.new("UICorner", infoCloseButton).CornerRadius = UDim.new(0, 6)

local infoDescription = Instance.new("TextLabel")
infoDescription.Size = UDim2.new(1, -40, 1, -70)
infoDescription.Position = UDim2.fromOffset(20, 56)
infoDescription.BackgroundTransparency = 1
infoDescription.Font = Enum.Font.Gotham
infoDescription.TextSize = 14
infoDescription.TextColor3 = DIM_TEXT
infoDescription.TextWrapped = true
infoDescription.TextXAlignment = Enum.TextXAlignment.Left
infoDescription.TextYAlignment = Enum.TextYAlignment.Top
infoDescription.ZIndex = 11
infoDescription.Text = ""
infoDescription.Parent = infoPanel

local function hideInfoModal()
	infoModal.Visible = false
end

local function showInfoModal(title, description)
	infoTitle.Text = title
	infoDescription.Text = description ~= "" and description or "No description available for this upgrade yet."
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

local tabs = {} -- [name] = { Button, Page }
local activeTabName = nil

local function makeTabButton(name)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(120, 34)
	button.BackgroundColor3 = TAB_OFF
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 14
	button.TextColor3 = DIM_TEXT
	button.Text = name
	button.Parent = tabBar
	Instance.new("UICorner", button).CornerRadius = UDim.new(0, 8)
	return button
end

local function makePage()
	local page = Instance.new("Frame")
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.Visible = false
	page.Parent = contentFrame
	return page
end

local function showTab(name)
	if activeTabName == name then
		return
	end
	activeTabName = name
	for tabName, entry in tabs do
		local isActive = tabName == name
		entry.Page.Visible = isActive
		entry.Button.BackgroundColor3 = if isActive then ACCENT else TAB_OFF
		entry.Button.TextColor3 = if isActive then PANEL else DIM_TEXT
	end
end

local function addTab(name)
	local button = makeTabButton(name)
	local page = makePage()
	tabs[name] = { Button = button, Page = page }
	button.MouseButton1Click:Connect(function()
		playClickSound()
		showTab(name)
	end)
	return page
end

--- Garage tab: carousel of owned cars + upgrade sliders for whichever one --
--- the carousel is currently showing. Replaces the old separate Vehicle and
--- Upgrades tabs - upgrades are inherently per-car, so browsing cars and
--- tuning them belongs in one place instead of two that have to stay synced.

local garagePage = addTab("Garage")

local carousel = Instance.new("Frame")
carousel.Size = UDim2.new(1, 0, 0, 190)
carousel.BackgroundTransparency = 1
carousel.Parent = garagePage

local carImage = Instance.new("ImageLabel")
carImage.Size = UDim2.fromOffset(220, 130)
carImage.Position = UDim2.new(0.5, 0, 0, 0)
carImage.AnchorPoint = Vector2.new(0.5, 0)
carImage.BackgroundColor3 = TAB_OFF
carImage.BorderSizePixel = 0
carImage.ScaleType = Enum.ScaleType.Fit
carImage.Parent = carousel
Instance.new("UICorner", carImage).CornerRadius = UDim.new(0, 10)

local function makeArrowButton(text)
	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(36, 36)
	button.Position = UDim2.new(0.5, 0, 0, 47)
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.BackgroundColor3 = TAB_OFF
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.TextColor3 = BRIGHT_TEXT
	button.Text = text
	button.Parent = carousel
	Instance.new("UICorner", button).CornerRadius = UDim.new(1, 0)
	return button
end

local prevButton = makeArrowButton("<")
prevButton.Position = UDim2.new(0.5, -240, 0, 47)
local nextButton = makeArrowButton(">")
nextButton.Position = UDim2.new(0.5, 204, 0, 47)

local vehicleNameLabel = Instance.new("TextLabel")
vehicleNameLabel.Size = UDim2.new(1, 0, 0, 26)
vehicleNameLabel.Position = UDim2.fromOffset(0, 136)
vehicleNameLabel.BackgroundTransparency = 1
vehicleNameLabel.Font = Enum.Font.GothamBold
vehicleNameLabel.TextSize = 18
vehicleNameLabel.TextColor3 = BRIGHT_TEXT
vehicleNameLabel.Text = "--"
vehicleNameLabel.Parent = carousel

local spawnButton = Instance.new("TextButton")
spawnButton.Size = UDim2.fromOffset(160, 30)
spawnButton.Position = UDim2.new(0.5, 0, 0, 162)
spawnButton.AnchorPoint = Vector2.new(0.5, 0)
spawnButton.BackgroundColor3 = ACCENT
spawnButton.BorderSizePixel = 0
spawnButton.Font = Enum.Font.GothamBold
spawnButton.TextSize = 14
spawnButton.TextColor3 = PANEL
spawnButton.Text = "Spawn Vehicle"
spawnButton.Parent = carousel
Instance.new("UICorner", spawnButton).CornerRadius = UDim.new(0, 8)
spawnButton.MouseButton1Click:Connect(function()
	playClickSound()
	spawnVehicleEvent:FireServer()
	-- Nothing left to do at the terminal once the car's out - closing means
	-- the player isn't stuck clicking X before they can actually go drive.
	closeTerminal()
end)

local upgradesScroll = Instance.new("ScrollingFrame")
upgradesScroll.Size = UDim2.new(1, 0, 1, -198)
upgradesScroll.Position = UDim2.fromOffset(0, 198)
upgradesScroll.BackgroundTransparency = 1
upgradesScroll.BorderSizePixel = 0
upgradesScroll.ScrollBarThickness = 6
upgradesScroll.ScrollBarImageColor3 = PANEL_EDGE
upgradesScroll.CanvasSize = UDim2.fromScale(0, 0) -- grown by UIListLayout below
upgradesScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
upgradesScroll.Parent = garagePage

local upgradesLayout = Instance.new("UIListLayout", upgradesScroll)
upgradesLayout.Padding = UDim.new(0, 8)

--- Shop tab: every catalog vehicle as a grid card, OWNED stamped over what --
--- the player already has, Buy priced for what they don't.

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
shopGrid.CellSize = UDim2.fromOffset(176, 168)
shopGrid.CellPadding = UDim2.fromOffset(10, 10)

showTab("Garage")

--============================================================================
-- Populating the Garage + Shop tabs from server data
--============================================================================

-- Which owned vehicle the carousel is currently showing. Not necessarily the
-- same as the server's SelectedVehicleId until the player actually lands on
-- it - see setCarouselIndex, which fires SelectVehicle the moment they do.
local carouselIndex = 1
local latestData = nil -- last GetPlotData result, so drag/buy handlers don't need to re-fetch

-- Forward-declared: several handlers below (buy/upgrade/slider) need to
-- re-render after firing a remote, and rendering itself wires up those same
-- handlers - mutual recursion, not just ordering.
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

local function formatStatValue(value)
	-- Whole numbers read cleaner without a decimal (e.g. Torque "30" not
	-- "30.0"), but a stat like SuspensionMaxLength genuinely needs one
	-- (3.5, 3.75, ...) or every notch above the first would look identical.
	if value == math.floor(value) then
		return string.format("%d", value)
	end
	return string.format("%.2f", value)
end

local function makeSliderRow(vehicleId, statName, spec, unlockedLevel, currentValue)
	local locked = unlockedLevel <= 0

	local row = Instance.new("Frame")
	-- Locked rows are taller - they carry an extra hint line explaining WHY
	-- the slider isn't draggable (see below), which is the whole point: a
	-- flat, unlabelled bar that just doesn't respond to a drag reads as
	-- broken, not as "buy something first".
	row.Size = UDim2.new(1, 0, 0, if locked then 76 else 56)
	row.BackgroundColor3 = TAB_OFF
	row.BorderSizePixel = 0
	row.Parent = upgradesScroll
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
	local padding = Instance.new("UIPadding", row)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.PaddingTop = UDim.new(0, 8)

	local maxLevel = VehicleUpgrades.MaxLevel(spec)
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(0.6, 0, 0, 18)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 13
	nameLabel.TextColor3 = if locked then DIM_TEXT else BRIGHT_TEXT
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Text = (if locked then "\u{1F512} " else "") .. statName .. "  -  " .. formatStatValue(currentValue)
	nameLabel.Parent = row

	local buyButton = Instance.new("TextButton")
	buyButton.Size = UDim2.fromOffset(120, 22)
	buyButton.Position = UDim2.new(1, -120, 0, -2)
	buyButton.BackgroundColor3 = if unlockedLevel >= maxLevel then LOCKED else ACCENT
	buyButton.BorderSizePixel = 0
	buyButton.Font = Enum.Font.GothamBold
	buyButton.TextSize = 12
	buyButton.TextColor3 = if unlockedLevel >= maxLevel then DIM_TEXT else PANEL
	buyButton.AutoButtonColor = unlockedLevel < maxLevel
	if unlockedLevel >= maxLevel then
		buyButton.Text = "MAXED"
	else
		buyButton.Text = "Upgrade $" .. VehicleUpgrades.CostForLevel(spec, unlockedLevel + 1)
	end
	buyButton.Parent = row
	Instance.new("UICorner", buyButton).CornerRadius = UDim.new(0, 6)
	buyButton.MouseButton1Click:Connect(function()
		if unlockedLevel >= maxLevel then
			return
		end
		playClickSound()
		buyUpgradeEvent:FireServer(vehicleId, statName)
		refreshTerminalData()
	end)

	-- (i) info button - opens showInfoModal with this stat's plain-language
	-- Description from its Configs/<Name>.luau spec. Pinned a fixed offset to
	-- the LEFT of buyButton (rather than right after nameLabel, whose actual
	-- rendered width depends on AbsoluteSize) so the gap between them stays
	-- consistent regardless of row width.
	local infoButton = Instance.new("TextButton")
	infoButton.Size = UDim2.fromOffset(22, 22)
	infoButton.Position = UDim2.new(1, -150, 0, -2)
	infoButton.BackgroundColor3 = TAB_OFF
	infoButton.BorderSizePixel = 0
	infoButton.AutoButtonColor = false
	infoButton.Font = Enum.Font.GothamBold
	infoButton.TextSize = 13
	infoButton.TextColor3 = DIM_TEXT
	infoButton.Text = "i"
	infoButton.Parent = row
	Instance.new("UICorner", infoButton).CornerRadius = UDim.new(1, 0)

	infoButton.MouseEnter:Connect(function()
		infoButton.BackgroundColor3 = ACCENT
		infoButton.TextColor3 = PANEL
	end)
	infoButton.MouseLeave:Connect(function()
		infoButton.BackgroundColor3 = TAB_OFF
		infoButton.TextColor3 = DIM_TEXT
	end)
	infoButton.MouseButton1Click:Connect(function()
		playClickSound()
		showInfoModal(statName, spec.Description or "")
	end)

	-- Track: a thin bar the knob rides along. Filled portion shows how far
	-- the CURRENT value sits toward Max; the unlocked portion (up to
	-- unlockedLevel) is what's actually draggable, everything past it stays
	-- LOCKED-coloured to show there's more of this stat to buy.
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 10)
	track.Position = UDim2.fromOffset(0, 30)
	track.BackgroundColor3 = LOCKED
	track.BackgroundTransparency = if locked then 0.35 else 0
	track.BorderSizePixel = 0
	track.Parent = row
	Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

	if locked then
		-- No knob, no fill, nothing that reads as "grab this and drag it" -
		-- the empty dashed-look track plus the hint line below it is the
		-- whole message: there's nothing to drag YET. A knob sitting at the
		-- far left of an otherwise-normal-looking slider is exactly what
		-- made this feel broken before - it invited a drag that silently did
		-- nothing.
		local hint = Instance.new("TextLabel")
		hint.Size = UDim2.new(1, 0, 0, 16)
		hint.Position = UDim2.fromOffset(0, 46)
		hint.BackgroundTransparency = 1
		hint.Font = Enum.Font.Gotham
		hint.TextSize = 11
		hint.TextColor3 = DIM_TEXT
		hint.TextXAlignment = Enum.TextXAlignment.Left
		hint.Text = "Buy an upgrade above to unlock this slider"
		hint.Parent = row
		return
	end

	local unlockedFraction = if maxLevel > 0 then unlockedLevel / maxLevel else 1
	local unlockedFill = Instance.new("Frame")
	unlockedFill.Size = UDim2.new(unlockedFraction, 0, 1, 0)
	unlockedFill.BackgroundColor3 = Color3.fromRGB(70, 76, 90)
	unlockedFill.BorderSizePixel = 0
	unlockedFill.ZIndex = 2
	unlockedFill.Parent = track
	Instance.new("UICorner", unlockedFill).CornerRadius = UDim.new(1, 0)

	local currentFraction = (currentValue - spec.Min) / (spec.Max - spec.Min)
	local valueFill = Instance.new("Frame")
	valueFill.Size = UDim2.new(currentFraction, 0, 1, 0)
	valueFill.BackgroundColor3 = ACCENT
	valueFill.BorderSizePixel = 0
	valueFill.ZIndex = 3
	valueFill.Parent = track
	Instance.new("UICorner", valueFill).CornerRadius = UDim.new(1, 0)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(16, 16)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(currentFraction, 0, 0.5, 0)
	knob.BackgroundColor3 = BRIGHT_TEXT
	knob.BorderSizePixel = 0
	knob.ZIndex = 4
	knob.Parent = track
	Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)

	local dragging = false
	local function updateFromInputX(inputX)
		local fraction = math.clamp((inputX - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
		local rawValue = spec.Min + fraction * (spec.Max - spec.Min)
		local snapped = VehicleUpgrades.NearestUnlockedValue(spec, unlockedLevel, rawValue)
		local snappedFraction = (snapped - spec.Min) / (spec.Max - spec.Min)
		valueFill.Size = UDim2.new(snappedFraction, 0, 1, 0)
		knob.Position = UDim2.new(snappedFraction, 0, 0.5, 0)
		nameLabel.Text = statName .. "  -  " .. formatStatValue(snapped)
		return snapped
	end

	local function beginDrag(inputX)
		dragging = true
		local snapped = updateFromInputX(inputX)
		setCarConfigValueEvent:FireServer(vehicleId, statName, snapped)
	end

	track.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input.Position.X)
		end
	end)
	knob.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			beginDrag(input.Position.X)
		end
	end)

	-- These two are connected on UserInputService rather than track/knob
	-- because a drag has to keep tracking the mouse even once it's moved off
	-- the (thin, 10px-tall) track - but that means they're NOT scoped to this
	-- row's lifetime the way GuiObject:Connect calls are, since Destroying a
	-- row doesn't touch a UserInputService listener closed over it. Every
	-- refreshTerminalData() rebuilds every row, so without explicitly
	-- disconnecting these on Destroying, each refresh would leak two more
	-- global listeners forever, each holding this row's (by-then-destroyed)
	-- track/knob/spec alive.
	local inputChangedConn, inputEndedConn
	inputChangedConn = UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			updateFromInputX(input.Position.X)
		end
	end)
	inputEndedConn = UserInputService.InputEnded:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
			-- Fire the final snapped value once more in case InputChanged
			-- never fired between InputBegan and this (a plain click, no
			-- drag) - beginDrag already sent one, but sending the same value
			-- again is harmless and guarantees the server and slider agree.
			local fraction = (knob.Position.X.Scale)
			local value = spec.Min + fraction * (spec.Max - spec.Min)
			setCarConfigValueEvent:FireServer(vehicleId, statName, value)
		end
	end)
	row.Destroying:Connect(function()
		inputChangedConn:Disconnect()
		inputEndedConn:Disconnect()
	end)
end

local function renderGarageForVehicle(data, vehicleId)
	local def = VehicleCatalog.Get(vehicleId)
	vehicleNameLabel.Text = def and def.DisplayName or vehicleId
	carImage.Image = def and def.ImageId or ""

	for _, child in upgradesScroll:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local rawConfig = def and VehiclePhysics.GetRawConfig(def.TemplateName)
	local specs = rawConfig and rawConfig.Upgrades
	if not specs then
		return
	end
	local levels = data.UpgradeLevels[vehicleId] or {}
	local configValues = data.CarConfigs[vehicleId] or {}
	-- VehicleCatalog doesn't define a stat display order, so fall back to a
	-- stable alphabetical one rather than Lua's unspecified table order,
	-- which would otherwise reshuffle the list on every refresh.
	local statNames = {}
	for statName in specs do
		table.insert(statNames, statName)
	end
	table.sort(statNames)

	for _, statName in statNames do
		local spec = specs[statName]
		local unlockedLevel = VehicleUpgrades.ClampLevel(spec, levels[statName] or 0)
		local currentValue = configValues[statName] or spec.Min
		makeSliderRow(vehicleId, statName, spec, unlockedLevel, currentValue)
	end
end

local function setCarouselIndex(data, index)
	local ordered = ownedIdsInCatalogOrder(data)
	if #ordered == 0 then
		vehicleNameLabel.Text = "--"
		carImage.Image = ""
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

local function makeShopCard(data, vehicleId, ownedSet)
	local def = VehicleCatalog.Get(vehicleId)
	if not def then
		return
	end
	local owned = ownedSet[vehicleId] == true

	local card = Instance.new("Frame")
	card.BackgroundColor3 = TAB_OFF
	card.BorderSizePixel = 0
	card.Parent = shopScroll
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 10)

	local image = Instance.new("ImageLabel")
	image.Size = UDim2.new(1, -16, 0, 88)
	image.Position = UDim2.fromOffset(8, 8)
	image.BackgroundColor3 = PANEL
	image.BorderSizePixel = 0
	image.ScaleType = Enum.ScaleType.Fit
	image.Image = def.ImageId or ""
	image.Parent = card
	Instance.new("UICorner", image).CornerRadius = UDim.new(0, 8)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -16, 0, 20)
	nameLabel.Position = UDim2.fromOffset(8, 100)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 14
	nameLabel.TextColor3 = BRIGHT_TEXT
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Text = def.DisplayName
	nameLabel.Parent = card

	if owned then
		local stamp = Instance.new("TextLabel")
		stamp.Size = UDim2.fromOffset(140, 32)
		stamp.Position = UDim2.new(0.5, 0, 0, 44)
		stamp.AnchorPoint = Vector2.new(0.5, 0)
		stamp.Rotation = -18
		stamp.BackgroundTransparency = 1
		stamp.Font = Enum.Font.GothamBlack
		stamp.TextSize = 26
		stamp.TextColor3 = STAMP_RED
		stamp.TextTransparency = 0.15
		stamp.Text = "OWNED"
		stamp.ZIndex = 5
		stamp.Parent = image
		local stroke = Instance.new("UIStroke", stamp)
		stroke.Color = STAMP_RED
		stroke.Thickness = 2

		local buyButton = Instance.new("TextButton")
		buyButton.Size = UDim2.new(1, -16, 0, 26)
		buyButton.Position = UDim2.fromOffset(8, 128)
		buyButton.BackgroundColor3 = LOCKED
		buyButton.BorderSizePixel = 0
		buyButton.Font = Enum.Font.GothamBold
		buyButton.TextSize = 13
		buyButton.TextColor3 = DIM_TEXT
		buyButton.AutoButtonColor = false
		buyButton.Text = "Owned"
		buyButton.Parent = card
		Instance.new("UICorner", buyButton).CornerRadius = UDim.new(0, 6)
	else
		local buyButton = Instance.new("TextButton")
		buyButton.Size = UDim2.new(1, -16, 0, 26)
		buyButton.Position = UDim2.fromOffset(8, 128)
		buyButton.BackgroundColor3 = if data.Money >= def.Price then ACCENT else LOCKED
		buyButton.BorderSizePixel = 0
		buyButton.Font = Enum.Font.GothamBold
		buyButton.TextSize = 13
		buyButton.TextColor3 = if data.Money >= def.Price then PANEL else DIM_TEXT
		buyButton.Text = "Buy $" .. def.Price
		buyButton.Parent = card
		Instance.new("UICorner", buyButton).CornerRadius = UDim.new(0, 6)
		buyButton.MouseButton1Click:Connect(function()
			playClickSound()
			buyVehicleEvent:FireServer(vehicleId)
			refreshTerminalData()
		end)
	end
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
	end

	-- Nothing to cycle to with zero or one car owned - showing arrows that
	-- can never do anything just invites clicking them to see why they don't
	-- work.
	local canCycle = #ordered > 1
	prevButton.Visible = canCycle
	nextButton.Visible = canCycle

	renderShop(data)
end

local function openTerminal()
	refreshTerminalData()
	screenGui.Enabled = true
end

closeTerminal = function()
	screenGui.Enabled = false
end

closeButton.MouseButton1Click:Connect(function()
	playClickSound()
	closeTerminal()
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape and screenGui.Enabled then
		closeTerminal()
	end
end)

--============================================================================
-- Per-plot prompts
--============================================================================

-- [plotModel] = true, once its prompts exist - guards against building a
-- second pair for the same plot (see the retry loop below).
local promptsBuilt = {}

-- Two CustomPrompt instances per plot (claim / open) rather than one whose
-- text changes: CustomPrompt builds its label once at construction and has
-- no way to relabel it afterwards. The two are mutually exclusive - a plot is
-- never both unclaimed and owned by me at once - so only one of a pair is
-- ever visible, and having both bound to F is harmless.
local function setupPlotPrompts(plotModel)
	if promptsBuilt[plotModel] then
		return true
	end

	local terminal = plotModel:FindFirstChild("Terminal")
	local screen = terminal and terminal:FindFirstChild("Screen")
	if not screen then
		return false -- not fully replicated yet - the retry below will catch it once it is
	end

	local claimPrompt = CustomPrompt.new(screen, {
		Text = "Hold to Claim This Plot",
		KeyCode = Enum.KeyCode.F,
		-- Hold rather than instant-press: claiming can't be undone for the
		-- rest of the server (see PlotManager.server.luau's header), so this
		-- is a bit of a guard against a stray tap claiming the wrong plot.
		HoldDuration = 1.5,
		ShouldShow = function()
			return not PlotOwnership.IsClaimed(plotModel) and not localPlayerOwnsAnyPlot()
		end,
	})
	claimPrompt.Triggered:Connect(function()
		claimPlotEvent:FireServer(plotModel)
	end)

	local openPrompt = CustomPrompt.new(screen, {
		Text = "Open Terminal",
		KeyCode = Enum.KeyCode.F,
		ShouldShow = function()
			return PlotOwnership.IsOwner(player, plotModel)
		end,
	})
	openPrompt.Triggered:Connect(openTerminal)

	promptsBuilt[plotModel] = true
	return true
end

-- A plot's Terminal/Screen may not have finished replicating to this client
-- the instant the plot itself shows up under VehiclePlotsFolder - same gap
-- VehicleDoorPrompts.client.luau retries for on freshly-added cars. Without
-- this, a plot whose Screen was one network tick late never gets a prompt at
-- all, for the rest of the session, with nothing printed anywhere to explain
-- why - which is exactly what a single unguarded FindFirstChild attempt did
-- here before.
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

for _, plotModel in VehiclePlotsFolder:GetChildren() do
	trySetupPlotPrompts(plotModel)
end
VehiclePlotsFolder.ChildAdded:Connect(trySetupPlotPrompts)

--============================================================================
-- Claim feedback sound
--============================================================================

-- Watches the attribute directly rather than hooking claimPrompt.Triggered:
-- Triggered only means a claim request was SENT, not that PlotManager.server
-- accepted it (too far away, already holds another plot, someone else beat
-- you to it, ...). OwnerUserId actually turning into MY id is the one
-- unambiguous signal that this client's claim went through.
local function watchForLocalClaim(plotModel)
	plotModel:GetAttributeChangedSignal(PlotOwnership.OWNER_USERID_ATTRIBUTE):Connect(function()
		if PlotOwnership.GetOwnerUserId(plotModel) == player.UserId then
			playClaimSound()
		end
	end)
end

for _, plotModel in VehiclePlotsFolder:GetChildren() do
	watchForLocalClaim(plotModel)
end
VehiclePlotsFolder.ChildAdded:Connect(watchForLocalClaim)

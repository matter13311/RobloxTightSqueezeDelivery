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

-- Matches CustomPrompt.luau / VehicleDashboard's dark-panel palette so this
-- reads as the same UI system rather than a one-off.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local TAB_OFF = Color3.fromRGB(28, 31, 38)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)

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

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PlotTerminalGui"
screenGui.ResetOnSpawn = false
screenGui.Enabled = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = player:WaitForChild("PlayerGui")

local main = Instance.new("Frame")
main.Size = UDim2.fromOffset(520, 360)
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

local moneyLabel = Instance.new("TextLabel")
moneyLabel.Size = UDim2.fromOffset(140, 40)
moneyLabel.Position = UDim2.new(1, -160, 0, 12)
moneyLabel.BackgroundTransparency = 1
moneyLabel.Font = Enum.Font.GothamBold
moneyLabel.TextSize = 18
moneyLabel.TextColor3 = ACCENT
moneyLabel.TextXAlignment = Enum.TextXAlignment.Right
moneyLabel.Text = "$0"
moneyLabel.Parent = main

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

local contentFrame = Instance.new("Frame")
contentFrame.Size = UDim2.new(1, -40, 1, -110)
contentFrame.Position = UDim2.fromOffset(20, 104)
contentFrame.BackgroundTransparency = 1
contentFrame.Parent = main

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
		showTab(name)
	end)
	return page
end

--- Vehicle tab -------------------------------------------------------------

local vehiclePage = addTab("Vehicle")

local vehicleNameLabel = Instance.new("TextLabel")
vehicleNameLabel.Size = UDim2.new(1, 0, 0, 30)
vehicleNameLabel.BackgroundTransparency = 1
vehicleNameLabel.Font = Enum.Font.GothamBold
vehicleNameLabel.TextSize = 18
vehicleNameLabel.TextColor3 = BRIGHT_TEXT
vehicleNameLabel.TextXAlignment = Enum.TextXAlignment.Left
vehicleNameLabel.Text = "Selected: --"
vehicleNameLabel.Parent = vehiclePage

local ownedList = Instance.new("Frame")
ownedList.Size = UDim2.new(1, 0, 1, -90)
ownedList.Position = UDim2.fromOffset(0, 40)
ownedList.BackgroundTransparency = 1
ownedList.Parent = vehiclePage
local ownedLayout = Instance.new("UIListLayout", ownedList)
ownedLayout.Padding = UDim.new(0, 6)

local spawnButton = Instance.new("TextButton")
spawnButton.Size = UDim2.new(1, 0, 0, 40)
spawnButton.Position = UDim2.new(0, 0, 1, -40)
spawnButton.BackgroundColor3 = ACCENT
spawnButton.BorderSizePixel = 0
spawnButton.Font = Enum.Font.GothamBold
spawnButton.TextSize = 16
spawnButton.TextColor3 = PANEL
spawnButton.Text = "Spawn Vehicle"
spawnButton.Parent = vehiclePage
Instance.new("UICorner", spawnButton).CornerRadius = UDim.new(0, 8)
spawnButton.MouseButton1Click:Connect(function()
	spawnVehicleEvent:FireServer()
end)

--- Shop tab (foundation only) ----------------------------------------------

local shopPage = addTab("Shop")
local shopLabel = Instance.new("TextLabel")
shopLabel.Size = UDim2.fromScale(1, 1)
shopLabel.BackgroundTransparency = 1
shopLabel.Font = Enum.Font.GothamMedium
shopLabel.TextSize = 15
shopLabel.TextColor3 = DIM_TEXT
shopLabel.TextWrapped = true
shopLabel.TextYAlignment = Enum.TextYAlignment.Top
shopLabel.Text = "Vehicle shop coming soon."
shopLabel.Parent = shopPage

--- Upgrades tab (foundation only) -------------------------------------------

local upgradesPage = addTab("Upgrades")
local upgradesLabel = Instance.new("TextLabel")
upgradesLabel.Size = UDim2.fromScale(1, 1)
upgradesLabel.BackgroundTransparency = 1
upgradesLabel.Font = Enum.Font.GothamMedium
upgradesLabel.TextSize = 15
upgradesLabel.TextColor3 = DIM_TEXT
upgradesLabel.TextWrapped = true
upgradesLabel.TextYAlignment = Enum.TextYAlignment.Top
upgradesLabel.Text = "Upgrades coming soon."
upgradesLabel.Parent = upgradesPage

showTab("Vehicle")

--- Populating the Vehicle tab from server data ------------------------------

-- Forward-declared: makeOwnedVehicleRow's row click needs to call this, but
-- this itself calls makeOwnedVehicleRow to rebuild the list - genuinely
-- mutual recursion, not just ordering.
local refreshTerminalData

local function makeOwnedVehicleRow(vehicleId, selectedId)
	local def = VehicleCatalog.Get(vehicleId)
	local row = Instance.new("TextButton")
	row.Size = UDim2.new(1, 0, 0, 34)
	row.BackgroundColor3 = if vehicleId == selectedId then ACCENT else TAB_OFF
	row.BorderSizePixel = 0
	row.Font = Enum.Font.GothamMedium
	row.TextSize = 14
	row.TextColor3 = if vehicleId == selectedId then PANEL else BRIGHT_TEXT
	row.Text = def and def.DisplayName or vehicleId
	row.Parent = ownedList
	Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)

	row.MouseButton1Click:Connect(function()
		selectVehicleEvent:FireServer(vehicleId)
		refreshTerminalData()
	end)
end

refreshTerminalData = function()
	local data = getPlotDataFunction:InvokeServer()
	if not data then
		return
	end

	moneyLabel.Text = "$" .. tostring(data.Money)

	local selectedDef = VehicleCatalog.Get(data.SelectedVehicleId)
	vehicleNameLabel.Text = "Selected: " .. (selectedDef and selectedDef.DisplayName or "--")

	for _, child in ownedList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for _, vehicleId in data.OwnedVehicleIds do
		makeOwnedVehicleRow(vehicleId, data.SelectedVehicleId)
	end
end

local function openTerminal()
	refreshTerminalData()
	screenGui.Enabled = true
end

local function closeTerminal()
	screenGui.Enabled = false
end

closeButton.MouseButton1Click:Connect(closeTerminal)
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

local CLAIM_SOUND_ID = "rbxassetid://90420386076500"

-- SoundService:PlayLocalSound plays without ever putting the Sound instance
-- into the DataModel, so this is inherently client-only - nobody else hears
-- it, and there's no Sound part to clean up in Workspace.
local function playClaimSound()
	local sound = Instance.new("Sound")
	sound.SoundId = CLAIM_SOUND_ID
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	SoundService:PlayLocalSound(sound)
end

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

-- The player's side of the delivery loop: the contract board that opens when
-- you pull into the depot's loading bay, the running job display while you are
-- carrying a load, and the payout summary when you park at the far end.
--
-- Nothing here is a security boundary. DeliveryManager.server.luau re-checks
-- that the truck really is in the bay, really is yours, and really is stopped
-- before it loads anything - the same split PlotTerminal.client.luau's header
-- describes. This script only decides what to SHOW.
--
-- Being "at the dock" is worked out with ParkGrade, the same shared module the
-- server pays out on, so the board appears exactly when the server would agree
-- the truck is in the bay - rather than on a proximity radius that could open
-- the board somewhere the server would refuse to load.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
local CargoTypes = require(ReplicatedStorage.Modules.Delivery.CargoTypes)
local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local player = Players.LocalPlayer

local getContractsFunction = ReplicatedStorage:WaitForChild("GetDeliveryContracts")
local acceptContractEvent = ReplicatedStorage:WaitForChild("AcceptDeliveryContract")
local deliveryUpdateEvent = ReplicatedStorage:WaitForChild("DeliveryUpdate")

-- WaitForChild for the same reason PlotTerminal does it: Workspace is not
-- guaranteed to have replicated by the time PlayerScripts starts, and a direct
-- index would throw and kill this whole script with no visible symptom.
local VehicleFolder = workspace:WaitForChild("Vehicles")

-- Matches PlotTerminal / CustomPrompt / VehicleDashboard, so this reads as the
-- same UI system rather than a second one bolted on.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local CARD = Color3.fromRGB(28, 31, 38)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)
local WARN_TEXT = Color3.fromRGB(214, 76, 76)

--=============================================================================
-- Small builders
--=============================================================================

local function corner(instance, radius)
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0, radius or 6)
	uiCorner.Parent = instance
	return uiCorner
end

local function stroke(instance, color)
	local uiStroke = Instance.new("UIStroke")
	uiStroke.Color = color or PANEL_EDGE
	uiStroke.Parent = instance
	return uiStroke
end

local function label(parent, text, size, color, bold)
	local textLabel = Instance.new("TextLabel")
	textLabel.BackgroundTransparency = 1
	textLabel.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	textLabel.TextSize = size
	textLabel.TextColor3 = color or BRIGHT_TEXT
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.Text = text
	textLabel.Parent = parent
	return textLabel
end

--=============================================================================
-- GUI
--=============================================================================

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DeliveryGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = player:WaitForChild("PlayerGui")

-- The running job, top-left. Deliberately small and always-on rather than a
-- key-to-open panel: in first person, with mirrors to watch and a gap to
-- thread, anything you have to stop and open is something you will not open.
local jobFrame = Instance.new("Frame")
jobFrame.Size = UDim2.fromOffset(260, 92)
jobFrame.Position = UDim2.fromOffset(16, 16)
jobFrame.BackgroundColor3 = PANEL
jobFrame.BackgroundTransparency = 0.1
jobFrame.BorderSizePixel = 0
jobFrame.Visible = false
jobFrame.Parent = screenGui
corner(jobFrame, 8)
stroke(jobFrame)

local jobTitle = label(jobFrame, "", 15, BRIGHT_TEXT, true)
jobTitle.Position = UDim2.fromOffset(12, 10)
jobTitle.Size = UDim2.new(1, -24, 0, 18)

local jobCargo = label(jobFrame, "", 13, DIM_TEXT)
jobCargo.Position = UDim2.fromOffset(12, 32)
jobCargo.Size = UDim2.new(1, -24, 0, 16)

local jobCondition = label(jobFrame, "", 13, ACCENT)
jobCondition.Position = UDim2.fromOffset(12, 52)
jobCondition.Size = UDim2.new(1, -24, 0, 16)

local jobValue = label(jobFrame, "", 13, DIM_TEXT)
jobValue.Position = UDim2.fromOffset(12, 70)
jobValue.Size = UDim2.new(1, -24, 0, 16)

-- The contract board, centred, opened by pulling into the bay.
local board = Instance.new("Frame")
board.Size = UDim2.fromOffset(520, 420)
board.Position = UDim2.fromScale(0.5, 0.5)
board.AnchorPoint = Vector2.new(0.5, 0.5)
board.BackgroundColor3 = PANEL
board.BorderSizePixel = 0
board.Visible = false
board.Parent = screenGui
corner(board, 10)
stroke(board)

local boardTitle = label(board, "Loading Dock", 22, BRIGHT_TEXT, true)
boardTitle.Position = UDim2.fromOffset(20, 16)
boardTitle.Size = UDim2.new(1, -40, 0, 26)

local boardSubtitle = label(board, "Pick a job. The crates are loaded onto your truck here.", 13, DIM_TEXT)
boardSubtitle.Position = UDim2.fromOffset(20, 44)
boardSubtitle.Size = UDim2.new(1, -40, 0, 18)

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(28, 28)
closeButton.Position = UDim2.new(1, -40, 0, 16)
closeButton.BackgroundColor3 = CARD
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 16
closeButton.TextColor3 = DIM_TEXT
closeButton.Text = "X"
closeButton.Parent = board
corner(closeButton, 6)

local offerList = Instance.new("Frame")
offerList.Position = UDim2.fromOffset(20, 76)
offerList.Size = UDim2.new(1, -40, 1, -96)
offerList.BackgroundTransparency = 1
offerList.Parent = board

local offerLayout = Instance.new("UIListLayout")
offerLayout.Padding = UDim.new(0, 10)
offerLayout.SortOrder = Enum.SortOrder.LayoutOrder
offerLayout.Parent = offerList

-- The payout summary, centred low so it does not cover the windscreen.
local summary = Instance.new("Frame")
summary.Size = UDim2.fromOffset(360, 132)
summary.Position = UDim2.fromScale(0.5, 0.78)
summary.AnchorPoint = Vector2.new(0.5, 0.5)
summary.BackgroundColor3 = PANEL
summary.BorderSizePixel = 0
summary.Visible = false
summary.Parent = screenGui
corner(summary, 10)
stroke(summary, ACCENT)

local summaryTitle = label(summary, "", 20, ACCENT, true)
summaryTitle.Position = UDim2.fromOffset(16, 12)
summaryTitle.Size = UDim2.new(1, -32, 0, 24)

local summaryBody = Instance.new("TextLabel")
summaryBody.BackgroundTransparency = 1
summaryBody.Position = UDim2.fromOffset(16, 40)
summaryBody.Size = UDim2.new(1, -32, 1, -52)
summaryBody.Font = Enum.Font.Gotham
summaryBody.TextSize = 14
summaryBody.TextColor3 = BRIGHT_TEXT
summaryBody.TextXAlignment = Enum.TextXAlignment.Left
summaryBody.TextYAlignment = Enum.TextYAlignment.Top
summaryBody.RichText = true
summaryBody.Text = ""
summaryBody.Parent = summary

--=============================================================================
-- Board contents
--=============================================================================

local activeContract = nil
-- Set when the player closes the board by hand, cleared when they leave the
-- bay. Without it, closing the board in a bay you are parked in would just
-- reopen it a quarter of a second later, forever.
local boardDismissed = false

local function clearOffers()
	for _, child in offerList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function makeOfferCard(offer, index)
	local cargoType = CargoTypes.GetOrDefault(offer.TypeId)

	local card = Instance.new("TextButton")
	card.Size = UDim2.new(1, 0, 0, 86)
	card.BackgroundColor3 = CARD
	card.BorderSizePixel = 0
	card.AutoButtonColor = true
	card.Font = Enum.Font.Gotham
	card.Text = ""
	card.LayoutOrder = index
	card.Parent = offerList
	corner(card, 8)
	stroke(card)

	local destinationLabel = label(card, offer.Stops[1], 17, BRIGHT_TEXT, true)
	destinationLabel.Position = UDim2.fromOffset(14, 10)
	destinationLabel.Size = UDim2.new(1, -140, 0, 20)

	local cargoLabel = label(
		card,
		string.format("%d x %s  -  fragility %.2f", offer.Units, cargoType.DisplayName, cargoType.Fragility),
		13,
		DIM_TEXT
	)
	cargoLabel.Position = UDim2.fromOffset(14, 32)
	cargoLabel.Size = UDim2.new(1, -140, 0, 16)

	local distanceLabel = label(card, string.format("%.0f studs away", offer.Distance), 13, DIM_TEXT)
	distanceLabel.Position = UDim2.fromOffset(14, 52)
	distanceLabel.Size = UDim2.new(1, -140, 0, 16)

	-- Described as a minimum on purpose: the server quotes a pristine, nose-in
	-- delivery, and reversing in cleanly pays more. Telling the player the
	-- figure can only go up is what makes the parking bonus feel like a reward
	-- rather than the removal of a penalty.
	local payLabel = label(card, string.format("$%d+", offer.QuotedValue), 22, ACCENT, true)
	payLabel.Position = UDim2.new(1, -120, 0, 22)
	payLabel.Size = UDim2.fromOffset(106, 26)
	payLabel.TextXAlignment = Enum.TextXAlignment.Right

	local payNote = label(card, "before parking bonus", 11, DIM_TEXT)
	payNote.Position = UDim2.new(1, -120, 0, 48)
	payNote.Size = UDim2.fromOffset(106, 14)
	payNote.TextXAlignment = Enum.TextXAlignment.Right

	card.Activated:Connect(function()
		acceptContractEvent:FireServer(offer.Id)
		board.Visible = false
	end)

	return card
end

local function openBoard()
	local ok, state = pcall(function()
		return getContractsFunction:InvokeServer()
	end)
	if not ok or type(state) ~= "table" then
		return
	end
	if state.Active or #state.Offers == 0 then
		return -- already carrying a job, or the map has no destinations built yet
	end

	clearOffers()
	for index, offer in state.Offers do
		makeOfferCard(offer, index)
	end
	board.Visible = true
end

closeButton.Activated:Connect(function()
	board.Visible = false
	boardDismissed = true
end)

--=============================================================================
-- Running job display
--=============================================================================

local conditionConnection = nil

local function refreshJobFrame()
	if not activeContract then
		jobFrame.Visible = false
		return
	end

	local cargoType = CargoTypes.GetOrDefault(activeContract.TypeId)
	local carModel = activeContract.Vehicle
	local condition = 1
	if carModel and carModel.Parent then
		local value = carModel:GetAttribute(CargoLoad.Attributes.Condition)
		condition = if type(value) == "number" then value else 1
	end

	jobTitle.Text = "-> " .. activeContract.Stops[1]
	jobCargo.Text = string.format("%d x %s", activeContract.Units, cargoType.DisplayName)
	jobCondition.Text = string.format("Cargo condition  %d%%", math.floor(condition * 100 + 0.5))
	-- Turns amber then red as goods get wrecked, so the cost of a scrape is
	-- visible while there is still time to drive more carefully.
	jobCondition.TextColor3 = if condition > 0.75
		then ACCENT
		elseif condition > 0.4 then Color3.fromRGB(224, 178, 84)
		else WARN_TEXT
	jobValue.Text = string.format(
		"Worth about $%d",
		CargoLoad.Value(activeContract.Units, activeContract.TypeId, condition)
	)
	jobFrame.Visible = true
end

local function setActiveContract(contract)
	activeContract = contract

	if conditionConnection then
		conditionConnection:Disconnect()
		conditionConnection = nil
	end
	-- Driven by the attribute changing rather than polled, so the number moves
	-- the instant the server registers a crash.
	local carModel = contract and contract.Vehicle
	if carModel then
		conditionConnection = carModel:GetAttributeChangedSignal(CargoLoad.Attributes.Condition):Connect(refreshJobFrame)
	end

	refreshJobFrame()
end

--=============================================================================
-- Server updates
--=============================================================================

local summaryToken = 0

local function showSummary(completed)
	local cargoType = CargoTypes.GetOrDefault(completed.TypeId)
	summaryTitle.Text = string.format("Delivered  +$%d", completed.Payout)
	summaryBody.Text = string.format(
		"%d x %s to %s\nCondition on arrival: %d%%\nPark: %s  (x%.2f total)%s",
		completed.Units,
		cargoType.DisplayName,
		completed.Destination,
		math.floor(completed.Condition * 100 + 0.5),
		completed.ParkLabel,
		completed.Multiplier,
		if completed.Balance then string.format("\nBalance: $%d", completed.Balance) else ""
	)
	summary.Visible = true

	-- Token, not a cancelled task: two deliveries in quick succession would
	-- otherwise have the first one's timer hide the second one's summary.
	summaryToken += 1
	local token = summaryToken
	task.delay(6, function()
		if summaryToken == token then
			summary.Visible = false
		end
	end)
end

deliveryUpdateEvent.OnClientEvent:Connect(function(update)
	if type(update) ~= "table" then
		return
	end
	setActiveContract(update.Active)
	if update.Completed then
		showSummary(update.Completed)
	end
end)

--=============================================================================
-- Am I at the dock?
--=============================================================================

local world = DeliveryConfig.World

-- Resolved lazily rather than once at startup, and re-resolved while empty.
-- The depot geometry is hand-built in Studio, so during development it can
-- appear (or be renamed, or be moved) after this script has already run - and
-- a one-shot lookup at line 1 would leave the board permanently dead with no
-- clue why. Once found, the list is cached and the scan stops.
local baySpaces = {}

local function findBaySpaces()
	if #baySpaces > 0 then
		return baySpaces
	end

	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	local depotFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DepotFolderName)
	local loadingBay = depotFolder and depotFolder:FindFirstChild(world.LoadingBayName)
	if not loadingBay then
		return baySpaces
	end

	for _, descendant in loadingBay:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name:sub(1, #world.SpacePrefix) == world.SpacePrefix then
			table.insert(baySpaces, descendant)
		end
	end
	return baySpaces
end

local function truckIsInBay()
	local spaces = findBaySpaces()
	if #spaces == 0 then
		return false
	end
	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	local chassis = carModel and carModel.PrimaryPart
	if not chassis then
		return false
	end
	if chassis.AssemblyLinearVelocity.Magnitude > DeliveryConfig.Parking.StoppedSpeed then
		return false
	end
	for _, space in spaces do
		if ParkGrade.Evaluate(carModel, space).Inside then
			return true
		end
	end
	return false
end

-- Quarter-second polling, matching the server's own arrival poll. Cheap enough
-- to be invisible (a handful of dot products on at most a few bay parts) and
-- far simpler than trying to drive this off Touched events, which fire
-- constantly while crossing a bay and say nothing about having stopped.
local accumulator = 0
RunService.Heartbeat:Connect(function(delta)
	accumulator += delta
	if accumulator < 0.25 then
		return
	end
	accumulator = 0

	local inBay = truckIsInBay()
	if not inBay then
		boardDismissed = false
		board.Visible = false
		return
	end

	if not board.Visible and not boardDismissed and not activeContract then
		openBoard()
	end
end)

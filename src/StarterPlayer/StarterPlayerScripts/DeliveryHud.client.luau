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
--
-- The board is a persistent, per-player POOL now, not three offers rolled fresh
-- on arrival (see ContractPool.luau). That changes two things here. Asking for
-- the board is free and idempotent, so nothing in this file has to be careful
-- about how often it asks. And an EMPTY board is a real state the player has to
-- be shown - with how long until the next job turns up, and the button that
-- skips the wait - rather than a reason not to open the panel at all.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
local CargoTypes = require(ReplicatedStorage.Modules.Delivery.CargoTypes)
local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local player = Players.LocalPlayer

local getContractsFunction = ReplicatedStorage:WaitForChild("GetDeliveryContracts")
local acceptContractEvent = ReplicatedStorage:WaitForChild("AcceptDeliveryContract")
local deliveryUpdateEvent = ReplicatedStorage:WaitForChild("DeliveryUpdate")
-- Fired by Monetization.server.luau once a refresh purchase has actually
-- rebuilt the board on the server - see its comment for why this exists rather
-- than redrawing on PromptProductPurchaseFinished.
local contractsRefreshedEvent = ReplicatedStorage:WaitForChild("ContractsRefreshed")

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
local CAUTION = Color3.fromRGB(224, 178, 84)
local WARN_TEXT = Color3.fromRGB(214, 76, 76)

-- Light / Moderate / Heavy, keyed by CargoLoad.WeightBand's Id rather than by
-- its display text, so renaming a band's label never silently drops its colour
-- back to the default.
local WEIGHT_COLORS = {
	Light = ACCENT,
	Moderate = CAUTION,
	Heavy = WARN_TEXT,
}

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

-- The running job, top-CENTRE. Deliberately small and always-on rather than a
-- key-to-open panel: in first person, with mirrors to watch and a gap to
-- thread, anything you have to stop and open is something you will not open.
--
-- Not top-left, where it started: Roblox's own chat and menu buttons live
-- there and sit on top of it. Top-centre is the one horizontal band the
-- CoreGui leaves alone at every screen size - the leaderboard takes the right,
-- chat the left - and it is still out of the windscreen.
local jobFrame = Instance.new("Frame")
jobFrame.Size = UDim2.fromOffset(260, 92)
jobFrame.AnchorPoint = Vector2.new(0.5, 0)
jobFrame.Position = UDim2.new(0.5, 0, 0, 12)
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
-- Taller than it was: the pool grows with the player's delivery count rather
-- than holding a fixed three, and there is now a footer under the list carrying
-- the pool's state and the refresh button.
local board = Instance.new("Frame")
board.Size = UDim2.fromOffset(520, 500)
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

-- A ScrollingFrame, where the fixed three-offer board could get away with a
-- plain one. Seven cards at 96px plus padding is well over the height of the
-- panel, and a list that silently clips the jobs a player levelled up to unlock
-- is worse than no cap increase at all.
local offerList = Instance.new("ScrollingFrame")
offerList.Position = UDim2.fromOffset(20, 76)
offerList.Size = UDim2.new(1, -40, 1, -140)
offerList.BackgroundTransparency = 1
offerList.BorderSizePixel = 0
offerList.ScrollBarThickness = 6
offerList.ScrollBarImageColor3 = PANEL_EDGE
offerList.CanvasSize = UDim2.fromScale(0, 0)
offerList.AutomaticCanvasSize = Enum.AutomaticSize.Y
offerList.Parent = board

local offerLayout = Instance.new("UIListLayout")
offerLayout.Padding = UDim.new(0, 10)
offerLayout.SortOrder = Enum.SortOrder.LayoutOrder
offerLayout.Parent = offerList

-- Shown INSTEAD of the cards when the board is empty. An empty panel with a
-- button in the corner leaves the player to work out for themselves that the
-- jobs are on a timer and that the timer is the thing the button skips, which
-- is precisely the moment they are most likely to just close the game.
local emptyNotice = Instance.new("TextLabel")
emptyNotice.Position = UDim2.fromOffset(20, 76)
emptyNotice.Size = UDim2.new(1, -40, 1, -140)
emptyNotice.BackgroundTransparency = 1
emptyNotice.Font = Enum.Font.Gotham
emptyNotice.TextSize = 15
emptyNotice.TextColor3 = DIM_TEXT
emptyNotice.TextWrapped = true
emptyNotice.RichText = true
emptyNotice.Visible = false
emptyNotice.Text = ""
emptyNotice.Parent = board

--=============================================================================
-- The board footer: what the pool is doing, and the button that skips it
--=============================================================================

local footer = Instance.new("Frame")
footer.Position = UDim2.new(0, 20, 1, -56)
footer.Size = UDim2.new(1, -40, 0, 36)
footer.BackgroundTransparency = 1
footer.Parent = board

-- Left half: "3 of 4 jobs - next in 7:12". The pool's whole state in one line,
-- because it is the line that explains why the board looks the way it does.
local poolStatus = label(footer, "", 13, DIM_TEXT)
poolStatus.Position = UDim2.fromOffset(0, 2)
poolStatus.Size = UDim2.new(1, -180, 0, 16)

local poolProgress = label(footer, "", 12, DIM_TEXT)
poolProgress.Position = UDim2.fromOffset(0, 19)
poolProgress.Size = UDim2.new(1, -180, 0, 15)

-- Outlined rather than filled, and no price in the label: this is a
-- secondary action next to the job cards, not the thing the board wants the
-- player's eye to land on first.
local refreshButton = Instance.new("TextButton")
refreshButton.AnchorPoint = Vector2.new(1, 0)
refreshButton.Position = UDim2.new(1, 0, 0, 0)
refreshButton.Size = UDim2.fromOffset(170, 34)
refreshButton.BackgroundTransparency = 1
refreshButton.BorderSizePixel = 0
refreshButton.Font = Enum.Font.GothamBold
refreshButton.TextSize = 14
refreshButton.TextColor3 = DIM_TEXT
refreshButton.Text = ""
refreshButton.Parent = footer
corner(refreshButton, 8)
stroke(refreshButton, PANEL_EDGE)

-- The payout summary, centred low so it does not cover the windscreen.
local summary = Instance.new("Frame")
-- Taller than it was by one line, for the progress/level-up line the payout
-- now carries (see progressLine).
summary.Size = UDim2.fromOffset(360, 154)
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
-- Set between clicking an offer and the server confirming it. The board is NOT
-- hidden on the click: the server re-checks that the truck is stopped before it
-- loads anything, and a car at rest is not perfectly still (see the grace
-- period at the bottom of this file), so an accept CAN be refused. Hiding the
-- board on the click would make a refusal look like the game swallowing the
-- job with no explanation.
local accepting = false
-- Guards the RemoteFunction round trip. openBoard runs from the Heartbeat poll
-- and InvokeServer yields, so without this a slow reply lets the next tick fire
-- a second request - and the board redraws under the player's cursor with a
-- different set of numbers than the one they were reading.
local boardRequestInFlight = false
-- How long to wait for the server to confirm an accept before assuming it was
-- refused and letting the player click again. Comfortably longer than a round
-- trip, short enough that a refused job does not feel like a hang.
local ACCEPT_TIMEOUT = 2
-- Declared up here because openBoard needs it and it needs the close button,
-- which is built below - the same forward declaration PlotTerminal uses for
-- closeTerminal. Nothing may set board.Visible directly: the cursor state is
-- tied to it (see setBoardVisible) and the two must never disagree.
local setBoardVisible

local function clearOffers()
	accepting = false
	for _, child in offerList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- The load, drawn as the actual crates.
--
-- A ViewportFrame with real Parts in it rather than a pre-rendered image per
-- cargo type: the crate count varies per contract, so an image would need one
-- asset per (type, count) pair and would go stale the moment a CrateSize or
-- Color changed in CargoTypes. This is built from the same table CargoManager
-- builds the real crates from, laid out by the same CargoLoad.CrateOffset, so
-- what the player is looking at on the board is what turns up in the bed.
--
-- Nothing here is parented to Workspace, so none of it collides, replicates or
-- costs anything physically - a ViewportFrame renders its own children in
-- isolation.
local PREVIEW_SIZE = 74
-- Enough to read a full load at a glance; past this the stack is a texture
-- rather than a count, and the card's "N x Parcels" text is doing the work
-- anyway. Only reachable with a heavily upgraded CargoCapacity.
local PREVIEW_MAX_CRATES = 18

local function makeCratePreview(parent, cargoType, units)
	local viewport = Instance.new("ViewportFrame")
	viewport.Size = UDim2.fromOffset(PREVIEW_SIZE, PREVIEW_SIZE)
	viewport.Position = UDim2.fromOffset(12, 6)
	viewport.BackgroundColor3 = PANEL
	viewport.BorderSizePixel = 0
	-- Lit from front-left and above so the three visible faces of a crate read
	-- as three different tones. Flat lighting turns a stack of boxes into one
	-- silhouette and the count becomes unreadable, which is the whole job here.
	viewport.Ambient = Color3.fromRGB(150, 152, 158)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.6, -1, -0.45)
	viewport.Parent = parent
	corner(viewport, 6)
	stroke(viewport)

	local camera = Instance.new("Camera")
	camera.FieldOfView = 30
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local shown = math.min(math.max(units, 1), PREVIEW_MAX_CRATES)
	local crateSize = cargoType.CrateSize

	for index = 0, shown - 1 do
		local crate = Instance.new("Part")
		crate.Size = crateSize
		crate.Color = cargoType.Color
		crate.Material = cargoType.Material
		-- Anchored purely so nothing tries to simulate them; a ViewportFrame
		-- runs no physics either way.
		crate.Anchored = true
		crate.CanCollide = false
		crate.TopSurface = Enum.SurfaceType.Smooth
		crate.BottomSurface = Enum.SurfaceType.Smooth
		crate.CFrame = CFrame.new(CargoLoad.CrateOffset(index, crateSize))
		crate.Parent = viewport
	end

	-- Framed from the stack's real size rather than a per-type constant, so a
	-- single tall crate of Glassware and a six-crate block of Aggregate both
	-- fill the box. CrateOffset puts the stack on the y=0 plane, hence the
	-- half-height centre.
	local stack = CargoLoad.StackSize(shown, crateSize)
	local focus = Vector3.new(0, stack.Y / 2, 0)
	local radius = stack.Magnitude / 2
	-- Trig rather than a tuned multiplier: distance = radius / tan(fov/2) is
	-- the exact fit, and 1.25 is the visual margin around it.
	local distance = (radius / math.tan(math.rad(camera.FieldOfView / 2))) * 1.25
	-- Three-quarter view, slightly above. Front-on hides the stack depth and a
	-- true isometric hides the count in the back row.
	camera.CFrame = CFrame.lookAt(focus + Vector3.new(0.85, 0.75, 1).Unit * distance, focus)

	return viewport
end

local function makeOfferCard(offer, index)
	local cargoType = CargoTypes.GetOrDefault(offer.TypeId)

	local card = Instance.new("TextButton")
	card.Size = UDim2.new(1, 0, 0, 96)
	card.BackgroundColor3 = CARD
	card.BorderSizePixel = 0
	card.AutoButtonColor = true
	card.Font = Enum.Font.Gotham
	card.Text = ""
	card.LayoutOrder = index
	card.Parent = offerList
	corner(card, 8)
	stroke(card)

	makeCratePreview(card, cargoType, offer.Units)

	-- Text starts clear of the preview. The three labels share one left edge
	-- and one right margin so the column stays straight whatever the preview
	-- does.
	local TEXT_X = 12 + PREVIEW_SIZE + 12
	local TEXT_WIDTH = -(TEXT_X + 126)

	local destinationLabel = label(card, offer.Stops[1], 17, BRIGHT_TEXT, true)
	destinationLabel.Position = UDim2.fromOffset(TEXT_X, 10)
	destinationLabel.Size = UDim2.new(1, TEXT_WIDTH, 0, 20)

	local cargoLabel = label(
		card,
		string.format("%d x %s  -  fragility %.2f", offer.Units, cargoType.DisplayName, cargoType.Fragility),
		13,
		DIM_TEXT
	)
	cargoLabel.Position = UDim2.fromOffset(TEXT_X, 32)
	cargoLabel.Size = UDim2.new(1, TEXT_WIDTH, 0, 16)

	local distanceLabel = label(card, string.format("%.0f studs away", offer.Distance), 13, DIM_TEXT)
	distanceLabel.Position = UDim2.fromOffset(TEXT_X, 52)
	distanceLabel.Size = UDim2.new(1, TEXT_WIDTH, 0, 16)

	-- Weight: a word AND a bar. The word is what a player reads at a glance in
	-- a moving truck; the bar is what lets them compare two Moderate jobs
	-- against each other without doing arithmetic. Neither alone does both.
	local band = CargoLoad.WeightBand(offer.MassFraction)
	local bandColor = WEIGHT_COLORS[band.Id] or DIM_TEXT

	local weightLabel = label(card, band.Label, 13, bandColor, true)
	weightLabel.Position = UDim2.fromOffset(TEXT_X, 72)
	weightLabel.Size = UDim2.fromOffset(64, 16)

	local weightTrack = Instance.new("Frame")
	weightTrack.Position = UDim2.fromOffset(TEXT_X + 68, 77)
	weightTrack.Size = UDim2.fromOffset(88, 6)
	weightTrack.BackgroundColor3 = PANEL
	weightTrack.BorderSizePixel = 0
	weightTrack.Parent = card
	corner(weightTrack, 3)

	local weightFill = Instance.new("Frame")
	-- Anchored and sized in scale so the fill grows from the left edge; a bar
	-- that grew from the middle would read as a gauge rather than a quantity.
	weightFill.Size = UDim2.new(band.Fill, 0, 1, 0)
	weightFill.BackgroundColor3 = bandColor
	weightFill.BorderSizePixel = 0
	weightFill.Parent = weightTrack
	corner(weightFill, 3)

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
		if accepting then
			return -- a second click while the first is still in flight
		end
		accepting = true
		acceptContractEvent:FireServer(offer.Id)

		-- The board closes when the contract actually arrives (see the
		-- DeliveryUpdate handler), not here. If nothing arrives, the note says
		-- so and the cards go live again rather than the player being left
		-- staring at a board that did nothing.
		payNote.Text = "loading..."
		task.delay(ACCEPT_TIMEOUT, function()
			if accepting and card.Parent then
				accepting = false
				payNote.Text = "didn't take - hold still and retry"
			end
		end)
	end)

	return card
end

--=============================================================================
-- The pool footer
--=============================================================================

-- The last board the server sent, and the os.clock() at which it arrived.
-- SecondsUntilNext is a DURATION when it leaves the server (see
-- ContractPool.Board), so the countdown is that duration minus however long
-- this client has been holding it - no comparison of two machines' clocks
-- anywhere, which is the only way this can be right for a player whose device
-- clock is wrong.
local boardState = nil
local boardStateAt = 0

-- Filled in from Roblox on startup (see ProgressionConfig.Monetization). The
-- button itself no longer displays this - the prompt Roblox shows on purchase
-- carries the price - but PromptProductPurchase still needs the product id.
local refreshPrice = ProgressionConfig.Monetization.RefreshContractsPrice

local function formatDuration(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- "4th", "5th". Only ever called on a contract cap, which
-- ProgressionConfig keeps in single digits - so this handles
-- the range that exists rather than pretending to be a general ordinal
-- formatter it would then have to get right for 11 through 13.
local ORDINALS = { "1st", "2nd", "3rd", "4th", "5th", "6th", "7th", "8th", "9th" }

local function ordinal(n)
	return ORDINALS[n] or tostring(n) .. "th"
end

local function updateFooter()
	local state = boardState
	if not state then
		poolStatus.Text = ""
		poolProgress.Text = ""
		return
	end

	local count = #state.Offers
	local cap = state.Cap or count

	if state.SecondsUntilNext then
		local remaining = state.SecondsUntilNext - (os.clock() - boardStateAt)
		poolStatus.Text = string.format("%d of %d jobs  -  next in %s", count, cap, formatDuration(remaining))
	else
		poolStatus.Text = string.format("%d of %d jobs", count, cap)
	end

	-- Second line: how to make the board bigger. A player looking at a board
	-- smaller than they would like is the exact audience for that, and this is
	-- the only place the progression explains itself at all. Both halves are in
	-- deliveries - the count they have done and the count the next slot wants -
	-- so there is no second unit to learn and nothing to convert.
	local deliveries = state.Deliveries or 0
	local milestone = state.NextCapMilestone

	if milestone then
		poolProgress.Text = string.format(
			"%s completed  -  %s more for a %s job",
			ProgressionConfig.DeliveryCountText(deliveries),
			ProgressionConfig.DeliveryCountText(math.max(0, milestone.Deliveries - deliveries)),
			ordinal(milestone.Cap)
		)
	else
		poolProgress.Text = string.format(
			"%s completed  -  every job slot unlocked",
			ProgressionConfig.DeliveryCountText(deliveries)
		)
	end
end

local function updateRefreshButton()
	refreshButton.Text = "Refresh Jobs"
end

-- Priced from the config immediately rather than waiting on the round trip
-- below, so the button is never briefly blank on a slow connection.
updateRefreshButton()

refreshButton.Activated:Connect(function()
	-- Roblox owns the whole purchase flow from here: the prompt, the payment,
	-- and telling the server. Nothing about the board changes on this click -
	-- it changes when the SERVER says the refresh happened (see the
	-- ContractsRefreshed handler below), so a cancelled or failed purchase
	-- leaves the board exactly as it was with no client-side undo to get wrong.
	MarketplaceService:PromptProductPurchase(player, ProgressionConfig.Monetization.RefreshContractsProductId)
end)

-- The real price, which only Roblox knows. Asked for once, off the main path,
-- and ignored on failure - the config's placeholder is already on the button
-- and a network hiccup should not leave the player staring at a blank one.
task.spawn(function()
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(
			ProgressionConfig.Monetization.RefreshContractsProductId,
			Enum.InfoType.Product
		)
	end)
	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
		refreshPrice = info.PriceInRobux
		updateRefreshButton()
	end
end)

--=============================================================================
-- Drawing and asking for the board
--=============================================================================

local function renderBoard(state)
	boardState = state
	boardStateAt = os.clock()

	clearOffers()
	for index, offer in state.Offers do
		makeOfferCard(offer, index)
	end

	local empty = #state.Offers == 0
	offerList.Visible = not empty
	emptyNotice.Visible = empty
	if empty and state.SecondsUntilNext then
		emptyNotice.Text = string.format(
			"Every job is out.\n\nThe depot posts a new one every %d minutes - or take a full board of %d right now.",
			math.max(1, math.floor(ProgressionConfig.Contracts.RegenSeconds / 60 + 0.5)),
			state.Cap or ProgressionConfig.BaseContractCap()
		)
	elseif empty then
		-- No timer AND no jobs means the map itself has nothing to deliver to,
		-- which is a build problem rather than a wait - and telling the player
		-- to sit tight for a job that is never coming would be a lie.
		emptyNotice.Text = "The depot has no destinations set up yet, so there is nothing to haul.\n\n"
			.. "(See docs/CargoDesign.md section 4.2.)"
	end

	updateRefreshButton()
	updateFooter()
end

-- Asks the server for the board and redraws it. Safe to call as often as
-- anything likes: the pool is persisted, so the answer does not change just
-- because it was asked for - which is the entire reason backing out of the bay
-- and driving in again no longer re-rolls the jobs.
local function requestBoard()
	if boardRequestInFlight then
		return nil
	end
	boardRequestInFlight = true
	local ok, state = pcall(function()
		return getContractsFunction:InvokeServer()
	end)
	boardRequestInFlight = false
	if not ok or type(state) ~= "table" or type(state.Offers) ~= "table" then
		return nil
	end
	if state.Active then
		return nil -- already carrying a job; the board has nothing to say
	end

	renderBoard(state)
	return state
end

local function openBoard()
	if requestBoard() then
		setBoardVisible(true)
	end
end

-- Called while the board is open. Two jobs: run the countdown down, and ask the
-- server for the board again the moment that countdown reaches zero, so a
-- player sitting in the bay watching the timer sees the job actually appear
-- rather than having to drive out and back in to collect it.
--
-- The re-request is gated on the countdown having elapsed, not on a timer of
-- its own, so an open board costs exactly one extra round trip per contract
-- regenerated - and none at all while the board is full.
local function tickBoard()
	if not boardState then
		return
	end
	updateFooter()
	if not boardState.SecondsUntilNext then
		return
	end
	if boardState.SecondsUntilNext - (os.clock() - boardStateAt) > 0 then
		return
	end
	-- Cleared first so a slow reply cannot re-enter this on every tick.
	boardState.SecondsUntilNext = nil
	requestBoard()
end

-- The server has rebuilt the board because the player paid for it. Redrawn
-- rather than patched locally: the new jobs were generated on the server and
-- this client has never seen them.
contractsRefreshedEvent.OnClientEvent:Connect(function()
	if board.Visible then
		requestBoard()
	end
end)

-- THE MOUSE, in first person. Same problem and same fix as
-- PlotTerminal.client.luau's applyMouseState, whose comment explains it in
-- full: Roblox's camera controller re-asserts MouseBehavior = LockCenter every
-- frame while zoomed all the way in, so setting Default once when the board
-- opens does not stick - the cursor stays pinned to the centre of the screen,
-- which here sits on top of the middle offer card. The player can see three
-- jobs and only ever click one.
--
-- Re-asserting every frame at RenderPriority.Last means this script's value is
-- the one still standing after the camera has had its say.
local MOUSE_STEP = "DeliveryBoardMouse"
local mouseBound = false

local function applyMouseState()
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

-- Every show/hide of the board goes through here, so the cursor can never be
-- left free with no board on screen (which would leave the player unable to
-- steer the camera) or locked with one open.
setBoardVisible = function(visible)
	if board.Visible == visible and mouseBound == visible then
		return
	end
	board.Visible = visible

	if visible and not mouseBound then
		mouseBound = true
		RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Last.Value, applyMouseState)
	elseif not visible and mouseBound then
		mouseBound = false
		RunService:UnbindFromRenderStep(MOUSE_STEP)
		-- Hand control back rather than forcing LockCenter ourselves - the
		-- camera controller decides what the cursor should do from how zoomed
		-- in the player currently is, and re-locks on its own next frame if
		-- they are still in first person.
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

closeButton.Activated:Connect(function()
	setBoardVisible(false)
	boardDismissed = true
end)

-- Escape closes it too, matching PlotTerminal. In first person the close
-- button is a small target for a cursor the player has only just got back.
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.Escape and board.Visible then
		setBoardVisible(false)
		boardDismissed = true
	end
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

-- The line under the payout that says the delivery counted for something beyond
-- money. Unlocking a job slot is the loudest thing that can happen at a
-- drop-off, so it takes the whole line; otherwise the line quietly counts down
-- to the next one, which is what makes the ladder visible without needing a
-- screen of its own.
local function progressLine(progress)
	if type(progress) ~= "table" then
		return "" -- they left between parking and being paid; there is no count to show
	end
	local deliveries = progress.Deliveries or 0

	if progress.CapIncreased and progress.ContractCap then
		return string.format("\n<b>Job slot unlocked - the board now holds %d</b>", progress.ContractCap)
	end

	local milestone = progress.NextCapMilestone
	if not milestone then
		return string.format("\n%s completed", ProgressionConfig.DeliveryCountText(deliveries))
	end
	return string.format(
		"\n%s to a %s job slot",
		ProgressionConfig.DeliveryCountText(math.max(0, milestone.Deliveries - deliveries)),
		ordinal(milestone.Cap)
	)
end

local function showSummary(completed)
	local cargoType = CargoTypes.GetOrDefault(completed.TypeId)
	summaryTitle.Text = string.format("Delivered  +$%d", completed.Payout)
	summaryBody.Text = string.format(
		"%d x %s to %s\nCondition on arrival: %d%%\nPark: %s  (x%.2f total)%s%s",
		completed.Units,
		cargoType.DisplayName,
		completed.Destination,
		math.floor(completed.Condition * 100 + 0.5),
		completed.ParkLabel,
		completed.Multiplier,
		if completed.Balance then string.format("\nBalance: $%d", completed.Balance) else "",
		progressLine(completed.Progress)
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
	if update.Active then
		-- The accept went through. THIS is what closes the board, so a refused
		-- accept leaves it open instead of vanishing silently.
		accepting = false
		setBoardVisible(false)
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

-- The board OPENS the instant the test passes and CLOSES only once it has
-- failed continuously for this long. The asymmetry is the whole point:
-- truckIsInBay is a knife-edge test on two quantities that both flicker while
-- a truck sits still.
--
--   Velocity. A parked car on a spring suspension never settles to exactly
--   zero - VehiclePhysics' own comments call the residual jitter out, and
--   StoppedSpeed is deliberately tuned to sit just ABOVE it, which means the
--   occasional frame pokes through. Anything jostling the assembly (a hull box
--   resolving a contact, the driver shifting weight) pushes it over.
--
--   Containment. A bounding-box corner parked on the tolerance line crosses
--   back and forth as the body rocks on its springs.
--
-- Either one blipping for a single frame hides a panel the player is reading
-- and then snaps it back a quarter-second later, which looks like a bug even
-- now that reopening costs nothing. (It used to cost the player their jobs: the
-- reopen fired a fresh RemoteFunction and re-rolled all three offers. That is
-- no longer possible at all - the pool is persisted and asking for it has no
-- side effect - but the flicker was always the visible half of the problem.)
-- A second of grace costs nothing, since the truck is stationary and nothing
-- can have changed, and it makes leaving the bay the only thing that closes the
-- board.
local LEAVE_GRACE_SECONDS = 1
local outOfBayFor = 0

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
	local elapsed = accumulator
	accumulator = 0

	if truckIsInBay() then
		outOfBayFor = 0
		if board.Visible then
			tickBoard()
		elseif not boardDismissed and not activeContract then
			openBoard()
		end
		return
	end

	outOfBayFor += elapsed
	if outOfBayFor < LEAVE_GRACE_SECONDS then
		return -- a jitter blip, not a departure. Leave the board exactly as it is.
	end

	boardDismissed = false
	setBoardVisible(false)
end)

--=============================================================================
-- Destination waypoint
--=============================================================================

-- WHY THIS IS NOT A BillboardGui, which is the obvious first answer:
--
-- A BillboardGui is drawn at a point in the world, so it is visible exactly
-- when the player is already looking at the destination - and invisible when
-- they are facing the wrong way, which is the only time a waypoint is any use.
-- It also shrinks with distance (or pins at a size that is wrong at every
-- other distance), and MaxDistance has to be set to something finite.
--
-- So this is a screen-space marker instead. On screen, it sits over the
-- destination. Off screen - including behind the player - it clamps to the
-- edge and rotates an arrow to point the way. That is the behaviour that
-- answers "which way do I go", and it needs no world part at the far end.
--
-- Entirely client-side, as asked: it is one player's private navigation, the
-- server already knows the contract, and nothing here is an authority on
-- anything.

local waypoint = Instance.new("Frame")
waypoint.Size = UDim2.fromOffset(150, 62)
waypoint.AnchorPoint = Vector2.new(0.5, 0.5)
waypoint.BackgroundTransparency = 1
waypoint.Visible = false
waypoint.ZIndex = 0 -- under the board and the summary, never over a button
waypoint.Parent = screenGui

local waypointArrow = Instance.new("TextLabel")
waypointArrow.Size = UDim2.fromOffset(34, 34)
waypointArrow.Position = UDim2.new(0.5, 0, 0, 0)
waypointArrow.AnchorPoint = Vector2.new(0.5, 0)
waypointArrow.BackgroundTransparency = 1
waypointArrow.Font = Enum.Font.GothamBold
waypointArrow.TextSize = 26
waypointArrow.TextColor3 = ACCENT
waypointArrow.Text = "▲"
waypointArrow.ZIndex = 0
waypointArrow.Parent = waypoint

local waypointCaption = Instance.new("TextLabel")
waypointCaption.Position = UDim2.new(0.5, 0, 0, 34)
waypointCaption.Size = UDim2.new(1, 0, 0, 28)
waypointCaption.AnchorPoint = Vector2.new(0.5, 0)
waypointCaption.BackgroundTransparency = 1
waypointCaption.Font = Enum.Font.GothamBold
waypointCaption.TextSize = 13
waypointCaption.TextColor3 = BRIGHT_TEXT
waypointCaption.TextXAlignment = Enum.TextXAlignment.Center
waypointCaption.TextYAlignment = Enum.TextYAlignment.Top
-- A stroke rather than a panel behind it: the caption sits over open sky and
-- road at different moments, and a solid backing plate that size would be one
-- more thing blocking the windscreen in first person.
local captionStroke = Instance.new("UIStroke")
captionStroke.Color = Color3.fromRGB(0, 0, 0)
captionStroke.Thickness = 2
captionStroke.Transparency = 0.35
captionStroke.Parent = waypointCaption
waypointCaption.ZIndex = 0
waypointCaption.Text = ""
waypointCaption.Parent = waypoint

-- Resolved lazily and re-resolved while empty, for the same reason
-- findBaySpaces is: the destination models are hand-built in Studio and can
-- appear or be renamed after this script has already run.
local destinationModels = nil

local function findDestination(name)
	if not destinationModels then
		local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
		local folder = deliveryRoot and deliveryRoot:FindFirstChild(world.DestinationsFolderName)
		if not folder then
			return nil
		end
		destinationModels = folder
	end
	return destinationModels:FindFirstChild(name)
end

-- How far in from the screen edge the marker parks when the destination is
-- off screen. Enough to keep the whole caption on screen rather than half a
-- word of it.
local WAYPOINT_MARGIN = 86
-- The top margin is deeper because the job panel now sits at top-centre, and
-- the waypoint is only ever on screen while that panel is too - so they would
-- otherwise collide every time the destination is straight ahead and above.
local WAYPOINT_MARGIN_TOP = 128

RunService.RenderStepped:Connect(function()
	if not activeContract then
		waypoint.Visible = false
		return
	end

	local model = findDestination(activeContract.Stops[1])
	local camera = workspace.CurrentCamera
	if not model or not camera then
		waypoint.Visible = false
		return
	end

	-- The model's centre, as asked - GetPivot rather than GetBoundingBox
	-- because a destination is a building and its pivot is where the builder
	-- put it, which is a better "here" than the centre of a box that might
	-- include an awning.
	local target = model:GetPivot().Position
	local point, onScreen = camera:WorldToViewportPoint(target)
	local viewport = camera.ViewportSize

	-- Behind the camera comes back with a negative Z and coordinates that are
	-- mirrored through the centre. Flipping them back is what stops the arrow
	-- pointing left when the destination is behind and to the right.
	local behind = point.Z <= 0
	local x = if behind then viewport.X - point.X else point.X
	local y = if behind then viewport.Y - point.Y else point.Y

	local clampedX = math.clamp(x, WAYPOINT_MARGIN, viewport.X - WAYPOINT_MARGIN)
	local clampedY = math.clamp(y, WAYPOINT_MARGIN_TOP, viewport.Y - WAYPOINT_MARGIN)
	local edge = behind or not onScreen or clampedX ~= x or clampedY ~= y

	waypoint.Position = UDim2.fromOffset(clampedX, clampedY)

	if edge then
		-- Point from the middle of the screen toward where the destination
		-- actually is. The glyph is drawn pointing up, hence the +90.
		local dx, dy = x - viewport.X / 2, y - viewport.Y / 2
		waypointArrow.Rotation = math.deg(math.atan2(dy, dx)) + 90
		waypointArrow.Text = "▲"
	else
		waypointArrow.Rotation = 0
		waypointArrow.Text = "◆" -- a pin sitting on the spot, rather than a direction
	end

	-- Distance from the TRUCK, not the camera: the player is judging how far
	-- they have to drive, and in a chase camera the two differ by enough to
	-- look wrong when parked.
	local carModel = activeContract.Vehicle
	local from = carModel and carModel.PrimaryPart and carModel.PrimaryPart.Position or camera.CFrame.Position
	waypointCaption.Text = string.format("%s\n%.0f studs", activeContract.Stops[1], (target - from).Magnitude)

	waypoint.Visible = true
end)

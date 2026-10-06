-- The guided first delivery: claim a plot, get a truck out, drive to the depot,
-- take a job, deliver it. Five steps, one banner at the bottom of the screen and
-- one GuideMarker pointing at whatever the player is supposed to be looking at.
--
-- WHY THIS EXISTS AT ALL. Watching children play it, the loop that reads as
-- obvious from inside the code is not obvious from inside the truck. They
-- claimed a plot, spawned a car, and then drove off to ram each other and crash
-- into things to watch the damage model - which is a completely reasonable thing
-- to do with a truck, and means they never found the depot, never carried a
-- load, and never discovered there was a game underneath. Step three is the one
-- this whole file was written for; the other four exist so that step three has
-- somewhere to start from.
--
-- ENTIRELY CLIENT-SIDE, and an authority on nothing - the same split
-- DepotGuides.client.luau's header sets out. Every step's completion test is a
-- state the server has ALREADY committed to and replicated (a plot's owner
-- attribute, a spawned vehicle's owner attribute, a DeliveryUpdate), so this
-- script can only ever notice things that have really happened. It cannot grant
-- a step, and there is nothing here to forge. The only thing it tells the server
-- is "stop showing me this", which is TutorialFinished.
--
-- STEPS ARE STATE, NOT EVENTS. Every step asks "is this done yet" about the
-- world as it is right now, rather than listening for the moment it happens.
-- That is what makes replaying the tutorial from the settings menu work with no
-- extra code: a player who restarts it while already holding a plot, a truck and
-- a contract is simply already past those steps on the first poll and lands on
-- the one thing they have not done. It also means nothing can be missed by a
-- dropped event, and a player who reverses out of the depot bay mid-step is not
-- stuck in a step whose trigger has been and gone.
--
-- WHAT POINTS WHERE is entirely GuideMarker's problem - see its header for why
-- it is four overlapping things at once and why none of them is a line painted
-- on the road. This file only ever decides WHICH object is the answer right now.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local GuideMarker = require(ReplicatedStorage.Modules.UI.GuideMarker)
local GuideSpotlight = require(ReplicatedStorage.Modules.UI.GuideSpotlight)
local Haulage = require(ReplicatedStorage.Modules.Delivery.Haulage)
local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)
local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)
local TutorialConfig = require(ReplicatedStorage.Modules.Tutorial.TutorialConfig)
local VehicleCatalog = require(ReplicatedStorage.Modules.Vehicles.VehicleCatalog)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local GameSettings = require(script.Parent.GameSettings)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- WaitForChild rather than direct indexing, for the reason PlotTerminal's
-- header spells out: Workspace is not guaranteed to have replicated by the time
-- PlayerScripts starts, and a direct index would throw and kill this whole
-- script with no symptom beyond "the tutorial never appeared".
local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")
local VehicleFolder = workspace:WaitForChild("Vehicles")

local getPlotDataFunction = ReplicatedStorage:WaitForChild("GetPlotData")
local deliveryUpdateEvent = ReplicatedStorage:WaitForChild("DeliveryUpdate")
local tutorialFinishedEvent = ReplicatedStorage:WaitForChild("TutorialFinished")

local world = DeliveryConfig.World

-- Matches the delivery HUD and the plot terminal, so the banner reads as part
-- of the same UI rather than as a second one bolted on.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local CARD = Color3.fromRGB(28, 31, 38)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = TutorialConfig.Color

--=============================================================================
-- The banner
--=============================================================================

-- BOTTOM-CENTRE, not top-centre, and this is not a style choice: the delivery
-- HUD's running-job panel already owns top-centre (see its comment for why it
-- had to move there), and step five is precisely the step where both would be
-- on screen at once. Bottom-centre is the other band Roblox's own UI leaves
-- alone, and it is out of the windscreen in first person.
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TutorialGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
-- Above the delivery HUD and the plot terminal (both 0) AND above the spotlight
-- overlay (5), below the settings menu (100) and its launcher (99).
--
-- Being above the spotlight is the load-bearing part. The plot terminal is a
-- 720x700 panel, and on a laptop screen its rectangle reaches down into where
-- this banner sits - so a scrim drawn over that panel would cover the banner and
-- swallow clicks on the Skip button underneath it. The tutorial must never be
-- the thing covering the button it is telling the player to press, and it must
-- never be the thing covering the way OUT of itself either.
screenGui.DisplayOrder = 6
screenGui.Enabled = false
screenGui.Parent = playerGui

local banner = Instance.new("Frame")
banner.Name = "Banner"
-- Sized in scale with a cap, rather than a fixed 520px: the same panel has to
-- fit a phone held sideways and not look like a stripe on a monitor.
banner.Size = UDim2.new(0.82, 0, 0, 106)
banner.AnchorPoint = Vector2.new(0.5, 1)
banner.Position = UDim2.new(0.5, 0, 1, -20)
banner.BackgroundColor3 = PANEL
banner.BackgroundTransparency = 0.06
banner.BorderSizePixel = 0
banner.Parent = screenGui

local bannerSize = Instance.new("UISizeConstraint")
bannerSize.MinSize = Vector2.new(300, 106)
bannerSize.MaxSize = Vector2.new(580, 106)
bannerSize.Parent = banner

Instance.new("UICorner", banner).CornerRadius = UDim.new(0, 10)

local bannerStroke = Instance.new("UIStroke")
bannerStroke.Color = ACCENT
bannerStroke.Thickness = 2
bannerStroke.Parent = banner

-- The step counter. Small, but it is the only thing on screen that says how
-- much of this is left, which is the question a player asks before deciding
-- whether to skip.
local stepCounter = Instance.new("TextLabel")
stepCounter.BackgroundTransparency = 1
stepCounter.Position = UDim2.fromOffset(16, 10)
stepCounter.Size = UDim2.new(1, -110, 0, 14)
stepCounter.Font = Enum.Font.GothamBold
stepCounter.TextSize = 11
stepCounter.TextColor3 = ACCENT
stepCounter.TextXAlignment = Enum.TextXAlignment.Left
stepCounter.Text = ""
stepCounter.Parent = banner

local stepTitle = Instance.new("TextLabel")
stepTitle.BackgroundTransparency = 1
stepTitle.Position = UDim2.fromOffset(16, 26)
stepTitle.Size = UDim2.new(1, -110, 0, 24)
stepTitle.Font = Enum.Font.LuckiestGuy
stepTitle.TextSize = 21
stepTitle.TextColor3 = BRIGHT_TEXT
stepTitle.TextXAlignment = Enum.TextXAlignment.Left
stepTitle.Text = ""
stepTitle.Parent = banner

local stepBody = Instance.new("TextLabel")
stepBody.BackgroundTransparency = 1
stepBody.Position = UDim2.fromOffset(16, 52)
stepBody.Size = UDim2.new(1, -110, 0, 44)
stepBody.Font = Enum.Font.GothamMedium
stepBody.TextSize = 15
stepBody.TextColor3 = DIM_TEXT
stepBody.TextXAlignment = Enum.TextXAlignment.Left
stepBody.TextYAlignment = Enum.TextYAlignment.Top
stepBody.TextWrapped = true
stepBody.Text = ""
stepBody.Parent = banner

-- Quiet, in the corner, and always there. A tutorial without a visible way out
-- is a tutorial the player fights; one with an obvious exit is one they are
-- willing to start. Styled as the secondary control it is - a filled card, not
-- the accent green the instructions use.
local skipButton = Instance.new("TextButton")
skipButton.AnchorPoint = Vector2.new(1, 1)
skipButton.Position = UDim2.new(1, -14, 1, -14)
skipButton.Size = UDim2.fromOffset(82, 30)
skipButton.BackgroundColor3 = CARD
skipButton.BorderSizePixel = 0
skipButton.AutoButtonColor = true
skipButton.Font = Enum.Font.GothamBold
skipButton.TextSize = 13
skipButton.TextColor3 = DIM_TEXT
skipButton.Text = "Skip"
skipButton.Parent = banner
Instance.new("UICorner", skipButton).CornerRadius = UDim.new(0, 8)

local skipStroke = Instance.new("UIStroke")
skipStroke.Color = PANEL_EDGE
skipStroke.Parent = skipButton

--=============================================================================
-- Which control each step is asking the player to click
--=============================================================================

-- The two steps whose target is a piece of UI rather than a place. A beam in the
-- world cannot say "that button", and for the job board it cannot say the harder
-- thing either: which of four almost identical cards, and that picking one is
-- allowed at all. GuideSpotlight does both by dimming the panel down to a single
-- control - see its header for why that is worth a module.
--
-- These reach into two other scripts' ScreenGuis BY NAME, which is the only
-- coupling in this file. It is deliberately one-way and entirely optional: every
-- lookup below is a FindFirstChild chain that yields nil, the spotlight simply
-- clears, and the step still completes on its own state test - which never goes
-- anywhere near the GUI. Renaming any of these costs the dimming and nothing
-- else. Both sides carry a comment saying so.
local function terminalSpotlight()
	local gui = playerGui:FindFirstChild("PlotTerminalGui")
	local panel = gui and gui:FindFirstChild("TerminalPanel")
	-- Recursive: the button lives inside the garage tab's carousel, and the
	-- tutorial has no business knowing the tab layout.
	local button = panel and panel:FindFirstChild("SpawnVehicleButton", true)
	return panel, button
end

local function boardSpotlight()
	local gui = playerGui:FindFirstChild("DeliveryGui")
	local panel = gui and gui:FindFirstChild("ContractBoard")
	local list = panel and panel:FindFirstChild("OfferList")
	-- ALWAYS the first card, never "the best one" or "a random one". Which card
	-- is the right card is not the lesson - that the cards are clickable at all
	-- is - and picking a different one each time the board redraws would move
	-- the cursor somewhere new every few seconds, which is the opposite of what
	-- this is for.
	local firstOffer = list and list:FindFirstChild("Offer1")
	return panel, firstOffer
end

--=============================================================================
-- World lookup
--=============================================================================

-- Lazy and re-tried while empty, matching DeliveryHud's findBaySpaces and
-- DepotGuides' findLoadingBay: the depot is hand-built in Studio and can
-- appear, move or be renamed after this script has already run.
local function findLoadingBay()
	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	local depotFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DepotFolderName)
	return depotFolder and depotFolder:FindFirstChild(world.LoadingBayName)
end

local function findDestination(name)
	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	local folder = deliveryRoot and deliveryRoot:FindFirstChild(world.DestinationsFolderName)
	return folder and folder:FindFirstChild(name)
end

local function spacesIn(container)
	local spaces = {}
	if not container then
		return spaces
	end
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name:sub(1, #world.SpacePrefix) == world.SpacePrefix then
			table.insert(spaces, descendant)
		end
	end
	return spaces
end

-- GuideMarker only accepts a Model or a BasePart (it needs a bounding box to
-- put a beam on top of), and a hand-built depot is as likely to be a Folder as
-- a Model. Falling back to a part INSIDE it keeps the marker working on
-- geometry nobody grouped, instead of silently pointing at nothing.
local function markableIn(container)
	if not container then
		return nil
	end
	if container:IsA("Model") or container:IsA("BasePart") then
		return container
	end
	return container:FindFirstChildWhichIsA("BasePart", true)
end

-- WHAT TO POINT AT INSIDE A DEPOT OR A DESTINATION - the SIGN, not the
-- building.
--
-- Highlighting the whole model was the first version and it is genuinely
-- unpleasant: a warehouse is the largest object on screen, an AlwaysOnTop
-- outline around it fills the windscreen, and the player ends up driving toward
-- a green rectangle they cannot see past. It also points at the wrong thing.
-- "The destination" is not a building, it is the one door of it you park at,
-- and the sign is exactly the marker a real driver looks for.
--
-- Order is sign, then parking space, then the model itself. The space is the
-- fallback rather than the model because a place with no sign built yet still
-- has somewhere you have to end up, and a bay marker is a far smaller and more
-- honest target than the whole warehouse.
local placeTargetCache = {}

local function placeTarget(container)
	if not container then
		return nil
	end

	local cached = placeTargetCache[container]
	-- Re-resolved if the cached part has since been deleted or reparented, so a
	-- building edited in Studio mid-session heals itself on the next poll rather
	-- than pointing at a ghost for the rest of the session.
	if cached and cached:IsDescendantOf(workspace) then
		return cached
	end

	-- One pass for both prefixes. A sign wins outright the moment one is found;
	-- the first space seen is remembered in case no sign ever is.
	local space = nil
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") then
			if descendant.Name:sub(1, #world.SignPrefix) == world.SignPrefix then
				placeTargetCache[container] = descendant
				return descendant
			elseif not space and descendant.Name:sub(1, #world.SpacePrefix) == world.SpacePrefix then
				space = descendant
			end
		end
	end

	local resolved = space or markableIn(container)
	placeTargetCache[container] = resolved
	return resolved
end

local baySpaces = {}

local function findBaySpaces()
	if #baySpaces == 0 then
		baySpaces = spacesIn(findLoadingBay())
	end
	return baySpaces
end

-- ONE parking space, picked once and stuck to for the rest of the run - not
-- "the nearest one" or "the first one every time". The depot sign already
-- says WHERE the depot is; this says "and a bay looks like this", and it only
-- has to say that once. Re-picking on every poll would have the arrow hop to
-- a different space every quarter second as ParkGrade re-evaluates, which
-- reads as broken rather than as a hint.
--
-- Re-resolved only if the cached space has been deleted or reparented - the
-- same self-healing `placeTarget` and `terminalTargetOf` already do - so a bay
-- edited in Studio mid-session does not leave this pointing at a ghost.
local chosenSpace = nil

local function pickSpace()
	if chosenSpace and chosenSpace:IsDescendantOf(workspace) then
		return chosenSpace
	end
	local spaces = findBaySpaces()
	chosenSpace = if #spaces > 0 then spaces[math.random(#spaces)] else nil
	return chosenSpace
end

--=============================================================================
-- What the world currently says
--=============================================================================

-- A PLOT IS A MODEL *OR* A FOLDER, and getting this wrong is silent. PlotManager
-- accepts either (see its setupPlot), and the garage in the place file is built
-- from Folders - so an IsA("Model") test here, which is what this started as,
-- makes every loop below find nothing at all: no plot to point at, and a claim
-- step that can never complete because the plot the player just claimed is not
-- one this script is willing to look at. Both failures are silent, because "no
-- free plot" and "no plot of mine" are legitimate answers this code has to
-- handle anyway.
--
-- Tested at all, rather than trusting the folder's contents, because a stray
-- part dropped in beside the plots has no Terminal and no pivot worth
-- measuring, and would error out of the poll instead of just not being a plot.
local function isPlot(instance)
	return instance:IsA("Model") or instance:IsA("Folder")
end

local function myPlot()
	for _, plotModel in VehiclePlotsFolder:GetChildren() do
		if isPlot(plotModel) and PlotOwnership.IsOwner(player, plotModel) then
			return plotModel
		end
	end
	return nil
end

-- Where a plot's "press F here" actually is. The prompts hang off
-- Terminal.Screen (see PlotTerminal's setupPlotPrompts), so that is what the
-- player has to walk up to - but the terminal as a whole reads better as a
-- highlighted object than a single screen face does.
--
-- Everything goes through markableIn because the plot AND its terminal are both
-- as likely to be Folders as Models in a hand-built garage, and GuideMarker can
-- only point at something with a bounding box. Falling through to a part inside
-- is what keeps the marker working on ungrouped geometry instead of quietly
-- pointing at nothing - which is exactly what returning the plot itself used to
-- do when the plot was a Folder.
local function terminalTargetOf(plotModel)
	if not plotModel then
		return nil
	end
	local terminal = plotModel:FindFirstChild("Terminal")
	return (terminal and markableIn(terminal)) or markableIn(plotModel)
end

-- The nearest plot nobody has claimed. Recomputed every poll rather than picked
-- once, so a plot somebody else takes while the player is walking toward it
-- moves the marker on to the next one instead of guiding them to a terminal
-- that will now refuse them.
local function nearestFreePlot()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local from = root and root.Position

	local best, bestDistance = nil, math.huge
	for _, plotModel in VehiclePlotsFolder:GetChildren() do
		if isPlot(plotModel) and not PlotOwnership.IsClaimed(plotModel) then
			if not from then
				return plotModel -- no character yet; any free plot is a fine answer
			end
			local target = terminalTargetOf(plotModel)
			local distance = target and (target:GetPivot().Position - from).Magnitude or math.huge
			if distance < bestDistance then
				best, bestDistance = plotModel, distance
			end
		end
	end
	return best
end

local function myVehicle()
	for _, carModel in VehicleFolder:GetChildren() do
		if carModel:IsA("Model") and VehicleOwnership.GetOwnerUserId(carModel) == player.UserId then
			return carModel
		end
	end
	return nil
end

-- The same two-part test DeliveryHud uses to decide the board should open -
-- inside a bay space AND stopped - rather than a proximity radius. Sharing the
-- test is what makes step three finish on exactly the frame the job list
-- appears, instead of a moment before it (leaving the player staring at "pick a
-- job" with no list) or a moment after (leaving the list open under an
-- instruction to keep driving).
--
-- `rig` asks it of the freight building's rig bays instead, which is where a
-- tractor and trailer takes its jobs. Haulage.FindParkedSpace is the HUD's own
-- containment test, so for a rig it measures the TRAILER.
local rigSpaces = {}

local function findRigSpaces()
	if #rigSpaces == 0 then
		rigSpaces = Haulage.DepotSpaces(true)
	end
	return rigSpaces
end

local function rawInBay(rig)
	local spaces = if rig then findRigSpaces() else findBaySpaces()
	if #spaces == 0 then
		return false
	end
	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	local chassis = carModel and carModel.PrimaryPart
	if not chassis then
		return false
	end
	if not ParkGrade.IsStopped(chassis) then
		return false
	end
	return Haulage.FindParkedSpace(carModel, spaces) ~= nil
end

-- STICKY, on exactly the grace the HUD shows the job board on, and it has to
-- be: this is what the banner and the spotlight are driven by, and the board
-- are on screen together. Asking the raw question meant the tutorial made its
-- own decision about whether the board was open, disagreed with the board a few
-- times a second, and flipped its instruction between "click a job" and "park
-- fully inside" while the list sat there open in front of the player.
--
-- Timestamped rather than accumulated, because this is called several times per
-- poll and once directly out of start(), so there is no single elapsed value to
-- add up. lastInBayAt starting at zero reads as "a very long time ago", which
-- is the right answer before the player has ever parked.
local lastInBayAt = { [true] = 0, [false] = 0 }

local function parkedIn(rig)
	if rawInBay(rig) then
		lastInBayAt[rig] = os.clock()
		return true
	end
	return (os.clock() - lastInBayAt[rig]) < DeliveryConfig.Parking.LeaveGraceSeconds
end

local function parkedInBay()
	return parkedIn(false)
end

local function parkedInFreightBay()
	return parkedIn(true)
end

--=============================================================================
-- The rig
--=============================================================================

-- What the trailer-truck track asks about. All of it is replicated state, like
-- everything else here: the Hitch attachment on the truck, the ObjectValue the
-- server points at the coupled trailer, the owner attribute on the trailer.

-- The player's spawned truck, if it is one that tows.
local function myTractor()
	local carModel = myVehicle()
	return if carModel and Haulage.IsTractor(carModel) then carModel else nil
end

-- Hitched right now. Not sticky, and deliberately so: a step that needs the
-- trailer on swaps to its Hint the moment it is dropped, which is the
-- instruction the player needs at that moment.
local function trailerHitched()
	local tractor = myTractor()
	return tractor ~= nil and Haulage.Trailer(tractor) ~= nil
end

-- The player's own trailer, wherever it is standing - or, until it has
-- streamed in (or if the yard was full when the truck spawned), the stalls it
-- will be stood in.
local function myTrailerTarget()
	local trailer =
		TrailerHitch.FindOwnedTrailer(workspace:FindFirstChild(TrailerHitch.WorkspaceFolderName), player.UserId)
	if trailer then
		return trailer, { Label = "Your trailer" }
	end
	return markableIn(TrailerHitch.FindStalls()), { Label = "TRAILER STALLS" }
end

-- One rig bay, picked once - the same reasoning as pickSpace.
local chosenRigSpace = nil

local function pickRigSpace()
	if chosenRigSpace and chosenRigSpace:IsDescendantOf(workspace) then
		return chosenRigSpace
	end
	local spaces = findRigSpaces()
	chosenRigSpace = if #spaces > 0 then spaces[math.random(#spaces)] else nil
	return chosenRigSpace
end

local function drivingTractor()
	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	return carModel ~= nil and Haulage.IsTractor(carModel)
end

--=============================================================================
-- Server-driven state
--=============================================================================

-- Read straight off the RemoteEvent rather than asked of DeliveryHud, the same
-- way DepotGuides does it: a RemoteEvent takes as many connections as you like,
-- and routing this through the HUD would make the tutorial depend on a script
-- it otherwise has nothing to do with.
local activeContract = nil
-- Set once, by the delivery that finishes the tutorial. A flag rather than a
-- state to poll, because "has delivered" is the one step condition that leaves
-- no trace in the world afterwards - a second later the truck is empty and
-- parked, which looks identical to never having taken a job at all.
local deliveredDuringRun = false

-- Set by DeliveryHud on the local Player for as long as its delivery clipboard
-- is on screen (see RECEIPT_ATTRIBUTE there). The Deliver step does not count
-- as done until it clears, so the clipboard gets read on its own and the
-- finish banner only appears once it has gone. Nil - the HUD missing or
-- renamed - reads as "not showing", so the step can never hang on it.
local RECEIPT_ATTRIBUTE = "DeliveryReceiptShowing"

local function receiptShowing()
	return player:GetAttribute(RECEIPT_ATTRIBUTE) == true
end

deliveryUpdateEvent.OnClientEvent:Connect(function(update)
	if type(update) ~= "table" then
		return
	end
	activeContract = update.Active
	if update.Completed then
		deliveredDuringRun = true
	end
end)

--=============================================================================
-- The steps
--=============================================================================

-- One entry per TutorialConfig.Steps id.
--
--   IsDone   has this already happened? Asked about the world as it is, never
--            about an event that fired.
--   Ready    is the player in a position to be working on it? False puts the
--            step's Hint on the banner instead of its Body, and usually points
--            the marker somewhere else - at the truck they got out of, most
--            often. NOT a step of its own: the goal has not changed, and a
--            counter that jumped from "3 of 5" to "4 of 6" every time somebody
--            hopped out would be lying about how much was left.
--   Target   what the marker points at, and how. Returns instance, options.
local stepLogic = {
	ClaimPlot = {
		IsDone = function()
			return myPlot() ~= nil
		end,
		Ready = function()
			return true
		end,
		Target = function()
			return terminalTargetOf(nearestFreePlot()), { Label = "Free garage" }
		end,
	},

	SpawnVehicle = {
		IsDone = function()
			return myVehicle() ~= nil
		end,
		Ready = function()
			return true
		end,
		Target = function()
			-- Beam off. The player is standing at this terminal - they just
			-- claimed it - and a 300-stud column out of something two metres in
			-- front of your face is not navigation, it is a wall.
			return terminalTargetOf(myPlot()), { Label = "Your terminal", Beam = false }
		end,
		-- Only bites once the terminal is actually open; until then both come
		-- back nil and the spotlight stays clear, leaving the world marker to
		-- get the player to the terminal in the first place.
		Spotlight = terminalSpotlight,
	},

	DriveToDepot = {
		IsDone = parkedInBay,
		Ready = function()
			return VehicleSeats.FindCarDrivenBy(player, VehicleFolder) ~= nil
		end,
		Target = function(ready)
			if not ready then
				return myVehicle(), { Label = "Your car", Beam = false }
			end
			-- Nothing here once driving - SpaceMarker below takes over as the
			-- ONLY marker on screen. It used to be both at once: this beam on
			-- the depot sign AND a second arrow over one bay space, and two
			-- bouncing arrows a few dozen studs apart read as two different
			-- places to go rather than one place with a specific spot in it.
			return nil, nil
		end,
		-- The one marker once the player is actually driving (the depot sign
		-- alone is enough before that - a car with nowhere to point it at yet
		-- has nothing to relate a specific space to). Full beam and screen
		-- arrow, same as the depot sign used to carry, since this is now the
		-- only thing answering "which way" at range as well as "park here" up
		-- close - see pickSpace for why it is always the same one space.
		SpaceMarker = function(ready)
			if not ready then
				return nil, nil
			end
			return pickSpace(), { Label = "Park Here" }
		end,
	},

	ChooseCargo = {
		IsDone = function()
			return activeContract ~= nil
		end,
		Ready = parkedInBay,
		Target = function(ready)
			if ready then
				-- Nothing in the world to point at: the job list is on screen,
				-- and the spotlight on it is what says so. A marker still
				-- burning on the bay the player is already parked in would be
				-- pointing at the one thing they have definitely already found.
				return nil, nil
			end
			return placeTarget(findLoadingBay()), { Label = "DEPOT" }
		end,
		-- Only while parked, because that is the only time the board exists.
		-- Handed the `ready` flag rather than working it out again, so the
		-- dimming appears on exactly the poll the board does.
		Spotlight = function(ready)
			if not ready then
				return nil, nil
			end
			return boardSpotlight()
		end,
	},

	Deliver = {
		IsDone = function()
			return deliveredDuringRun and not receiptShowing()
		end,
		Ready = function()
			return VehicleSeats.FindCarDrivenBy(player, VehicleFolder) ~= nil
		end,
		Target = function(ready)
			if not ready then
				return myVehicle(), { Label = "Your car", Beam = false }
			end
			local stop = activeContract and activeContract.Stops and activeContract.Stops[1]
			if not stop then
				return nil, nil
			end
			-- ScreenArrow off, and only here: the delivery HUD already draws its
			-- own edge-clamped waypoint for exactly this destination whenever a
			-- contract is active. Two arrows a few pixels apart, disagreeing
			-- slightly because one measures from the truck and the other from
			-- the camera, is worse than either alone. The beam and the highlight
			-- have no such duplicate, so they stay.
			return placeTarget(findDestination(stop)), { Label = stop, ScreenArrow = false }
		end,
	},

	--=========================================================================
	-- The trailer-truck track (TutorialConfig.Tracks.HitchTruck)
	--=========================================================================

	SpawnRig = {
		IsDone = function()
			return myTractor() ~= nil
		end,
		Ready = function()
			return true
		end,
		Target = function()
			return terminalTargetOf(myPlot()), { Label = "Your terminal" }
		end,
		-- Bites once the terminal is open, on whichever truck is showing - so
		-- the text has to say WHICH truck; the dimming only says "this button".
		Spotlight = terminalSpotlight,
	},

	HitchTrailer = {
		IsDone = trailerHitched,
		Ready = drivingTractor,
		Target = function(ready)
			if not ready then
				return myTractor(), { Label = "Your truck", Beam = false }
			end
			-- From here the hitch prompt (TrailerHitchPrompt) does the close
			-- work - "not lined up", "stop completely", "[T] Hitch trailer" -
			-- and this only has to get the truck to the right trailer.
			return myTrailerTarget()
		end,
	},

	ParkAtFreight = {
		IsDone = parkedInFreightBay,
		-- Driving, WITH the trailer on. Drop it and the Hint says to pick it
		-- back up, rather than leaving an arrow over a bay a bobtail tractor
		-- can never be "parked" in.
		Ready = function()
			return drivingTractor() and trailerHitched()
		end,
		Target = function(ready)
			if ready then
				return nil, nil -- SpaceMarker below is the one marker, as in DriveToDepot
			end
			if not drivingTractor() then
				return myTractor(), { Label = "Your truck", Beam = false }
			end
			return myTrailerTarget()
		end,
		NoTargetWhenReady = true,
		SpaceMarker = function(ready)
			if not ready then
				return nil, nil
			end
			return pickRigSpace(), { Label = "Back your trailer in" }
		end,
	},

	ChooseFreight = {
		IsDone = function()
			return activeContract ~= nil
		end,
		Ready = parkedInFreightBay,
		Target = function(ready)
			if ready then
				return nil, nil
			end
			local freightBay = Haulage.DepotBay(true)
			return (freightBay and freightBay:FindFirstChild("FreightBoard")) or markableIn(freightBay), { Label = "FREIGHT" }
		end,
		NoTargetWhenReady = true,
		Spotlight = function(ready)
			if not ready then
				return nil, nil
			end
			return boardSpotlight()
		end,
	},

	DeliverFreight = {
		IsDone = function()
			return deliveredDuringRun and not receiptShowing()
		end,
		Ready = function()
			return drivingTractor() and trailerHitched()
		end,
		Target = function(ready)
			if not ready then
				if not drivingTractor() then
					return myTractor(), { Label = "Your truck", Beam = false }
				end
				return myTrailerTarget()
			end
			local stop = activeContract and activeContract.Stops and activeContract.Stops[1]
			local destination = stop and findDestination(stop)
			if not destination then
				return nil, nil
			end
			-- The long bay itself rather than the building's sign: a rig
			-- destination has ordinary bays as well, and the trailer only
			-- counts in the one that is long enough for it.
			return Haulage.SpacesIn(destination, true)[1] or placeTarget(destination), { Label = stop, ScreenArrow = false }
		end,
		HoldsForReceipt = true,
	},
}

-- Flags on the two first-delivery steps that the runner used to recognise by
-- name. Set here, beside the track's own, so the runner asks one question of
-- every step instead of keeping a list of ids.
stepLogic.DriveToDepot.NoTargetWhenReady = true
stepLogic.ChooseCargo.NoTargetWhenReady = true
stepLogic.Deliver.HoldsForReceipt = true

--=============================================================================
-- The runner
--=============================================================================

local marker = nil
local running = false
local stepIndex = 0
local finishToken = 0
-- Which tutorial is running: nil for the first-delivery one, or a
-- TutorialConfig.Tracks key. Everything that differs between them - the steps,
-- the finish message, whether the server is told - is read through the three
-- functions below, so the runner itself never asks which one it is.
local activeTrack = nil

local function activeSteps()
	local track = activeTrack and TutorialConfig.Tracks[activeTrack]
	return if track then track.Steps else TutorialConfig.Steps
end

local function activeFinish()
	local track = activeTrack and TutorialConfig.Tracks[activeTrack]
	return if track then track.Finish else TutorialConfig.Finish
end

-- TutorialFinished sets the save's TutorialDone, which is about the FIRST
-- tutorial: "do not show this to me on join". A track is only ever started by
-- a purchase popup or the settings menu, so it has nothing to record.
local function tellServerFinished()
	if activeTrack == nil then
		tutorialFinishedEvent:FireServer()
	end
end
-- [step id] = true once its "nothing to point at" warning has been printed. Not
-- cleared on restart: the warning is about the PLACE being wrong, and a second
-- run of the tutorial will not have fixed it.
local warnedNoTarget = {}

local spotlight = nil

local function ensureSpotlight()
	if not spotlight then
		spotlight = GuideSpotlight.new({
			Parent = playerGui,
			Color = ACCENT,
			Name = "TutorialSpotlight",
		})
	end
	return spotlight
end

local function ensureMarker()
	if not marker then
		marker = GuideMarker.new({
			Parent = screenGui,
			Color = ACCENT,
			Name = "TutorialMarker",
		})
	end
	return marker
end

-- A second, independent GuideMarker for DriveToDepot's parking space - see
-- pickSpace above for why it is one fixed space rather than "the nearest
-- one". A separate instance rather than reusing `marker` for both: the depot
-- sign and the space it is describing are two different targets on screen at
-- once once the player is close enough for both to matter, and GuideMarker
-- only ever tracks one target at a time.
local spaceMarker = nil

local function ensureSpaceMarker()
	if not spaceMarker then
		spaceMarker = GuideMarker.new({
			Parent = screenGui,
			Color = ACCENT,
			Name = "TutorialSpaceMarker",
		})
	end
	return spaceMarker
end

-- A quick flash of the banner's edge whenever the words change. Without it the
-- text simply swaps while the player is looking out of the windscreen, and the
-- next thing they read is an instruction they think they have already followed.
-- The colour change is what makes it catch the eye; a thickness pulse alone in
-- the same green was easy to miss while driving.
--
-- `times` is how many white pulses: several for a brand new step, one for a
-- step swapping between its Body and Hint. Each pulse is green -> white ->
-- green (the tween reverses), so it always comes to rest back on ACCENT.
local flashTween = nil

local function flashBanner(times)
	-- Cancelled rather than left to finish, so a step arriving mid-flash
	-- restarts the count instead of two tweens fighting over the stroke.
	if flashTween then
		flashTween:Cancel()
	end
	bannerStroke.Color = ACCENT
	bannerStroke.Thickness = 2
	flashTween = TweenService:Create(
		bannerStroke,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, math.max(1, times) - 1, true),
		{ Thickness = 6, Color = TutorialConfig.FlashColor }
	)
	flashTween:Play()
end

local function playStepSound()
	local soundId = TutorialConfig.StepSoundId
	if type(soundId) ~= "string" or soundId == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	SoundService:PlayLocalSound(sound)
end

local lastRenderedText = nil
-- The counter line ("STEP 2 OF 5", "DONE", "TIP") is what says a NEW step has
-- arrived, as opposed to the same step swapping between its Body and Hint -
-- so the sound keys off it, while the flash keys off the text.
local lastRenderedCounter = nil

local function renderBanner(counter, title, body)
	stepCounter.Text = counter
	stepTitle.Text = title
	stepBody.Text = body
	-- Hidden while DeliveryHud's clipboard is up (see poll); any render is
	-- the tutorial having something to say again.
	banner.Visible = true

	local newStep = lastRenderedCounter ~= counter
	if newStep then
		lastRenderedCounter = counter
		playStepSound()
	end

	-- Flashed on the TEXT changing rather than on the step changing, so the
	-- swap between a step's Body and its Hint - which is a different
	-- instruction, even though the step number has not moved - gets the same
	-- announcement as a new step does.
	if newStep or lastRenderedText ~= title .. "\0" .. body then
		lastRenderedText = title .. "\0" .. body
		flashBanner(if newStep then TutorialConfig.NewStepFlashes else 1)
	end
end

local stop -- forward declaration; start() and the skip button both call it

-- IS THE TUTORIAL ON SCREEN RIGHT NOW. Mirrored onto the local Player as an
-- attribute because another script needs the answer and there is no honest way
-- for it to work the answer out for itself.
--
-- The garage terminal hides its upgrade section while this is running: a
-- first-time player is being told to press one button, and ten upgrade cards
-- next to that instruction are noise the tutorial's own banner is partly
-- sitting on top of anyway. It originally asked the SAVE for this - the
-- TutorialDone field off GetPlotData - which is a different question and gets
-- the wrong answer twice over. Replaying from the settings menu runs the
-- tutorial with the flag already true, and flushPlayerData sets the flag on
-- every disconnect, so from a player's second session onward it is permanently
-- true while the tutorial may well be running. "Saved as completed" and
-- "happening right now" are not the same fact, and only this one is live.
--
-- Client-only and deliberately not replicated: an attribute a LocalScript sets
-- on its own Player stays on this client, which is right - it describes what is
-- on this screen, and the server has no use for it.
local TUTORIAL_ACTIVE_ATTRIBUTE = "TutorialActive"

local function setRunning(value)
	running = value
	player:SetAttribute(TUTORIAL_ACTIVE_ATTRIBUTE, value)
end

-- Everything torn down, the banner hidden, and the server told. Called on
-- finish, on skip, and on a restart before the new run begins - so there is
-- exactly one path that takes the tutorial off the screen.
--
-- `tellServer` is false only for the restart case: the flag is already set (a
-- replay is only ever offered to somebody it has been set for) and firing the
-- remote again would be a round trip that changes nothing.
stop = function(tellServer)
	setRunning(false)
	stepIndex = 0
	lastRenderedText = nil
	lastRenderedCounter = nil
	finishToken += 1

	if spotlight then
		spotlight:Destroy()
		spotlight = nil
	end
	if marker then
		marker:Destroy()
		marker = nil
	end
	if spaceMarker then
		spaceMarker:Destroy()
		spaceMarker = nil
	end
	screenGui.Enabled = false

	if tellServer then
		tellServerFinished()
	end
end

local function finish()
	-- The banner survives the teardown for a few seconds, saying it is over.
	-- A tutorial that simply stops mid-drive is indistinguishable from one that
	-- broke, and the player is owed the difference.
	if spotlight then
		spotlight:Destroy()
		spotlight = nil
	end
	if marker then
		marker:Destroy()
		marker = nil
	end
	if spaceMarker then
		spaceMarker:Destroy()
		spaceMarker = nil
	end
	setRunning(false)
	stepIndex = 0

	local finishMessage = activeFinish()
	renderBanner("DONE", finishMessage.Title, finishMessage.Body)
	skipButton.Text = "Close"

	tellServerFinished()

	-- A token rather than a cancellable task: restarting the tutorial from the
	-- settings menu inside these few seconds would otherwise have the old
	-- timer hide the new run's banner.
	finishToken += 1
	local token = finishToken
	-- Read now, not inside the timer: by the time it fires a different
	-- tutorial may have been started (the token check catches that) and this
	-- must still describe the one that just finished.
	local wasFirstTutorial = activeTrack == nil
	task.delay(finishMessage.Seconds, function()
		if finishToken ~= token then
			return
		end

		-- The garage nudge belongs to the first tutorial only; a player
		-- finishing a track bought the truck AT that terminal.
		if not wasFirstTutorial then
			screenGui.Enabled = false
			skipButton.Text = "Skip"
			return
		end

		-- One more banner before this goes away for good: the garage-terminal
		-- nudge (see TutorialConfig.GarageReminder for why). Same token, so a
		-- replay started during either banner still tears both down cleanly.
		renderBanner("TIP", TutorialConfig.GarageReminder.Title, TutorialConfig.GarageReminder.Body)
		task.delay(TutorialConfig.GarageReminder.Seconds, function()
			if finishToken == token then
				screenGui.Enabled = false
				skipButton.Text = "Skip"
			end
		end)
	end)
end

-- One poll: advance past every step that is already satisfied, then draw
-- whatever the current one wants.
--
-- The advance is a loop, not a single check, precisely because steps are state:
-- a player who restarts the tutorial already holding a plot, a truck and a
-- contract has three steps come back done on the very first poll, and they
-- should all clear in that poll rather than one every quarter second while the
-- banner flickers through instructions they are years past.
local function poll()
	if not running then
		return
	end

	local steps = activeSteps()
	while stepIndex <= #steps and stepLogic[steps[stepIndex].Id].IsDone() do
		stepIndex += 1
	end

	if stepIndex > #steps then
		finish()
		return
	end

	local step = steps[stepIndex]
	local logic = stepLogic[step.Id]

	-- Delivered, and the clipboard is still stamping its lines on. The banner
	-- and every marker step aside so the clipboard is the only thing to read;
	-- the next poll after it slides away finishes the step and puts the banner
	-- back with the finish message.
	if logic.HoldsForReceipt and deliveredDuringRun then
		banner.Visible = false
		ensureMarker():SetTarget(nil, nil)
		ensureSpotlight():SetTarget(nil, nil)
		ensureSpaceMarker():SetTarget(nil, nil)
		return
	end

	local ready = logic.Ready()

	-- Hint only when there IS one. A step with no Hint keeps its Body whatever
	-- state the player is in, rather than going blank.
	local body = if ready or not step.Hint then step.Body else step.Hint
	renderBanner(string.format("STEP %d OF %d", stepIndex, #steps), step.Title, body)

	local target, options = logic.Target(ready)
	ensureMarker():SetTarget(target, options)

	-- A STEP WITH NOTHING TO POINT AT SAYS SO, once, out loud.
	--
	-- This is the failure this whole file is worst at showing: every lookup in
	-- here degrades to nil, nil is a legitimate answer everywhere (no free
	-- plots left, depot not built yet), and the visible result is a banner
	-- giving an instruction with no beam, no outline and no arrow anywhere -
	-- which reads as "the markers are broken" rather than "I could not find the
	-- thing". It cost a playtest once already, to a plot folder that was a
	-- Folder where this expected a Model.
	--
	-- Once per step id, so a step that genuinely cannot resolve its target does
	-- not fill the output for as long as the player stands there.
	--
	-- DriveToDepot joins ChooseCargo in the exemption once `ready`: its own
	-- Target deliberately goes nil at that point now that SpaceMarker is the
	-- only marker left on screen (see the step's own comment) - a real "found
	-- nothing" would be SpaceMarker coming back empty, not this one.
	local expectedNilTarget = ready and logic.NoTargetWhenReady == true
	if not target and not expectedNilTarget and not warnedNoTarget[step.Id] then
		warnedNoTarget[step.Id] = true
		warn(
			"TutorialGuide: step '"
				.. step.Id
				.. "' has nothing to point at - the banner is up but there will be no beam, outline or arrow. "
				.. "Check that workspace.Spawn.VehiclePlots holds Model or Folder plots with a Terminal, and that "
				.. "workspace."
				.. world.RootFolderName
				.. " has its Depot and Destinations built (see docs/CargoDesign.md section 4.2)."
		)
	end

	-- A step with no Spotlight clears it rather than leaving the last one up.
	local spotPanel, spotTarget = nil, nil
	if logic.Spotlight then
		spotPanel, spotTarget = logic.Spotlight(ready)
	end
	ensureSpotlight():SetTarget(spotPanel, spotTarget)

	-- Same idea for the second world marker: a step with no SpaceMarker clears
	-- it rather than leaving DriveToDepot's arrow floating over an empty bay
	-- once the player has moved on to picking a job.
	local spaceTarget, spaceOptions = nil, nil
	if logic.SpaceMarker then
		spaceTarget, spaceOptions = logic.SpaceMarker(ready)
	end
	ensureSpaceMarker():SetTarget(spaceTarget, spaceOptions)
end

-- `track` is a TutorialConfig.Tracks key, or nil for the first-delivery
-- tutorial.
local function start(track)
	-- Restarting from the settings menu mid-run is legitimate (a player who got
	-- lost wants it from the top), so a run in progress is torn down rather
	-- than refused. The server is not told: it already knows.
	stop(false)

	activeTrack = if track and TutorialConfig.Tracks[track] then track else nil
	deliveredDuringRun = false
	setRunning(true)
	stepIndex = 1
	skipButton.Text = "Skip"
	screenGui.Enabled = true

	poll()
end

skipButton.Activated:Connect(function()
	-- The same button says "Close" during the finish message, and closing an
	-- already-finished tutorial must not fire the remote a second time - by
	-- then `running` is false and finish() has already sent it.
	if running then
		stop(true)
	else
		finishToken += 1
		screenGui.Enabled = false
		skipButton.Text = "Skip"
	end
end)

local accumulator = 0
RunService.Heartbeat:Connect(function(delta)
	if not running then
		return
	end
	accumulator += delta
	if accumulator < TutorialConfig.PollInterval then
		return
	end
	accumulator = 0
	poll()
end)

--=============================================================================
-- Starting it
--=============================================================================

-- Replaying it is a settings-menu action rather than anything this file has to
-- build - see GameSettings' ReplayTutorial definition. The menu knows nothing
-- about tutorials and this script knows nothing about menus; the key is the
-- only thing they share.
GameSettings.OnAction("ReplayTutorial", function()
	start(nil)
end)
GameSettings.OnAction("ReplayHitchTutorial", function()
	start("HitchTruck")
end)

--=============================================================================
-- The offer
--=============================================================================

-- "Congrats on your trailer truck! Want a quick lesson?" - shown the moment a
-- vehicle with a PurchaseTutorial (VehicleCatalog) is bought, and the only way
-- a track ever starts by itself.
--
-- A popup with a yes and a no, not the track simply starting: the player has
-- the garage open and has just spent the biggest sum in the game, and a banner
-- quietly appearing under that panel is the tutorial equivalent of talking to
-- somebody who is looking the other way. It also has to be refusable without
-- cost - a player buying the truck on a second account, or one who watched a
-- friend do it, should be one click from never seeing it.
--
-- Built on demand and destroyed on answer: it is on screen for a few seconds
-- once per account, so there is nothing worth keeping around.
local function offerTrack(trackKey)
	local track = TutorialConfig.Tracks[trackKey]
	local offer = track and track.Offer
	if not offer or playerGui:FindFirstChild("TutorialOfferGui") then
		return
	end

	local offerGui = Instance.new("ScreenGui")
	offerGui.Name = "TutorialOfferGui"
	offerGui.ResetOnSpawn = false
	offerGui.IgnoreGuiInset = true
	-- Above the banner (6) and so above the garage terminal it appears over,
	-- below the settings menu (100).
	offerGui.DisplayOrder = 7
	offerGui.Parent = playerGui

	-- Swallows clicks, so a press that misses a button does not land on the
	-- garage panel underneath and spawn or buy something.
	local scrim = Instance.new("TextButton")
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.45
	scrim.AutoButtonColor = false
	scrim.Text = ""
	scrim.Parent = offerGui

	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.new(0.86, 0, 0, 250)
	card.BackgroundColor3 = PANEL
	card.BorderSizePixel = 0
	card.Parent = offerGui
	Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)

	local cardSize = Instance.new("UISizeConstraint")
	cardSize.MaxSize = Vector2.new(480, 250)
	cardSize.Parent = card

	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = ACCENT
	cardStroke.Thickness = 2
	cardStroke.Parent = card

	local function text(position, size, font, textSize, color, value)
		local line = Instance.new("TextLabel")
		line.BackgroundTransparency = 1
		line.Position = position
		line.Size = size
		line.Font = font
		line.TextSize = textSize
		line.TextColor3 = color
		line.TextWrapped = true
		line.TextXAlignment = Enum.TextXAlignment.Center
		line.TextYAlignment = Enum.TextYAlignment.Top
		line.Text = value
		line.Parent = card
		return line
	end

	text(UDim2.fromOffset(20, 18), UDim2.new(1, -40, 0, 30), Enum.Font.LuckiestGuy, 24, ACCENT, offer.Title)
	text(UDim2.fromOffset(24, 58), UDim2.new(1, -48, 0, 96), Enum.Font.GothamMedium, 15, BRIGHT_TEXT, offer.Body)
	if offer.Footnote then
		text(UDim2.new(0, 20, 1, -32), UDim2.new(1, -40, 0, 16), Enum.Font.Gotham, 12, DIM_TEXT, offer.Footnote)
	end

	local function button(anchorX, label, background, textColor, onClick)
		local choice = Instance.new("TextButton")
		choice.AnchorPoint = Vector2.new(anchorX, 1)
		choice.Position = UDim2.new(0.5, if anchorX == 1 then -6 else 6, 1, -44)
		choice.Size = UDim2.new(0.5, -30, 0, 40)
		choice.BackgroundColor3 = background
		choice.BorderSizePixel = 0
		choice.Font = Enum.Font.GothamBold
		choice.TextSize = 15
		choice.TextColor3 = textColor
		choice.Text = label
		choice.Parent = card
		Instance.new("UICorner", choice).CornerRadius = UDim.new(0, 8)
		choice.Activated:Connect(function()
			offerGui:Destroy()
			onClick()
		end)
	end

	button(1, offer.Decline or "Maybe later", CARD, DIM_TEXT, function() end)
	-- Dark text on the accent green: the one filled, coloured control on the
	-- card, so "yes" is where the eye lands first.
	button(0, offer.Accept or "Show me how", ACCENT, PANEL, function()
		start(trackKey)
	end)
end

-- PlotTerminal writes this the moment a purchase lands (see its BuyVehicle
-- call). An attribute rather than a remote or a require: the two scripts stay
-- ignorant of each other, exactly as they are over TutorialActive.
player:GetAttributeChangedSignal("VehicleJustBought"):Connect(function()
	local vehicleId = player:GetAttribute("VehicleJustBought")
	local vehicleDef = type(vehicleId) == "string" and VehicleCatalog.Get(vehicleId)
	if vehicleDef and vehicleDef.PurchaseTutorial then
		offerTrack(vehicleDef.PurchaseTutorial)
	end
end)

-- Asked at startup, off the main thread. GetPlotData is the round trip every
-- client already makes, so the tutorial costs no remote of its own (see
-- PlotManager's GetPlotData for the other half).
--
-- RETRIED, because a nil reply is the ordinary case rather than an error: the
-- server answers nil for a player whose save is still loading, and a brand new
-- player - the entire audience for this file - is loading a save on the slowest
-- path there is, a DataStore miss with retries behind it. Asking once would
-- mean the tutorial silently never appeared for exactly the people it is for,
-- on exactly the connections where it matters, and it would look like a bug
-- that only ever happens to somebody else.
--
-- Bounded rather than a forever loop: after this long something is actually
-- wrong, and the settings menu still has the button. Nothing is shown on
-- failure - showing the tutorial to a returning player because a RemoteFunction
-- timed out is the worse of the two wrong answers, the same call
-- PlayerDataStore.Load makes about an unreachable save.
local STARTUP_RETRY_INTERVAL = 1
local STARTUP_TIMEOUT = 30

task.spawn(function()
	local waited = 0
	while true do
		local ok, data = pcall(function()
			return getPlotDataFunction:InvokeServer()
		end)
		if ok and type(data) == "table" then
			-- Finished, skipped, or left partway through on an earlier visit -
			-- all three set this (see PlotManager's flushPlayerData). The
			-- settings menu's Replay button is the way back in.
			if data.TutorialDone then
				return
			end
			break
		end
		if waited >= STARTUP_TIMEOUT then
			return
		end
		waited += STARTUP_RETRY_INTERVAL
		task.wait(STARTUP_RETRY_INTERVAL)
	end

	-- A beat before it appears. Joining a Roblox game drops the player into a
	-- loading screen fading out, a character spawning and a camera settling; a
	-- banner that is already there once all that clears reads as part of the
	-- world, where one that appears during it is missed entirely.
	task.wait(2)
	start()
end)

-- Claiming a garage plot (game.Workspace.Spawn.VehiclePlots.*), owning and
-- selecting vehicles, and spawning the selected one at the plot. Authoritative
-- for all of it - the client's terminal (PlotTerminal.client.luau) only shows
-- UI and fires remotes; every check here is re-verified server-side.
--
-- A player can claim exactly one plot per SERVER. That's enforced by keeping
-- claims in the in-memory `playerData` table below rather than anywhere
-- persisted - there is nothing to carry across a leave/rejoin, which is
-- exactly the "can't switch plots without leaving" rule asked for. Every plot
-- is also force-cleared to unowned at server start, for the same reason.
--
-- Spawning a vehicle does NOT set up its welding, wheels, doors, collision or
-- damage - it only clones a template into workspace.Vehicles at the plot's
-- spawn point and sets its VehicleOwnership owner. Every one of those systems
-- already watches workspace.Vehicles.ChildAdded on its own (Raycast.server,
-- VehicleCollisionSetup.server, VehicleDoors.server, ...), so a freshly
-- spawned car is picked up and fully rigged by the existing pipeline with no
-- changes needed here - this script only ever has to know where the car goes
-- and who owns it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehicleCatalog = require(ReplicatedStorage.Modules.Vehicles.VehicleCatalog)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleUpgrades = require(ReplicatedStorage.Modules.Vehicles.VehicleUpgrades)
local UpgradePasses = require(ReplicatedStorage.Modules.Vehicles.UpgradePasses)
local VehiclePaint = require(ReplicatedStorage.Modules.Vehicles.VehiclePaint)
local VehicleInduction = require(ReplicatedStorage.Modules.Vehicles.VehicleInduction)
local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)
local PlayerDataStore = require(script.Parent.Modules.PlayerDataStore)
local ContractPool = require(script.Parent.Modules.ContractPool)
local PassOwnership = require(script.Parent.Modules.PassOwnership)
local PermitAccess = require(ReplicatedStorage.Modules.Permits.PermitAccess)

local VehicleFolder = workspace.Vehicles

-- Server-side backstop on how close a player has to actually be standing to a
-- plot's Terminal.Screen to claim it - same idea as MAX_ENTER_DISTANCE in
-- VehicleDoors.server.luau. The client's CustomPrompt already won't offer the
-- claim prompt from further than this, so this only ever bites a forged
-- request.
local MAX_CLAIM_DISTANCE = 12

-- [userId] = { OwnedVehicleIds, SelectedVehicleId, Money, UpgradeLevels,
-- CarConfigs } - exactly PlayerDataStore's persisted shape (see its header),
-- and NOTHING else. Kept separate from sessionState below on purpose: this is
-- the exact table handed to PlayerDataStore.Save, so nothing that can't
-- survive a JSON round-trip (an Instance, chief among them) can ever end up
-- in it - there is no field here a save path has to remember to strip.
local playerData = {}

-- [userId] = { ClaimedPlot = Model | nil, SpawnedVehicle = Model | nil,
-- SpawnedVehicleId = string | nil } - session-only, never saved and never even reaches PlayerDataStore.Save. Kept
-- in its own table (rather than nil'd-out fields on playerData) specifically
-- so an Instance can never accidentally ride along into a save - DataStores
-- reject any table containing one ("Cannot store Dictionary in data store"),
-- which is exactly the bug this split replaces the old defensive nil-outs
-- with.
local sessionState = {}

--============================================================================
-- Remotes
--============================================================================
-- Created FIRST, before anything that touches Workspace or iterates plots.
-- The client blocks on ReplicatedStorage:WaitForChild for each of these -
-- if plot setup below ever errored before reaching this point, every client
-- would hang forever waiting for a remote that was never going to be created,
-- with nothing printed anywhere to explain why. Creating them up front means
-- a bad plot can only ever break plot claiming, never silently freeze every
-- client's terminal script.

local claimPlotEvent = Instance.new("RemoteEvent")
claimPlotEvent.Name = "ClaimPlot"
claimPlotEvent.Parent = ReplicatedStorage

local spawnVehicleEvent = Instance.new("RemoteEvent")
spawnVehicleEvent.Name = "SpawnVehicle"
spawnVehicleEvent.Parent = ReplicatedStorage

local selectVehicleEvent = Instance.new("RemoteEvent")
selectVehicleEvent.Name = "SelectVehicle"
selectVehicleEvent.Parent = ReplicatedStorage

local getPlotDataFunction = Instance.new("RemoteFunction")
getPlotDataFunction.Name = "GetPlotData"
getPlotDataFunction.Parent = ReplicatedStorage

-- A RemoteFunction (returns whether the purchase went through) for the same
-- ordering reason as BuyUpgrade below: the garage re-fetches GetPlotData right
-- after buying, and only a blocking call guarantees the purchase has landed
-- before that read.
local buyVehicleEvent = Instance.new("RemoteFunction")
buyVehicleEvent.Name = "BuyVehicle"
buyVehicleEvent.Parent = ReplicatedStorage

-- Bodywork (see VehiclePaint.luau) and the Induction Upgrade (see
-- VehicleInduction.luau). All RemoteFunctions, all for the BuyUpgrade reason:
-- the garage redraws from GetPlotData straight after.
--   BuyPaintColor(colorId) -> bool        unlocks a colour for every car, for money
--   BuyPaintMaterial(materialId) -> bool  likewise for a material
--   SetVehiclePaint(vehicleId, value) -> bool      nil/"" = stock
--   SetVehicleMaterial(vehicleId, value) -> bool   nil/"" = stock
--   BuyInductionStage(vehicleId) -> bool  buys the NEXT stage; no stage argument
--                                         at all, so a forged call cannot skip
--                                         rungs or re-buy one already owned
--   SetInductionStage(vehicleId, level) -> bool  switches DOWN to (or back up
--                                         to) a stage already bought; buying is
--                                         the only way the ceiling ever rises
local buyPaintColorFunction = Instance.new("RemoteFunction")
buyPaintColorFunction.Name = "BuyPaintColor"
buyPaintColorFunction.Parent = ReplicatedStorage

local buyPaintMaterialFunction = Instance.new("RemoteFunction")
buyPaintMaterialFunction.Name = "BuyPaintMaterial"
buyPaintMaterialFunction.Parent = ReplicatedStorage

local setVehiclePaintFunction = Instance.new("RemoteFunction")
setVehiclePaintFunction.Name = "SetVehiclePaint"
setVehiclePaintFunction.Parent = ReplicatedStorage

local setVehicleMaterialFunction = Instance.new("RemoteFunction")
setVehicleMaterialFunction.Name = "SetVehicleMaterial"
setVehicleMaterialFunction.Parent = ReplicatedStorage

local buyInductionStageFunction = Instance.new("RemoteFunction")
buyInductionStageFunction.Name = "BuyInductionStage"
buyInductionStageFunction.Parent = ReplicatedStorage

local setInductionStageFunction = Instance.new("RemoteFunction")
setInductionStageFunction.Name = "SetInductionStage"
setInductionStageFunction.Parent = ReplicatedStorage

-- Client -> server: this player opened/closed the garage view. Only drives the
-- "In Garage" marker other players see over their head (GarageIndicators.
-- client.luau) - the garage itself is entirely local, so from everyone else's
-- side the player is otherwise just standing at the terminal.
local setGarageOpenEvent = Instance.new("RemoteEvent")
setGarageOpenEvent.Name = "SetGarageOpen"
setGarageOpenEvent.Parent = ReplicatedStorage

local IN_GARAGE_ATTRIBUTE = "InGarage"

-- A RemoteFunction, not a fire-and-forget RemoteEvent, on purpose: the client
-- immediately re-fetches GetPlotData after buying to redraw the row unlocked,
-- and there is no guaranteed ordering between a RemoteEvent fired a moment
-- earlier and a RemoteFunction invoked right after it (they're separate
-- Instances - Roblox only orders calls made through the SAME remote). With a
-- plain RemoteEvent, that follow-up GetPlotData invoke could reach the server
-- and return before OnServerEvent here had actually run, so the terminal
-- redrew the row still locked even though the purchase (and the leaderstat
-- deduction) had gone through - fixed by only closing/reopening the terminal.
-- InvokeServer blocks the client until this function returns, so by the time
-- it does, the purchase is guaranteed already applied.
local buyUpgradeEvent = Instance.new("RemoteFunction")
buyUpgradeEvent.Name = "BuyUpgrade"
buyUpgradeEvent.Parent = ReplicatedStorage

-- A RemoteFunction, not a fire-and-forget RemoteEvent, for the same reason as
-- BuyUpgrade above: the terminal's tune arrows fire this and then immediately
-- re-fetch GetPlotData to redraw the segment bar, and there is no guaranteed
-- ordering between a RemoteEvent fired a moment earlier and a RemoteFunction
-- invoked right after it. With a plain RemoteEvent, that follow-up GetPlotData
-- invoke could reach the server and return before OnServerEvent here had
-- actually run, so the bar redrew at the OLD level even though the tune had
-- gone through - which is why the arrows looked like they needed two presses
-- to move the bar once (the first press's effect only showed up on the redraw
-- after the second press).
local setCarConfigValueEvent = Instance.new("RemoteFunction")
setCarConfigValueEvent.Name = "SetCarConfigValue"
setCarConfigValueEvent.Parent = ReplicatedStorage

-- Client -> server, fire and forget: the guided first delivery is over. There
-- is nothing to validate and nothing to refuse - it sets a flag whose only
-- effect is that this player is not offered the tutorial again, and a player
-- who forged it would be opting OUT of help. That is why it is a RemoteEvent
-- with no reply rather than a RemoteFunction.
--
-- The tutorial itself lives entirely on the client (TutorialGuide.client.luau)
-- for the same reason the depot guides do: it draws one player's private
-- markers and is an authority on nothing. This flag is the only part of it the
-- server has any business knowing.
local tutorialFinishedEvent = Instance.new("RemoteEvent")
tutorialFinishedEvent.Name = "TutorialFinished"
tutorialFinishedEvent.Parent = ReplicatedStorage

-- Client -> server, fire and forget: the player's settings-menu values, sent
-- whole (debounced) by SettingsPersistence.client.luau. Like TutorialFinished
-- there is nothing to protect - they only change what that one client draws -
-- so the handler only enforces a storable shape (PlayerDataStore.SanitizeSettings).
local saveSettingsEvent = Instance.new("RemoteEvent")
saveSettingsEvent.Name = "SaveSettings"
saveSettingsEvent.Parent = ReplicatedStorage

-- Client -> server: buy a zone permit (see ProgressionConfig.Permits). A
-- RemoteFunction so the permit panel can show the result without guessing -
-- it returns (true) or (false, reason).
local buyPermitFunction = Instance.new("RemoteFunction")
buyPermitFunction.Name = "BuyPermit"
buyPermitFunction.Parent = ReplicatedStorage

--============================================================================
-- Plot discovery + the "who owns this" nameplate
--============================================================================

-- WaitForChild rather than a direct index: with the remotes already created
-- above, this can safely block for a moment if Workspace hasn't fully
-- settled yet without ever risking leaving a client's WaitForChild hanging.
local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")

-- [plotModel] = { Gui = SurfaceGui, Label = TextLabel }
local ownerLabels = {}
local plots = {} -- [plotModel] = true, only plots that passed validation

local function buildOwnerLabel(screen)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "OwnerLabel"
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	-- Not AlwaysOnTop: that draws the name over a third-person player standing
	-- in front of the terminal. Normal depth lets the character occlude it.
	gui.AlwaysOnTop = false
	gui.Enabled = false

	local label = Instance.new("TextLabel")
	label.Name = "OwnerName"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	-- Plain white, not the dashboard's slightly-off-white BRIGHT_TEXT - this
	-- sits directly on the Screen part's own (near-black) material, not on a
	-- dark panel background, so it needs to read at a glance rather than
	-- blend in like the rest of the UI system does.
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextScaled = true
	label.Text = ""
	label.Parent = gui

	gui.Parent = screen
	return gui, label
end

local function refreshOwnerLabel(plotModel)
	local entry = ownerLabels[plotModel]
	if not entry then
		return
	end
	local ownerName = PlotOwnership.GetOwnerName(plotModel)
	entry.Label.Text = ownerName or ""
	entry.Gui.Enabled = ownerName ~= nil
end

local function setupPlot(plotModel)
	if not plotModel:IsA("Model") and not plotModel:IsA("Folder") then
		return
	end
	local terminal = plotModel:FindFirstChild("Terminal")
	local screen = terminal and terminal:FindFirstChild("Screen")
	local collisionBox = plotModel:FindFirstChild("CollisionBox")
	if not screen or not collisionBox then
		warn("PlotManager: " .. plotModel:GetFullName() .. " is missing Terminal.Screen or CollisionBox - skipping")
		return
	end

	PlotOwnership.ClearOwner(plotModel) -- every plot starts unclaimed each server

	if not ownerLabels[plotModel] then
		local gui, label = buildOwnerLabel(screen)
		ownerLabels[plotModel] = { Gui = gui, Label = label }
	end
	refreshOwnerLabel(plotModel)

	plotModel:GetAttributeChangedSignal(PlotOwnership.OWNER_NAME_ATTRIBUTE):Connect(function()
		refreshOwnerLabel(plotModel)
	end)

	plots[plotModel] = true
end

-- One misconfigured plot must never be able to take the rest of the garage -
-- or the remote handlers below, which don't depend on this loop finishing -
-- down with it. Same pcall-per-item shape as trySetUpCar in
-- VehicleCollisionSetup.server.luau.
local function trySetupPlot(plotModel)
	local ok, err = pcall(setupPlot, plotModel)
	if not ok then
		warn("PlotManager: failed to set up " .. plotModel:GetFullName() .. ": " .. tostring(err))
	end
end

local plotChildren = VehiclePlotsFolder:GetChildren()
if #plotChildren == 0 then
	warn("PlotManager: " .. VehiclePlotsFolder:GetFullName() .. " has no plots in it yet")
end
for _, plotModel in plotChildren do
	trySetupPlot(plotModel)
end
VehiclePlotsFolder.ChildAdded:Connect(trySetupPlot)
VehiclePlotsFolder.ChildRemoved:Connect(function(plotModel)
	plots[plotModel] = nil
	ownerLabels[plotModel] = nil
end)

--============================================================================
-- Vehicle spawning
--============================================================================

-- Prefer an explicit VehicleSpawn part/Attachment inside the plot (recommended:
-- add one facing out of the garage bay) - falls back to the CollisionBox's own
-- centre/orientation so spawning still works with nothing more than the two
-- parts described in the brief, just less precisely parked.
local function getSpawnCFrame(plotModel)
	local marker = plotModel:FindFirstChild("VehicleSpawn")
	if marker then
		if marker:IsA("Attachment") then
			return marker.WorldCFrame
		elseif marker:IsA("BasePart") then
			return marker.CFrame
		end
	end
	warn(
		"PlotManager: "
			.. plotModel:GetFullName()
			.. " has no VehicleSpawn part/attachment - parking at the CollisionBox's centre instead. Add a VehicleSpawn part for accurate parking."
	)
	return plotModel.CollisionBox.CFrame
end

-- The leaderstats Folder/IntValue is what puts money on Roblox's built-in
-- player list AND is what every client's own money HUD reads (see
-- SettingsMenu.client.luau's corner display) - it's just a plain replicated
-- value, so neither needs a remote to keep up to date. playerData.Money
-- stays the actual source of truth (it's what gets saved); this only ever
-- mirrors it after a change. Every site that touches data.Money goes
-- through setMoney below specifically so nothing can update one without the
-- other.
local function syncLeaderstatMoney(player, data)
	local leaderstats = player:FindFirstChild("leaderstats")
	local money = leaderstats and leaderstats:FindFirstChild("Money")
	if money then
		money.Value = data.Money
	end
end

local function setMoney(player, data, newMoney)
	data.Money = newMoney
	syncLeaderstatMoney(player, data)
end

-- Deliveries, the game's one progression number and its one other leaderstat.
-- Same "mirror, never the source of truth" rule as money: data.Deliveries is
-- what gets saved, this only reflects it after a change.
--
-- There is deliberately no Level column beside it. A level would have been this
-- same count looked up in a table, so the player list would have carried the
-- same fact twice while every gate in the game is stated in deliveries anyway -
-- see ProgressionConfig's header.
local function syncLeaderstatProgress(player, data)
	local leaderstats = player:FindFirstChild("leaderstats")
	local deliveries = leaderstats and leaderstats:FindFirstChild("Deliveries")
	if deliveries then
		deliveries.Value = data.Deliveries or 0
	end
end

-- The one door into a player's money for any OTHER server script (today:
-- DeliveryManager paying out a completed delivery). A BindableFunction rather
-- than exporting `playerData`, because this script owning that table outright
-- is what makes "every site that touches data.Money goes through setMoney" a
-- statement anyone can verify by reading one file.
--
-- Parented to ServerScriptService, not ReplicatedStorage: a client cannot see
-- it at all, so unlike a RemoteEvent there is no handler here that has to
-- treat its caller as hostile.
--
-- Returns the player's new balance, or nil if they have no loaded data (they
-- left mid-delivery). Callers must handle nil rather than assume payment
-- happened.
local awardMoneyFunction = Instance.new("BindableFunction")
awardMoneyFunction.Name = "AwardMoney"
awardMoneyFunction.Parent = script.Parent

awardMoneyFunction.OnInvoke = function(player, amount)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end
	-- amount ~= amount catches NaN, which would otherwise poison a balance
	-- that then gets SAVED - the same guard VehicleDamage's validate makes.
	if type(amount) ~= "number" or amount ~= amount or amount < 0 then
		warn("PlotManager: AwardMoney called with a bad amount: " .. tostring(amount))
		return nil
	end

	local data = playerData[player.UserId]
	if not data then
		return nil
	end

	setMoney(player, data, data.Money + math.floor(amount))
	return data.Money
end

--============================================================================
-- The contract pool's door, for the two scripts that are not this one
--============================================================================
-- Same shape and same reasoning as AwardMoney above: the contract board is
-- part of a player's SAVE, so it lives in `playerData` and this script stays
-- the only thing that touches that table. DeliveryManager runs the delivery
-- loop and Monetization.server.luau handles the receipt, and neither of them
-- gets a reference to player data - they get these four answers.
--
-- BindableFunctions, so a client cannot see them at all. Every one returns nil
-- for a player with no loaded data (mid-join, or a DataStore read still in
-- flight), and every caller has to treat that as "not now" rather than as an
-- error - a request that arrives mid-load is dropped, exactly as the remote
-- handlers below already do.

-- The board as it stands, refilled for however much real time has passed.
-- `config`/`capacity` describe the truck the player is sitting in right now:
-- contracts are stored as capacity FRACTIONS and sized to the vehicle at draw
-- time (see ContractPool's header), so the caller - which is the one that knows
-- about vehicles - has to say which truck to quote against.
local getContractBoardFunction = Instance.new("BindableFunction")
getContractBoardFunction.Name = "GetContractBoard"
getContractBoardFunction.Parent = script.Parent

getContractBoardFunction.OnInvoke = function(player, config, capacity)
	local data = playerData[player.UserId]
	if not data then
		return nil
	end
	return ContractPool.Board(data, config or {}, capacity or 0)
end

-- Removes a contract from the board and hands back its seed, or nil if this
-- player never had it. THE authority on "was this job actually on your board" -
-- DeliveryManager checks nothing about ids itself, it just fails when this
-- returns nil.
local takeContractFunction = Instance.new("BindableFunction")
takeContractFunction.Name = "TakeContract"
takeContractFunction.Parent = script.Parent

takeContractFunction.OnInvoke = function(player, contractId)
	local data = playerData[player.UserId]
	if not data then
		return nil
	end
	return ContractPool.Take(data, contractId)
end

-- One completed delivery. Bumps the game's one progression number and re-syncs
-- the leaderstat that shows it.
local recordDeliveryFunction = Instance.new("BindableFunction")
recordDeliveryFunction.Name = "RecordDelivery"
recordDeliveryFunction.Parent = script.Parent

recordDeliveryFunction.OnInvoke = function(player)
	local data = playerData[player.UserId]
	if not data then
		return nil
	end
	local capBefore = ProgressionConfig.ContractCapFor(data.Deliveries or 0)
	local deliveries = ContractPool.RecordDelivery(data)
	local capAfter = ProgressionConfig.ContractCapFor(deliveries)
	syncLeaderstatProgress(player, data)

	return {
		Deliveries = deliveries,
		ContractCap = capAfter,
		-- The client turns this into the "your board now holds 4 jobs" banner on
		-- the payout summary. Worked out here because here is the only place
		-- that can see BOTH sides of the increment.
		CapIncreased = capAfter > capBefore,
		NextCapMilestone = ProgressionConfig.NextCapMilestone(deliveries),
	}
end

-- What the developer product buys. Returns true only if the board was actually
-- rebuilt: the receipt handler must NOT consume a purchase it could not honour
-- (a place file with no destinations built, say), because a consumed receipt is
-- gone and Roblox will never hand it back.
local refreshContractsFunction = Instance.new("BindableFunction")
refreshContractsFunction.Name = "RefreshContracts"
refreshContractsFunction.Parent = script.Parent

refreshContractsFunction.OnInvoke = function(player)
	local data = playerData[player.UserId]
	if not data then
		return false
	end
	if not ContractPool.Refresh(data) then
		return false
	end

	-- Written through immediately, which nothing else in this script does.
	-- Every other change here can afford to wait for the player to leave,
	-- because the worst case is a lost minute of grinding. This one was paid
	-- for in Robux: if the server dies before PlayerRemoving runs, the receipt
	-- is already consumed and Roblox will never present it again, so the
	-- player has paid for a board they will never see. One extra SetAsync per
	-- purchase is a trivial price for that not being possible.
	PlayerDataStore.Save(player, data)
	return true
end

-- The free path to the same refresh - see ContractPool.FreeRefresh. Same
-- immediate-save reasoning as the paid one above: the cooldown this starts is
-- the scarce resource, and losing that write to a server crash would hand the
-- player their free refresh back for nothing the next time they join.
local freeRefreshContractsFunction = Instance.new("BindableFunction")
freeRefreshContractsFunction.Name = "FreeRefreshContracts"
freeRefreshContractsFunction.Parent = script.Parent

freeRefreshContractsFunction.OnInvoke = function(player)
	local data = playerData[player.UserId]
	if not data then
		return false
	end
	if not ContractPool.FreeRefresh(data) then
		return false
	end
	PlayerDataStore.Save(player, data)
	return true
end

-- Third-person time is published to the client as an expiry timestamp on a
-- Player attribute (VehicleViewMode reads it), but SAVED as seconds left. The
-- two are converted at the edges: on join the saved seconds become
-- now + seconds, and on leave whatever is left on the clock is written back.
-- That is what makes the 20 minutes play time rather than wall-clock time - a
-- player who buys it and leaves with 10 minutes on the clock has 10 minutes
-- when they join any server, however long they were away.
local THIRD_PERSON_ATTRIBUTE = ProgressionConfig.Monetization.ThirdPersonAttribute

local function thirdPersonSecondsLeft(player)
	local expiresAt = player:GetAttribute(THIRD_PERSON_ATTRIBUTE)
	if type(expiresAt) ~= "number" then
		return 0
	end
	return math.max(0, math.floor(expiresAt - os.time()))
end

-- What the third-person developer product buys. Returns false only if the
-- player's data has not loaded, so the receipt handler leaves the purchase
-- unprocessed and Roblox presents it again.
local grantThirdPersonFunction = Instance.new("BindableFunction")
grantThirdPersonFunction.Name = "GrantThirdPerson"
grantThirdPersonFunction.Parent = script.Parent

grantThirdPersonFunction.OnInvoke = function(player, seconds)
	local data = playerData[player.UserId]
	if not data or type(seconds) ~= "number" then
		return false
	end
	-- Stacks on whatever is left rather than resetting - buying again while
	-- it is still running is never wasted.
	local total = thirdPersonSecondsLeft(player) + seconds
	player:SetAttribute(THIRD_PERSON_ATTRIBUTE, os.time() + total)
	data.ThirdPersonSecondsLeft = total

	-- Written through immediately, for the same reason as the contract
	-- refresh above: this was paid for in Robux and the receipt is consumed
	-- the moment this returns true.
	PlayerDataStore.Save(player, data)
	return true
end

local function despawnVehicle(session)
	if session.SpawnedVehicle and session.SpawnedVehicle.Parent then
		session.SpawnedVehicle:Destroy()
	end
	session.SpawnedVehicle = nil
	session.SpawnedVehicleId = nil
end

-- A vehicle's saved paint value, or nil for stock.
local function getVehiclePaint(data, vehicleId)
	local entry = data.Customization and data.Customization[vehicleId]
	return entry and VehiclePaint.Sanitize(entry.Paint)
end

-- ...and the material half, which is stored in the same entry.
local function getVehicleMaterial(data, vehicleId)
	local entry = data.Customization and data.Customization[vehicleId]
	return entry and VehiclePaint.SanitizeMaterial(entry.Material)
end

-- The highest stage BOUGHT for this car - the ceiling, not what is switched on.
local function getInductionStage(data, vehicleId)
	return VehicleInduction.ClampStage((data.InductionStages or {})[vehicleId])
end

-- The stage actually switched on, which is what the car wears and what the
-- effects read. Clamped against the ceiling on the way out as well as on the
-- way in, so there is no ordering in which a stale setting can outlive the
-- purchase it was clamped against.
--
-- A missing setting means "everything bought", which is both what a player who
-- has never touched the arrows expects and what every save written before the
-- setting existed reconciles to.
local function getInductionSetting(data, vehicleId)
	local owned = getInductionStage(data, vehicleId)
	local active = (data.InductionSetting or {})[vehicleId]
	if type(active) ~= "number" then
		return owned
	end
	return math.clamp(VehicleInduction.ClampStage(active), 0, owned)
end

-- The Customization entry for a car, created on demand. Both paint and
-- material write through here so neither can clobber the other by replacing
-- the table wholesale.
local function customizationEntry(data, vehicleId)
	data.Customization = data.Customization or {}
	local entry = data.Customization[vehicleId]
	if not entry then
		entry = {}
		data.Customization[vehicleId] = entry
	end
	return entry
end

-- The spawned car, if it is this vehicle - the one thing every "apply what was
-- just bought to the car already on the road" branch needs, so they all ask
-- the same question rather than each writing their own version of it.
local function liveVehicleFor(player, vehicleId)
	local session = sessionState[player.UserId]
	local spawned = session and session.SpawnedVehicle
	if spawned and spawned.Parent and session.SpawnedVehicleId == vehicleId then
		return spawned
	end
	return nil
end

-- This vehicle's Upgrades spec table (from its Configs/<Name>.luau file), or
-- nil if it has none. The one place both the spawn-time attribute writer and
-- the Buy/SetCarConfigValue remote handlers below get it from, so there's
-- only one lookup path to keep in sync with VehiclePhysics' own config
-- loading.
local function getUpgradeSpecs(vehicleDef)
	return vehicleDef and VehiclePhysics.GetUpgradeSpecs(vehicleDef.TemplateName)
end

-- Writes ConfigName plus every upgradable stat's current (per-player) value
-- onto a car's Chassis as Attributes. VehiclePhysics.GetConfig already treats
-- a Chassis Attribute as the HIGHEST-precedence source for that key (above
-- the Configs/<name>.luau file, above DEFAULTS) - see its header - so this is
-- the entire mechanism for a player's purchased/tuned stats actually taking
-- effect, with no changes needed to the physics step itself.
--
-- ConfigName is set explicitly rather than relying on the clone's Name
-- matching a Configs/ file, because the clone's Name is whatever the
-- ServerStorage template happens to be named - this way vehicle identity
-- (VehicleCatalog.Id) and physics config identity can never drift apart.
local function applyCarConfigAttributes(chassis, vehicleId, vehicleDef, data)
	chassis:SetAttribute("ConfigName", vehicleDef.TemplateName)

	local specs = getUpgradeSpecs(vehicleDef)
	local configValues = specs and data.CarConfigs[vehicleId]
	if not configValues then
		return
	end
	for statName in specs do
		local value = configValues[statName]
		if value ~= nil then
			chassis:SetAttribute(statName, value)
		end
	end
end

local function spawnVehicle(player, data, session)
	local plotModel = session.ClaimedPlot
	if not plotModel then
		return
	end

	local vehicleId = data.SelectedVehicleId
	local vehicleDef = vehicleId and VehicleCatalog.Get(vehicleId)
	if not vehicleDef or not data.OwnedVehicleIds[vehicleId] then
		warn("PlotManager: " .. player.Name .. " tried to spawn an unowned/unknown vehicle: " .. tostring(vehicleId))
		return
	end

	local templates = ServerStorage:FindFirstChild("VehicleTemplates")
	local template = templates and templates:FindFirstChild(vehicleDef.TemplateName)
	if not template then
		warn(
			"PlotManager: no ServerStorage.VehicleTemplates."
				.. vehicleDef.TemplateName
				.. " found - place a vehicle model there to make "
				.. vehicleDef.DisplayName
				.. " spawnable."
		)
		return
	end

	-- The terminal prompt can't even be reached while the local player is
	-- seated (see CustomPrompt.luau), so there's no path to "replace the car
	-- while sitting in it" from the GUI - this is just cleaning up whatever
	-- was parked here before, if anything.
	despawnVehicle(session)

	local clone = template:Clone()
	clone:PivotTo(getSpawnCFrame(plotModel))
	VehicleOwnership.SetOwner(clone, player)
	if clone.PrimaryPart then
		applyCarConfigAttributes(clone.PrimaryPart, vehicleId, vehicleDef, data)
	else
		warn("PlotManager: " .. clone:GetFullName() .. " has no PrimaryPart - can't apply ConfigName/upgrade attributes")
	end
	-- Painted before it is parented, so nobody ever sees it pop from stock to
	-- its colour. The garage preview was painted by the same function.
	VehiclePaint.Apply(clone, getVehiclePaint(data, vehicleId), getVehicleMaterial(data, vehicleId))
	-- On the MODEL, not the Chassis like the tuning stats: every client reads
	-- this for every car it can see (see InductionEffects), and the model is
	-- the thing those loops already hold. Written before parenting for the
	-- same reason as the paint - a car that arrives stock and turns into a
	-- turbo car a frame later would whistle on spawn.
	clone:SetAttribute(VehicleInduction.ATTRIBUTE, getInductionSetting(data, vehicleId))
	-- Atomic, not Default: a Default model streams its parts out one by one
	-- while the Model itself stays in workspace.Vehicles, leaving PrimaryPart
	-- nil and no ChildRemoved for the client caches to react to. Atomic
	-- streams the whole car, Model included, in and out as one unit, which
	-- is the ChildAdded/ChildRemoved contract every client vehicle script
	-- already assumes. Not Persistent: that would make every client run the
	-- per-frame wheel/light work for every car on the map.
	clone.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	clone.Parent = VehicleFolder

	session.SpawnedVehicle = clone
	session.SpawnedVehicleId = vehicleId
end

--============================================================================
-- Player lifecycle
--============================================================================

-- Yields on the DataStore call (see PlayerDataStore.Load) - fine here since
-- PlayerAdded/the startup loop below each run this in their own thread, and
-- every remote handler already guards on playerData[userId] existing, so a
-- request that arrives mid-load is just dropped rather than acting on a half
-- -built table.
local function initPlayerData(player)
	local saved = PlayerDataStore.Load(player)
	playerData[player.UserId] = saved
	sessionState[player.UserId] = { ClaimedPlot = nil, SpawnedVehicle = nil, SpawnedVehicleId = nil }

	-- Built fresh every join rather than persisted itself - it's derived
	-- entirely from saved.Money, which IS persisted (see PlayerDataStore).
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local money = Instance.new("IntValue")
	money.Name = "Money"
	money.Value = saved.Money
	money.Parent = leaderstats

	local deliveries = Instance.new("IntValue")
	deliveries.Name = "Deliveries"
	deliveries.Parent = leaderstats

	syncLeaderstatProgress(player, saved)

	-- Mirrored onto the Player so the crossing barriers (PermitGates.client)
	-- can answer on the client. The save stays the source of truth.
	for permitId in saved.Permits or {} do
		player:SetAttribute(PermitAccess.AttributeName(permitId), true)
	end

	-- Bought third-person time carries over from the last server. Starts
	-- counting down now, from the moment they are actually here.
	local thirdPersonLeft = saved.ThirdPersonSecondsLeft or 0
	if thirdPersonLeft > 0 then
		player:SetAttribute(THIRD_PERSON_ATTRIBUTE, os.time() + thirdPersonLeft)
	end
end

-- Tears a player's session down and writes their save, and is the ONLY place
-- that writes one - both PlayerRemoving and BindToClose come through here.
--
-- The first thing it does is take `data` and `session` OUT of the two tables,
-- before touching anything that yields. That ordering is the whole point, not
-- tidiness: PlayerRemoving and BindToClose both fire when a server shuts down,
-- and PlayerDataStore.Save yields for as long as the DataStore round-trip
-- takes. Clearing after the save (as this used to) leaves both entries sitting
-- there for the entire write, so the other caller finds them, decides the
-- player still needs saving, and fires a SECOND SetAsync at the same key -
-- which, being inside the per-key write cooldown, is what produces
-- "DataStore request was added to queue ... Key = Player_<id>". Claiming
-- first makes the second caller a no-op instead. It is a race, which is why
-- the warning only showed up on some playtests and not others.
--
-- Does not return until the write has actually landed, so PlayerRemoving
-- can't return - and BindToClose can't finish - with the save still in
-- flight and Roblox tearing the server down underneath it.
local function flushPlayerData(player)
	local data = playerData[player.UserId]
	local session = sessionState[player.UserId]
	if not data or not session then
		return -- already flushed by the other caller
	end
	playerData[player.UserId] = nil
	sessionState[player.UserId] = nil

	despawnVehicle(session)
	if session.ClaimedPlot then
		PlotOwnership.ClearOwner(session.ClaimedPlot)
		session.ClaimedPlot = nil
	end

	-- Leaving counts as finishing it, whether or not they got to the end.
	--
	-- The alternative - only the completion remote sets this - means a player
	-- who quits during step three is restarted at step one on their next join,
	-- and again the join after that, forever, because a player who bounces off
	-- the tutorial is exactly the player who keeps bouncing off it. The
	-- tutorial is a first impression, not a gate, and it can always be replayed
	-- deliberately from the settings menu (see GameSettings' ReplayTutorial
	-- action).
	data.TutorialDone = true

	-- Whatever is left on the third-person clock goes into the save, so the
	-- time they have not used is still theirs next join.
	data.ThirdPersonSecondsLeft = thirdPersonSecondsLeft(player)

	PlayerDataStore.Save(player, data)
	PlayerDataStore.Release(player)
end

-- The one place that answers "does this player own this car's upgrade pass".
-- Three callers ask (buy, tune, and the panel's own data fetch) and they must
-- never disagree, which is also what makes the testing override below a single
-- edit rather than three.
local function ownsUpgradePass(player, vehicleId)
	if UpgradePasses.DebugForceUnowned then
		return false
	end
	return PassOwnership.Owns(player, UpgradePasses.PassIdFor(vehicleId))
end

-- Warms this player's game-pass answers while they are still walking to a
-- plot, so the first terminal open does not stall on a web call per gated
-- stat. Fire-and-forget - PassOwnership.Owns is correct with or without it.
local function prefetchUpgradePasses(player)
	local passIds = {}
	for _, passId in UpgradePasses.PassIdByVehicleId do
		table.insert(passIds, passId)
	end
	for _, passId in VehiclePaint.CustomPaintPassIdByVehicleId do
		table.insert(passIds, passId)
	end
	PassOwnership.Prefetch(player, passIds)
end

-- Does this player own this car's custom colour picker? A car with no pass id
-- yet (absent from the table) has no picker to sell, so nobody owns it - the
-- garage shows "coming soon" rather than a button that opens nothing.
local function ownsCustomPaint(player, vehicleId)
	local passId = VehiclePaint.CustomPaintPassIdFor(vehicleId)
	if not passId then
		return false
	end
	return PassOwnership.Owns(player, passId)
end

-- A respawned character is not standing at the garage any more, whatever the
-- client last said.
local function watchGarageFlag(player)
	player.CharacterAdded:Connect(function()
		player:SetAttribute(IN_GARAGE_ATTRIBUTE, nil)
	end)
end

Players.PlayerAdded:Connect(initPlayerData)
Players.PlayerAdded:Connect(prefetchUpgradePasses)
Players.PlayerAdded:Connect(watchGarageFlag)
Players.PlayerRemoving:Connect(flushPlayerData)

-- BindToClose blocks server shutdown until this returns, which is what makes
-- saving everyone here actually reliable - PlayerRemoving alone is NOT fired
-- for every player when the whole server is shutting down at once. Anyone
-- PlayerRemoving did already reach is a no-op above, so nobody is written
-- twice.
--
-- Each player is flushed in their own thread, then waited on: the saves are
-- independent, they're to different keys, and doing them one after another
-- would mean a full DataStore round-trip PER PLAYER of shutdown time - on a
-- busy server that risks Roblox's 30-second shutdown budget expiring with
-- players still unsaved.
game:BindToClose(function()
	local pending = 0
	local done = Instance.new("BindableEvent")

	for _, player in Players:GetPlayers() do
		pending += 1
		task.spawn(function()
			-- pcall so one player's save erroring can't leave `pending`
			-- stuck above zero and hang shutdown until Roblox kills it.
			pcall(flushPlayerData, player)
			pending -= 1
			if pending == 0 then
				done:Fire()
			end
		end)
	end

	if pending > 0 then
		done.Event:Wait()
	end
	done:Destroy()
end)

-- Anyone who beat this script to the DataModel. Rare in practice (server
-- scripts run before the first player joins) but free to cover, and skipping
-- the prefetch here would leave exactly those players paying a web call on
-- their first terminal open.
for _, player in Players:GetPlayers() do
	initPlayerData(player)
	prefetchUpgradePasses(player)
	watchGarageFlag(player)
end

--============================================================================
-- Remote handlers
--============================================================================

claimPlotEvent.OnServerEvent:Connect(function(player, plotModel)
	local data = playerData[player.UserId]
	local session = sessionState[player.UserId]
	if not data or not session or session.ClaimedPlot then
		return -- already holds a plot this server - can't switch, see the header
	end
	if typeof(plotModel) ~= "Instance" or not plots[plotModel] then
		return
	end
	if PlotOwnership.IsClaimed(plotModel) then
		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end
	local distance = (rootPart.Position - plotModel.Terminal.Screen.Position).Magnitude
	if distance > MAX_CLAIM_DISTANCE then
		return
	end

	PlotOwnership.SetOwner(plotModel, player)
	session.ClaimedPlot = plotModel
end)

-- The garage passes the vehicle it is showing. SelectVehicle is a separate
-- remote and Roblox does not order calls across two remotes, so a player who
-- picks a car and hits Spawn in the same breath could otherwise get the car
-- they had selected BEFORE. Optional, so an old client firing it bare still
-- spawns the saved selection.
spawnVehicleEvent.OnServerEvent:Connect(function(player, vehicleId)
	local data = playerData[player.UserId]
	local session = sessionState[player.UserId]
	if not data or not session or not session.ClaimedPlot then
		return
	end
	if typeof(vehicleId) == "string" and data.OwnedVehicleIds[vehicleId] then
		data.SelectedVehicleId = vehicleId
	end
	spawnVehicle(player, data, session)
end)

selectVehicleEvent.OnServerEvent:Connect(function(player, vehicleId)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" then
		return
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return
	end
	data.SelectedVehicleId = vehicleId
end)

buyVehicleEvent.OnServerInvoke = function(player, vehicleId)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" then
		return false
	end
	if data.OwnedVehicleIds[vehicleId] then
		return false -- already owned, nothing to buy
	end
	local vehicleDef = VehicleCatalog.Get(vehicleId)
	if not vehicleDef then
		return false
	end
	if data.Money < vehicleDef.Price then
		return false
	end
	-- The other half of the price. The garage already shows this car locked
	-- and never offers the buy button (see PlotTerminal), so this only ever
	-- bites a forged request - the same relationship every other check in
	-- this file has with the client's own UI.
	if (data.Deliveries or 0) < VehicleCatalog.RequiredDeliveries(vehicleDef) then
		return false
	end

	setMoney(player, data, data.Money - vehicleDef.Price)
	data.OwnedVehicleIds[vehicleId] = true
	-- Bought from the garage while looking at it, so it becomes the car the
	-- Spawn button spawns.
	data.SelectedVehicleId = vehicleId

	-- A freshly bought car starts at every stat's free level-0 default -
	-- CarConfigs isn't populated yet, but PlayerDataStore.reconcile fills it
	-- in (and clamps it) the NEXT time this player's data round-trips a Load,
	-- so leaving it empty here is safe; SetCarConfigValue below also treats a
	-- missing entry as "at the default" for exactly this reason.
	return true
end

buyPaintColorFunction.OnServerInvoke = function(player, colorId)
	local data = playerData[player.UserId]
	if not data or typeof(colorId) ~= "string" then
		return false
	end
	local color = VehiclePaint.ColorsById[colorId]
	if not color then
		return false
	end
	data.PaintColors = data.PaintColors or {}
	if data.PaintColors[colorId] then
		return false -- already owned
	end
	if data.Money < color.Price then
		return false
	end
	setMoney(player, data, data.Money - color.Price)
	data.PaintColors[colorId] = true
	return true
end

setVehiclePaintFunction.OnServerInvoke = function(player, vehicleId, value)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" then
		return false
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return false
	end
	if value ~= nil and typeof(value) ~= "string" then
		return false
	end
	local paint = VehiclePaint.Sanitize(value)
	-- Anything that is not stock has to be paid for: a colour bought with
	-- money, or any colour at all with the pass. A malformed value sanitizes
	-- to stock, which is always allowed - so only a value that genuinely IS
	-- stock gets through as nil.
	if value ~= nil and value ~= "" and not paint then
		return false
	end
	if paint then
		if VehiclePaint.IsCustom(paint) then
			if not ownsCustomPaint(player, vehicleId) then
				return false
			end
		elseif not (data.PaintColors and data.PaintColors[paint]) then
			return false
		end
	end

	customizationEntry(data, vehicleId).Paint = paint

	-- Repaint the car already out on the road too, if it is this one, rather
	-- than making the player respawn to see what they just bought.
	local live = liveVehicleFor(player, vehicleId)
	if live then
		VehiclePaint.Apply(live, paint, getVehicleMaterial(data, vehicleId))
	end
	return true
end

buyPaintMaterialFunction.OnServerInvoke = function(player, materialId)
	local data = playerData[player.UserId]
	if not data or typeof(materialId) ~= "string" then
		return false
	end
	local material = VehiclePaint.MaterialsById[materialId]
	if not material then
		return false
	end
	data.PaintMaterials = data.PaintMaterials or {}
	if data.PaintMaterials[materialId] then
		return false -- already owned
	end
	if data.Money < material.Price then
		return false
	end
	setMoney(player, data, data.Money - material.Price)
	data.PaintMaterials[materialId] = true
	return true
end

setVehicleMaterialFunction.OnServerInvoke = function(player, vehicleId, value)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" then
		return false
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return false
	end
	if value ~= nil and typeof(value) ~= "string" then
		return false
	end
	local material = VehiclePaint.SanitizeMaterial(value)
	-- Same shape as the paint handler above: anything that is not stock has to
	-- have been bought, and a malformed value sanitizes to stock rather than
	-- being silently accepted as something else.
	if value ~= nil and value ~= "" and not material then
		return false
	end
	if material and not (data.PaintMaterials and data.PaintMaterials[material]) then
		return false
	end

	customizationEntry(data, vehicleId).Material = material

	local live = liveVehicleFor(player, vehicleId)
	if live then
		VehiclePaint.Apply(live, getVehiclePaint(data, vehicleId), material)
	end
	return true
end

-- Buys the NEXT stage of the Induction Upgrade for one car. The stage is never
-- passed in: the server reads what the player has, works out what comes next
-- and charges for that, so there is no argument a forged call could use to jump
-- to stage 4 or to pay for a stage it already owns.
buyInductionStageFunction.OnServerInvoke = function(player, vehicleId)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" then
		return false
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return false
	end
	local current = getInductionStage(data, vehicleId)
	local nextStage = VehicleInduction.NextStage(current)
	if not nextStage then
		return false -- already at the top of the ladder
	end
	if data.Money < nextStage.Price then
		return false
	end

	setMoney(player, data, data.Money - nextStage.Price)
	data.InductionStages = data.InductionStages or {}
	data.InductionStages[vehicleId] = nextStage.Level
	-- Buying SWITCHES IT ON, the same as buying a stat upgrade applies its new
	-- level: a child's first purchase has to visibly - here audibly - do
	-- something. The arrows are how you turn it back down, not how you finish
	-- the purchase.
	data.InductionSetting = data.InductionSetting or {}
	data.InductionSetting[vehicleId] = nextStage.Level

	-- Straight onto the car already parked outside, so a player who buys the
	-- turbo and walks out to their truck hears it on the way to the next job
	-- rather than having to respawn the car first.
	local live = liveVehicleFor(player, vehicleId)
	if live then
		live:SetAttribute(VehicleInduction.ATTRIBUTE, nextStage.Level)
	end
	return true
end

-- Switching between stages already bought. The counterpart to BuyInductionStage
-- and the exact shape of SetCarConfigValue below: the purchase raises a
-- ceiling, this picks a rung at or under it, and the clamp is what stops a
-- forged call from switching on a stage that was never paid for.
--
-- WHY IT EXISTS. Anti-lag is loud on purpose, and a player who bought it for
-- the bangs and then wants a quiet truck for a careful delivery would otherwise
-- have no way back - the ladder would be a one-way door on a thing bought for
-- how it sounds.
setInductionStageFunction.OnServerInvoke = function(player, vehicleId, level)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" or typeof(level) ~= "number" then
		return false
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return false
	end
	local owned = getInductionStage(data, vehicleId)
	local clamped = math.clamp(VehicleInduction.ClampStage(level), 0, owned)

	data.InductionSetting = data.InductionSetting or {}
	data.InductionSetting[vehicleId] = clamped

	local live = liveVehicleFor(player, vehicleId)
	if live then
		live:SetAttribute(VehicleInduction.ATTRIBUTE, clamped)
	end
	return true
end

setGarageOpenEvent.OnServerEvent:Connect(function(player, isOpen)
	if typeof(isOpen) ~= "boolean" then
		return
	end
	player:SetAttribute(IN_GARAGE_ATTRIBUTE, if isOpen then true else nil)
end)

buyPermitFunction.OnServerInvoke = function(player, permitId)
	local data = playerData[player.UserId]
	if not data or typeof(permitId) ~= "string" then
		return false, "Not ready"
	end
	data.Permits = data.Permits or {}
	local reason = PermitAccess.BlockReason(permitId, data.Permits, data.Money, data.Deliveries or 0)
	if reason then
		return false, reason
	end
	local def = ProgressionConfig.Permits[permitId]
	setMoney(player, data, data.Money - def.Price)
	data.Permits[permitId] = true
	player:SetAttribute(PermitAccess.AttributeName(permitId), true)
	return true
end

buyUpgradeEvent.OnServerInvoke = function(player, vehicleId, statName)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" or typeof(statName) ~= "string" then
		return false
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return false
	end
	local vehicleDef = VehicleCatalog.Get(vehicleId)
	local specs = getUpgradeSpecs(vehicleDef)
	local spec = specs and specs[statName]
	if not spec then
		return false
	end

	-- The Robux half of the wall. The terminal already draws these stats
	-- padlocked and never fires this for one (see PlotTerminal's locked
	-- cards), so this only ever catches a forged call - the same relationship
	-- every other check in this file has with the client's own UI.
	--
	-- Deliberately BUY-side only, and deliberately not softened by however many
	-- levels the player already has: grandfathered levels keep a pre-pass
	-- player's existing tuning working (see the SetCarConfigValue handler
	-- below) but they are not a licence to keep climbing a ladder that now
	-- costs Robux.
	if not UpgradePasses.CanBuy(statName, ownsUpgradePass(player, vehicleId)) then
		return false
	end

	local levels = data.UpgradeLevels[vehicleId]
	if not levels then
		levels = {}
		data.UpgradeLevels[vehicleId] = levels
	end
	local currentLevel = VehicleUpgrades.ClampLevel(spec, levels[statName] or 0)
	local nextLevel = currentLevel + 1
	if nextLevel > VehicleUpgrades.MaxLevel(spec) then
		return false -- already fully upgraded
	end

	local cost = VehicleUpgrades.CostForLevel(spec, nextLevel)
	if data.Money < cost then
		return false
	end

	setMoney(player, data, data.Money - cost)
	levels[statName] = nextLevel
	return true
end

setCarConfigValueEvent.OnServerInvoke = function(player, vehicleId, statName, value)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" or typeof(statName) ~= "string" or typeof(value) ~= "number" then
		return false
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return false
	end
	local vehicleDef = VehicleCatalog.Get(vehicleId)
	local specs = getUpgradeSpecs(vehicleDef)
	local spec = specs and specs[statName]
	if not spec then
		return false
	end

	-- Snapping to the nearest notch the player has actually UNLOCKED (not
	-- just the nearest notch, full stop) is what stops a forged remote call
	-- from setting a stat past what's been paid for.
	local unlockedLevel = (data.UpgradeLevels[vehicleId] or {})[statName] or 0

	-- Tuning a gated stat needs the pass OR levels already bought in it. The
	-- second half is what keeps a player who upgraded before the pass existed
	-- able to use what they paid in-game money for - see UpgradePasses.CanTune.
	if not UpgradePasses.CanTune(statName, ownsUpgradePass(player, vehicleId), unlockedLevel) then
		return false
	end

	local snapped = VehicleUpgrades.NearestUnlockedValue(spec, unlockedLevel, value)

	local configValues = data.CarConfigs[vehicleId]
	if not configValues then
		configValues = {}
		data.CarConfigs[vehicleId] = configValues
	end
	configValues[statName] = snapped

	-- Live-update the currently spawned car too, if this is the vehicle it
	-- is - otherwise the change would only take effect the NEXT time this
	-- vehicle is spawned, which reads as the slider having silently failed.
	local session = sessionState[player.UserId]
	if session and session.SpawnedVehicle and data.SelectedVehicleId == vehicleId and session.SpawnedVehicle.PrimaryPart then
		session.SpawnedVehicle.PrimaryPart:SetAttribute(statName, snapped)
	end

	return true
end

tutorialFinishedEvent.OnServerEvent:Connect(function(player)
	local data = playerData[player.UserId]
	if not data then
		return
	end
	data.TutorialDone = true
end)

-- Only kept in memory here; flushPlayerData writes it with everything else, so
-- a slider drag costs no DataStore requests at all.
saveSettingsEvent.OnServerEvent:Connect(function(player, settings)
	local data = playerData[player.UserId]
	if not data then
		return
	end
	data.Settings = PlayerDataStore.SanitizeSettings(settings)
end)

getPlotDataFunction.OnServerInvoke = function(player)
	local data = playerData[player.UserId]
	local session = sessionState[player.UserId]
	if not data or not session then
		return nil
	end

	local ownedVehicleIds = {}
	local upgradeLevels = {}
	local carConfigs = {}
	local upgradePassOwned = {}
	local customPaintOwned = {}
	local vehiclePaint = {}
	local vehicleMaterial = {}
	local inductionStages = {}
	local inductionSetting = {}
	for id in data.OwnedVehicleIds do
		table.insert(ownedVehicleIds, id)
		upgradeLevels[id] = data.UpgradeLevels[id] or {}
		carConfigs[id] = data.CarConfigs[id] or {}
		vehiclePaint[id] = getVehiclePaint(data, id)
		vehicleMaterial[id] = getVehicleMaterial(data, id)
		inductionStages[id] = getInductionStage(data, id)
		inductionSetting[id] = getInductionSetting(data, id)
	end
	local paintColors = {}
	for colorId in data.PaintColors or {} do
		table.insert(paintColors, colorId)
	end
	local paintMaterials = {}
	for materialId in data.PaintMaterials or {} do
		table.insert(paintMaterials, materialId)
	end

	-- A SECOND pass, deliberately not folded into the loop above: Owns yields
	-- on a cold cache, and yielding partway through iterating OwnedVehicleIds
	-- means a BuyVehicle that lands during the yield can insert a key into the
	-- table this is walking - which in Lua is undefined and can throw
	-- "invalid key to 'next'". Iterating the flat array this already built
	-- instead has nothing to invalidate.
	--
	-- prefetchUpgradePasses warms the cache at join precisely so this is a
	-- table lookup per owned car rather than a web call per owned car on the
	-- critical path of the panel opening.
	for _, id in ownedVehicleIds do
		upgradePassOwned[id] = ownsUpgradePass(player, id)
		customPaintOwned[id] = ownsCustomPaint(player, id)
	end

	return {
		ClaimedPlotName = session.ClaimedPlot and session.ClaimedPlot.Name or nil,
		OwnedVehicleIds = ownedVehicleIds,
		SelectedVehicleId = data.SelectedVehicleId,
		Money = data.Money,
		-- The shop's locked cards are captioned from this and nothing else -
		-- both the requirement and the player's progress toward it are the same
		-- unit, so there is nothing to convert on either side.
		Deliveries = data.Deliveries or 0,
		HasSpawnedVehicle = session.SpawnedVehicle ~= nil,
		UpgradeLevels = upgradeLevels,
		CarConfigs = carConfigs,
		-- Carried on the panel's own round trip rather than on a remote of its
		-- own. The tutorial has to ask this exactly once, at startup, and this
		-- is already the call every client makes at startup - a second
		-- RemoteFunction for one boolean would be a second thing to keep in
		-- step with the save's shape for no gain.
		TutorialDone = data.TutorialDone and true or false,
		-- Same reasoning: SettingsPersistence reads this once at startup.
		Settings = data.Settings or {},
		-- Keyed by VEHICLE id, not by pass id, because that is the question the
		-- terminal actually asks ("is this car's tuning unlocked") and because a
		-- numeric pass id as a table key is a shape the client would have to
		-- re-derive from UpgradePasses anyway. Carried on this round trip for
		-- the same reason TutorialDone is: the panel already makes this call
		-- every time it opens.
		UpgradePassOwned = upgradePassOwned,
		-- [vehicleId] = saved paint value (nil = stock), the colour ids this
		-- player has bought, and whether the custom picker is theirs. See
		-- VehiclePaint.luau for the shapes.
		VehiclePaint = vehiclePaint,
		VehicleMaterial = vehicleMaterial,
		PaintColors = paintColors,
		PaintMaterials = paintMaterials,
		-- [vehicleId] = the Induction Upgrade stage BOUGHT for that car, and the
		-- one switched on, 0 for stock. Both always present for every owned car
		-- (the getters clamp a missing entry) so the terminal never has to
		-- distinguish "not bought" from "not sent". Same pair, same meaning, as
		-- UpgradeLevels and CarConfigs above.
		InductionStages = inductionStages,
		InductionSetting = inductionSetting,
		-- Keyed by vehicle id, like UpgradePassOwned above and for the same
		-- reason: the palette passes are per car.
		CustomPaintOwned = customPaintOwned,
	}
end

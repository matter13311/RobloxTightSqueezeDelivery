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
local Admin = require(ReplicatedStorage.Modules.Admin)
local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)
local PlayerDataStore = require(script.Parent.Modules.PlayerDataStore)
local ContractPool = require(script.Parent.Modules.ContractPool)

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

-- [userId] = { ClaimedPlot = Model | nil, SpawnedVehicle = Model | nil } -
-- session-only, never saved and never even reaches PlayerDataStore.Save. Kept
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

local buyVehicleEvent = Instance.new("RemoteEvent")
buyVehicleEvent.Name = "BuyVehicle"
buyVehicleEvent.Parent = ReplicatedStorage

local buyUpgradeEvent = Instance.new("RemoteEvent")
buyUpgradeEvent.Name = "BuyUpgrade"
buyUpgradeEvent.Parent = ReplicatedStorage

local setCarConfigValueEvent = Instance.new("RemoteEvent")
setCarConfigValueEvent.Name = "SetCarConfigValue"
setCarConfigValueEvent.Parent = ReplicatedStorage

local adminGrantMoneyEvent = Instance.new("RemoteEvent")
adminGrantMoneyEvent.Name = "AdminGrantMoney"
adminGrantMoneyEvent.Parent = ReplicatedStorage

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
	gui.AlwaysOnTop = true
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

local function despawnVehicle(session)
	if session.SpawnedVehicle and session.SpawnedVehicle.Parent then
		session.SpawnedVehicle:Destroy()
	end
	session.SpawnedVehicle = nil
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
	clone.Parent = VehicleFolder

	session.SpawnedVehicle = clone
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
	sessionState[player.UserId] = { ClaimedPlot = nil, SpawnedVehicle = nil }

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

	PlayerDataStore.Save(player, data)
	PlayerDataStore.Release(player)
end

Players.PlayerAdded:Connect(initPlayerData)
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

for _, player in Players:GetPlayers() do
	initPlayerData(player)
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

spawnVehicleEvent.OnServerEvent:Connect(function(player)
	local data = playerData[player.UserId]
	local session = sessionState[player.UserId]
	if not data or not session or not session.ClaimedPlot then
		return
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

buyVehicleEvent.OnServerEvent:Connect(function(player, vehicleId)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" then
		return
	end
	if data.OwnedVehicleIds[vehicleId] then
		return -- already owned, nothing to buy
	end
	local vehicleDef = VehicleCatalog.Get(vehicleId)
	if not vehicleDef then
		return
	end
	if data.Money < vehicleDef.Price then
		return
	end
	-- The other half of the price. The shop already greys this card out and
	-- refuses to fire the remote (see PlotTerminal's makeShopCard), so this only
	-- ever bites a forged request - the same relationship every other check in
	-- this file has with the client's own UI.
	if (data.Deliveries or 0) < VehicleCatalog.RequiredDeliveries(vehicleDef) then
		return
	end

	setMoney(player, data, data.Money - vehicleDef.Price)
	data.OwnedVehicleIds[vehicleId] = true

	-- A freshly bought car starts at every stat's free level-0 default -
	-- CarConfigs isn't populated yet, but PlayerDataStore.reconcile fills it
	-- in (and clamps it) the NEXT time this player's data round-trips a Load,
	-- so leaving it empty here is safe; SetCarConfigValue below also treats a
	-- missing entry as "at the default" for exactly this reason.
end)

buyUpgradeEvent.OnServerEvent:Connect(function(player, vehicleId, statName)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" or typeof(statName) ~= "string" then
		return
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return
	end
	local vehicleDef = VehicleCatalog.Get(vehicleId)
	local specs = getUpgradeSpecs(vehicleDef)
	local spec = specs and specs[statName]
	if not spec then
		return
	end

	local levels = data.UpgradeLevels[vehicleId]
	if not levels then
		levels = {}
		data.UpgradeLevels[vehicleId] = levels
	end
	local currentLevel = VehicleUpgrades.ClampLevel(spec, levels[statName] or 0)
	local nextLevel = currentLevel + 1
	if nextLevel > VehicleUpgrades.MaxLevel(spec) then
		return -- already fully upgraded
	end

	local cost = VehicleUpgrades.CostForLevel(spec, nextLevel)
	if data.Money < cost then
		return
	end

	setMoney(player, data, data.Money - cost)
	levels[statName] = nextLevel
end)

setCarConfigValueEvent.OnServerEvent:Connect(function(player, vehicleId, statName, value)
	local data = playerData[player.UserId]
	if not data or typeof(vehicleId) ~= "string" or typeof(statName) ~= "string" or typeof(value) ~= "number" then
		return
	end
	if not data.OwnedVehicleIds[vehicleId] then
		return
	end
	local vehicleDef = VehicleCatalog.Get(vehicleId)
	local specs = getUpgradeSpecs(vehicleDef)
	local spec = specs and specs[statName]
	if not spec then
		return
	end

	-- Snapping to the nearest notch the player has actually UNLOCKED (not
	-- just the nearest notch, full stop) is what stops a forged remote call
	-- from setting a stat past what's been paid for.
	local unlockedLevel = (data.UpgradeLevels[vehicleId] or {})[statName] or 0
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
end)

adminGrantMoneyEvent.OnServerEvent:Connect(function(player)
	if not Admin.IsAdmin(player.UserId) then
		warn("PlotManager: rejected AdminGrantMoney from non-admin " .. player.Name)
		return
	end
	local data = playerData[player.UserId]
	if not data then
		return
	end
	setMoney(player, data, data.Money + Admin.GrantAmount)
end)

tutorialFinishedEvent.OnServerEvent:Connect(function(player)
	local data = playerData[player.UserId]
	if not data then
		return
	end
	data.TutorialDone = true
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
	for id in data.OwnedVehicleIds do
		table.insert(ownedVehicleIds, id)
		upgradeLevels[id] = data.UpgradeLevels[id] or {}
		carConfigs[id] = data.CarConfigs[id] or {}
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
	}
end

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
local PlayerDataStore = require(script.Parent.Modules.PlayerDataStore)

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
end

-- Saves synchronously (PlayerDataStore.Save also yields) so PlayerRemoving
-- doesn't return - and Roblox doesn't tear the rest of the way down - before
-- the write actually lands.
local function cleanupPlayerData(player)
	local data = playerData[player.UserId]
	local session = sessionState[player.UserId]
	if not data or not session then
		return
	end

	despawnVehicle(session)
	if session.ClaimedPlot then
		PlotOwnership.ClearOwner(session.ClaimedPlot)
		session.ClaimedPlot = nil
	end

	PlayerDataStore.Save(player, data)
	playerData[player.UserId] = nil
	sessionState[player.UserId] = nil
end

Players.PlayerAdded:Connect(initPlayerData)
Players.PlayerRemoving:Connect(cleanupPlayerData)

-- BindToClose blocks server shutdown until this returns, which is what makes
-- saving everyone here actually reliable - PlayerRemoving alone is NOT fired
-- for every player when the whole server is shutting down at once. Mirrors
-- cleanupPlayerData's despawn/unclaim, then saves `data` - which, thanks to
-- the playerData/sessionState split above, can never hold an Instance
-- (ClaimedPlot/SpawnedVehicle) in the first place, so there's nothing here to
-- remember to strip out before the save.
game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		local data = playerData[player.UserId]
		local session = sessionState[player.UserId]
		if data and session then
			despawnVehicle(session)
			if session.ClaimedPlot then
				PlotOwnership.ClearOwner(session.ClaimedPlot)
				session.ClaimedPlot = nil
			end
			PlayerDataStore.Save(player, data)
		end
	end
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
		HasSpawnedVehicle = session.SpawnedVehicle ~= nil,
		UpgradeLevels = upgradeLevels,
		CarConfigs = carConfigs,
	}
end

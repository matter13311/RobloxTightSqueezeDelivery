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

local VehicleFolder = workspace.Vehicles

-- Server-side backstop on how close a player has to actually be standing to a
-- plot's Terminal.Screen to claim it - same idea as MAX_ENTER_DISTANCE in
-- VehicleDoors.server.luau. The client's CustomPrompt already won't offer the
-- claim prompt from further than this, so this only ever bites a forged
-- request.
local MAX_CLAIM_DISTANCE = 12

-- [userId] = {
--   ClaimedPlot = Model | nil,
--   OwnedVehicleIds = { [vehicleId] = true },
--   SelectedVehicleId = string,
--   Money = number,
--   SpawnedVehicle = Model | nil,
-- }
local playerData = {}

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

local function despawnVehicle(data)
	if data.SpawnedVehicle and data.SpawnedVehicle.Parent then
		data.SpawnedVehicle:Destroy()
	end
	data.SpawnedVehicle = nil
end

local function spawnVehicle(player, data)
	local plotModel = data.ClaimedPlot
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
	despawnVehicle(data)

	local clone = template:Clone()
	clone:PivotTo(getSpawnCFrame(plotModel))
	VehicleOwnership.SetOwner(clone, player)
	clone.Parent = VehicleFolder

	data.SpawnedVehicle = clone
end

--============================================================================
-- Player lifecycle
--============================================================================

local function initPlayerData(player)
	playerData[player.UserId] = {
		ClaimedPlot = nil,
		OwnedVehicleIds = VehicleCatalog.DefaultOwnedIds(),
		SelectedVehicleId = "StarterCar",
		Money = 0,
		SpawnedVehicle = nil,
	}
end

local function cleanupPlayerData(player)
	local data = playerData[player.UserId]
	if not data then
		return
	end

	despawnVehicle(data)
	if data.ClaimedPlot then
		PlotOwnership.ClearOwner(data.ClaimedPlot)
	end

	playerData[player.UserId] = nil
end

Players.PlayerAdded:Connect(initPlayerData)
Players.PlayerRemoving:Connect(cleanupPlayerData)
for _, player in Players:GetPlayers() do
	initPlayerData(player)
end

--============================================================================
-- Remote handlers
--============================================================================

claimPlotEvent.OnServerEvent:Connect(function(player, plotModel)
	local data = playerData[player.UserId]
	if not data or data.ClaimedPlot then
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
	data.ClaimedPlot = plotModel
end)

spawnVehicleEvent.OnServerEvent:Connect(function(player)
	local data = playerData[player.UserId]
	if not data or not data.ClaimedPlot then
		return
	end
	spawnVehicle(player, data)
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

getPlotDataFunction.OnServerInvoke = function(player)
	local data = playerData[player.UserId]
	if not data then
		return nil
	end

	local ownedVehicleIds = {}
	for id in data.OwnedVehicleIds do
		table.insert(ownedVehicleIds, id)
	end

	return {
		ClaimedPlotName = data.ClaimedPlot and data.ClaimedPlot.Name or nil,
		OwnedVehicleIds = ownedVehicleIds,
		SelectedVehicleId = data.SelectedVehicleId,
		Money = data.Money,
		HasSpawnedVehicle = data.SpawnedVehicle ~= nil,
	}
end

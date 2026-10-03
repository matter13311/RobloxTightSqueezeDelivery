-- The "TOP DRIVERS" board beside the dispatch office: the ten highest lifetime
-- delivery counts, each with the driver's portrait.
--
-- The board itself is a Part placed by hand in Studio (place-only, like the
-- rest of the hand-edited Terminal) and found by its CollectionService tag, so
-- it can be moved or duplicated without touching this script. Everything ON
-- it is built here.
--
-- Two sources are merged into one list:
--   * An OrderedDataStore of every player's delivery count, for the all-time
--     standings - most of the top ten will not be in this server.
--   * The leaderstats of whoever IS in this server, read live. That is what
--     makes the board move the moment you finish a delivery rather than at the
--     next store refresh, and what fills it in Studio, where the store may not
--     be reachable at all. Everyone here is listed, even on zero, until ten
--     better scores push them off.
--
-- leaderstats.Deliveries is only a mirror of the saved data (see
-- PlotManager), which is exactly what a display wants: this script never has
-- to know how player data is loaded or saved.

local CollectionService = game:GetService("CollectionService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local BOARD_TAG = "DeliveryLeaderboard"
local STORE_NAME = "DeliveryLeaderboard_v1"
local ROWS = 10
-- One GetSortedAsync a minute, plus a SetAsync for each player whose count
-- changed since the last one - far inside the datastore budget.
local REFRESH_SECONDS = 60

local PANEL = Color3.fromRGB(18, 20, 25)
local ROW_FILL = Color3.fromRGB(28, 31, 38)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local ACCENT = Color3.fromRGB(86, 200, 128)
local RANK_COLORS = {
	Color3.fromRGB(255, 205, 80),
	Color3.fromRGB(200, 208, 220),
	Color3.fromRGB(214, 140, 84),
}

-- Studio play-tests must not write test scores onto the live board.
local canWrite = not RunService:IsStudio()

local store = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[DeliveryLeaderboard] no datastore, showing this server only:", result)
	end
end

--=============================================================================
-- Board UI
--=============================================================================

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = instance
	return c
end

local function label(parent, props)
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = BRIGHT_TEXT
	for key, value in props do
		text[key] = value
	end
	text.Parent = parent
	return text
end

-- Every board in the place, each as its list of row widgets. More than one is
-- allowed; they all show the same thing.
local boards = {}

local function buildBoard(part)
	if boards[part] or not part:IsA("BasePart") then
		return
	end

	local old = part:FindFirstChild("LeaderboardGui")
	if old then
		old:Destroy()
	end

	local faceName = part:GetAttribute("Face")
	local gui = Instance.new("SurfaceGui")
	gui.Name = "LeaderboardGui"
	gui.Face = if type(faceName) == "string" and Enum.NormalId[faceName] then Enum.NormalId[faceName] else Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	-- Unlit, so it reads the same at night as at noon - it is a lit sign.
	gui.LightInfluence = 0
	gui.Parent = part

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = PANEL
	root.BorderSizePixel = 0
	root.Parent = gui

	label(root, {
		Position = UDim2.new(0, 0, 0, 14),
		Size = UDim2.new(1, 0, 0, 64),
		TextSize = 60,
		Text = "TOP DRIVERS",
	})
	label(root, {
		Position = UDim2.new(0, 0, 0, 78),
		Size = UDim2.new(1, 0, 0, 30),
		Font = Enum.Font.GothamMedium,
		TextSize = 26,
		TextColor3 = DIM_TEXT,
		Text = "Most deliveries, all time",
	})

	local list = Instance.new("Frame")
	list.Position = UDim2.new(0, 24, 0, 124)
	list.Size = UDim2.new(1, -48, 1, -142)
	list.BackgroundTransparency = 1
	list.Parent = root

	local rows = {}
	for index = 1, ROWS do
		local row = Instance.new("Frame")
		row.Position = UDim2.fromScale(0, (index - 1) / ROWS)
		row.Size = UDim2.new(1, 0, 1 / ROWS, -6)
		row.BackgroundColor3 = ROW_FILL
		row.BorderSizePixel = 0
		row.Visible = false
		row.Parent = list
		corner(row, 8)

		label(row, {
			Size = UDim2.new(0, 96, 1, 0),
			TextSize = 40,
			TextColor3 = RANK_COLORS[index] or DIM_TEXT,
			Text = "#" .. index,
		})

		local portrait = Instance.new("ImageLabel")
		portrait.AnchorPoint = Vector2.new(0, 0.5)
		portrait.Position = UDim2.new(0, 100, 0.5, 0)
		portrait.Size = UDim2.new(1, -8, 1, -8)
		portrait.SizeConstraint = Enum.SizeConstraint.RelativeYY
		portrait.BackgroundColor3 = PANEL_EDGE
		portrait.BorderSizePixel = 0
		portrait.Parent = row
		corner(portrait, 100)

		local name = label(row, {
			Position = UDim2.new(0, 172, 0, 0),
			Size = UDim2.new(1, -370, 1, 0),
			TextSize = 38,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})

		local count = label(row, {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -18, 0, 0),
			Size = UDim2.new(0, 170, 1, 0),
			TextSize = 40,
			TextColor3 = ACCENT,
			TextXAlignment = Enum.TextXAlignment.Right,
		})

		rows[index] = { Frame = row, Portrait = portrait, Name = name, Count = count }
	end

	boards[part] = rows
end

--=============================================================================
-- Standings
--=============================================================================

-- { { UserId, Deliveries } } - the store's top page as of the last refresh.
local globalEntries = {}
-- Display names for drivers who are not in this server. Online players are
-- read straight off their Player instead, so this never goes stale for them.
local nameCache = {}
local nameRequested = {}

local render

local function liveDeliveries(player)
	local leaderstats = player:FindFirstChild("leaderstats")
	local deliveries = leaderstats and leaderstats:FindFirstChild("Deliveries")
	return if deliveries then deliveries.Value else 0
end

local function nameFor(userId)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.DisplayName
	end
	if nameCache[userId] then
		return nameCache[userId]
	end
	if not nameRequested[userId] then
		nameRequested[userId] = true
		task.spawn(function()
			local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
			nameCache[userId] = if ok then name else "Driver"
			render()
		end)
	end
	return "..."
end

function render()
	local byUser = {}
	for _, entry in globalEntries do
		byUser[entry.UserId] = entry.Deliveries
	end
	for _, player in Players:GetPlayers() do
		byUser[player.UserId] = math.max(byUser[player.UserId] or 0, liveDeliveries(player))
	end

	local standings = {}
	for userId, deliveries in byUser do
		table.insert(standings, { UserId = userId, Deliveries = deliveries })
	end
	table.sort(standings, function(a, b)
		if a.Deliveries ~= b.Deliveries then
			return a.Deliveries > b.Deliveries
		end
		return a.UserId < b.UserId
	end)

	for part, rows in boards do
		if not part.Parent then
			boards[part] = nil
			continue
		end
		for index, row in rows do
			local entry = standings[index]
			row.Frame.Visible = entry ~= nil
			if entry then
				row.Name.Text = nameFor(entry.UserId)
				row.Count.Text = tostring(entry.Deliveries)
				-- rbxthumb needs no yielding call; a Studio test player's
				-- negative id has no avatar, so it keeps the blank disc.
				row.Portrait.Image = if entry.UserId > 0
					then string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", entry.UserId)
					else ""
			end
		end
	end
end

--=============================================================================
-- Store sync
--=============================================================================

-- What each player's stored count was last set to by this server, so an
-- unchanged count costs no write.
local lastWritten = {}

local function writePlayer(player)
	if not (store and canWrite) or player.UserId <= 0 then
		return
	end
	local deliveries = liveDeliveries(player)
	-- Zero is never written: it is also what leaderstats reads before the
	-- player's data has loaded, and writing that would wipe a real score.
	if deliveries <= 0 or lastWritten[player] == deliveries then
		return
	end
	local ok, err = pcall(store.SetAsync, store, tostring(player.UserId), deliveries)
	if ok then
		lastWritten[player] = deliveries
	else
		warn("[DeliveryLeaderboard] save failed:", err)
	end
end

local function refresh()
	for _, player in Players:GetPlayers() do
		writePlayer(player)
	end
	if not store then
		return
	end
	local ok, result = pcall(function()
		return store:GetSortedAsync(false, ROWS):GetCurrentPage()
	end)
	if not ok then
		warn("[DeliveryLeaderboard] refresh failed:", result)
		return
	end
	local entries = {}
	for _, item in result do
		local userId = tonumber(item.key)
		if userId then
			table.insert(entries, { UserId = userId, Deliveries = item.value })
		end
	end
	globalEntries = entries
end

--=============================================================================
-- Wiring
--=============================================================================

local function watchPlayer(player)
	task.spawn(function()
		local leaderstats = player:WaitForChild("leaderstats", 30)
		local deliveries = leaderstats and leaderstats:WaitForChild("Deliveries", 30)
		if deliveries then
			deliveries.Changed:Connect(render)
		end
		render()
	end)
end

for _, part in CollectionService:GetTagged(BOARD_TAG) do
	buildBoard(part)
end
CollectionService:GetInstanceAddedSignal(BOARD_TAG):Connect(function(part)
	buildBoard(part)
	render()
end)

Players.PlayerAdded:Connect(watchPlayer)
for _, player in Players:GetPlayers() do
	watchPlayer(player)
end

Players.PlayerRemoving:Connect(function(player)
	writePlayer(player)
	lastWritten[player] = nil
	-- Deferred: the player is still in GetPlayers() while this event runs.
	task.defer(render)
end)

game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		task.spawn(writePlayer, player)
	end
end)

while true do
	refresh()
	render()
	task.wait(REFRESH_SECONDS)
end

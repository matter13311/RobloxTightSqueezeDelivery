-- Client half of the zone permits: the crossing barriers, their boom arms,
-- and the "buy a permit" panel that appears when a player pulls up to one.
--
-- Same per-client wall pattern as ExpressGates.client.luau: every gate in
-- workspace.Map.Permits.PermitGates is an invisible description on the server
-- (Permit + Outward attributes). This client builds its own solid copy and
-- arms it only while this player lacks that permit AND is on the gate's
-- outside, so the wall never touches anyone else and can never trap a player
-- who is already through.
--
-- Everyone sees the booms, and they stay DOWN for players without the permit
-- while other drivers roll straight through. That is the point: the far zones
-- are meant to be seen being used.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)
local PermitAccess = require(ReplicatedStorage.Modules.Permits.PermitAccess)
local ResponsiveScale = require(ReplicatedStorage.Modules.UI.ResponsiveScale)

local player = Players.LocalPlayer
local VehicleFolder = workspace:WaitForChild("Vehicles")
local buyPermit = ReplicatedStorage:WaitForChild("BuyPermit")

local ARM_CLEARANCE = 2.5
local INSIDE_MARGIN = 1
local BOOM_UP = math.rad(80)

local wallFolder = Instance.new("Folder")
wallFolder.Name = "LocalPermitGates"
wallFolder.Parent = workspace

--=============================================================================
-- Bodies (character + the car it sits in)
--=============================================================================

local function localBodies()
	local models = {}
	local point = nil
	local character = player.Character
	if not character then
		return models, point
	end
	table.insert(models, character)
	local root = character:FindFirstChild("HumanoidRootPart")
	point = root and root.Position
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	local carModel = seat and seat:FindFirstAncestorWhichIsA("Model")
	if carModel and carModel.Parent == VehicleFolder then
		table.insert(models, carModel)
		if carModel.PrimaryPart then
			point = carModel.PrimaryPart.Position
		end
	end
	return models, point
end

local function anyBodyNear(box, models)
	if #models == 0 then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = models
	params.RespectCanCollide = false
	local grown = box.Size + Vector3.new(ARM_CLEARANCE, 0, ARM_CLEARANCE) * 2
	return #workspace:GetPartBoundsInBox(box.CFrame, grown, params) > 0
end

--=============================================================================
-- Gates, booms, pay zones
--=============================================================================

local gates = {} -- [part] = { Box, Wall, Outward, Permit, Solid }
local booms = {} -- { Pivot, Arm, Stripe, Angle, Length, Permit }
local payZones = {} -- { Part, Permit }
local tracked = {}

local function track(part)
	if tracked[part] or not part:IsA("BasePart") then
		return
	end
	local permit = part:GetAttribute("Permit")
	if type(permit) ~= "string" or not ProgressionConfig.Permits[permit] then
		return
	end
	tracked[part] = true
	if part.Name == PermitAccess.PAY_ZONE_NAME then
		table.insert(payZones, { Part = part, Permit = permit })
		return
	end
	if part.Name == PermitAccess.BOOM_NAME then
		local length = part:GetAttribute("BoomLength")
		length = if type(length) == "number" and length > 0 then length else 12
		local arm = Instance.new("Part")
		arm.Name = "PermitBoomArm"
		arm.Anchored = true
		arm.CanCollide = false
		arm.CanQuery = false
		arm.CanTouch = false
		arm.CastShadow = false
		arm.Material = Enum.Material.SmoothPlastic
		arm.Color = Color3.fromRGB(200, 35, 35)
		arm.Size = Vector3.new(length, 0.6, 0.6)
		arm.Parent = wallFolder
		local stripe = arm:Clone()
		stripe.Name = "PermitBoomStripe"
		stripe.Color = Color3.fromRGB(245, 245, 245)
		stripe.Size = Vector3.new(math.min(4, length / 3), 0.62, 0.62)
		stripe.Parent = wallFolder
		table.insert(booms, { Pivot = part, Arm = arm, Stripe = stripe, Angle = 0, Length = length, Permit = permit })
		return
	end
	local outward = part:GetAttribute("Outward")
	if typeof(outward) ~= "Vector3" then
		return
	end
	local wall = Instance.new("Part")
	wall.Name = part.Name
	wall.Anchored = true
	wall.CanCollide = false
	wall.CanQuery = false
	wall.CanTouch = true
	wall.CastShadow = false
	wall.Transparency = 1
	wall.Size = part.Size
	wall.CFrame = part.CFrame
	wall.Parent = wallFolder
	gates[part] = { Box = part, Wall = wall, Outward = outward.Unit, Permit = permit, Solid = false }
end

task.spawn(function()
	local model = PermitAccess.FindGates()
	while not model do
		task.wait(1)
		model = PermitAccess.FindGates()
	end
	for _, child in model:GetChildren() do
		track(child)
	end
	model.ChildAdded:Connect(track)
end)

local function updateGate(entry, has, models, point)
	if has or not point then
		entry.Solid = false
		entry.Wall.CanCollide = false
		return
	end
	local side = (point - entry.Box.Position):Dot(entry.Outward)
	if entry.Solid then
		if side < -INSIDE_MARGIN then
			entry.Solid = false
			entry.Wall.CanCollide = false
		end
	elseif side > 0 and not anyBodyNear(entry.Box, models) then
		entry.Solid = true
		entry.Wall.CanCollide = true
	end
end

--=============================================================================
-- Panel
--=============================================================================

local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local ACCENT = Color3.fromRGB(86, 200, 128)
local LOCKED = Color3.fromRGB(70, 74, 84)
local WARN = Color3.fromRGB(240, 120, 90)

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = instance
end

local gui = Instance.new("ScreenGui")
gui.Name = "PermitGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "PermitPanel"
panel.Size = UDim2.fromOffset(380, 230)
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.new(0.5, 0, 1, -140)
panel.BackgroundColor3 = PANEL
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
corner(panel, 10)
local stroke = Instance.new("UIStroke")
stroke.Color = PANEL_EDGE
stroke.Parent = panel
ResponsiveScale.Fit(panel)

local function text(name, pos, size, font, textSize, color)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = pos
	l.Size = size
	l.Font = font
	l.TextSize = textSize
	l.TextColor3 = color
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Parent = panel
	return l
end

local title = text("Title", UDim2.fromOffset(20, 14), UDim2.new(1, -70, 0, 26), Enum.Font.GothamBlack, 20, BRIGHT_TEXT)
local body = text("Body", UDim2.fromOffset(20, 46), UDim2.new(1, -40, 0, 60), Enum.Font.Gotham, 14, DIM_TEXT)
local reqs = text("Requirements", UDim2.fromOffset(20, 110), UDim2.new(1, -40, 0, 44), Enum.Font.GothamBold, 14, BRIGHT_TEXT)

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(28, 28)
closeButton.Position = UDim2.new(1, -44, 0, 12)
closeButton.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 16
closeButton.TextColor3 = DIM_TEXT
closeButton.Text = "X"
closeButton.Parent = panel
corner(closeButton, 6)

local buyButton = Instance.new("TextButton")
buyButton.AnchorPoint = Vector2.new(0.5, 1)
buyButton.Size = UDim2.new(1, -40, 0, 42)
buyButton.Position = UDim2.new(0.5, 0, 1, -16)
buyButton.BorderSizePixel = 0
buyButton.Font = Enum.Font.GothamBold
buyButton.TextSize = 16
buyButton.TextColor3 = PANEL
buyButton.Parent = panel
corner(buyButton, 8)

local shownPermit = nil
local dismissedPermit = nil
local busy = false
local flash = nil -- { Text, Until }

local function leaderstat(name)
	local stats = player:FindFirstChild("leaderstats")
	local v = stats and stats:FindFirstChild(name)
	return v and v.Value or 0
end

local function money(n)
	local s = tostring(math.floor(n))
	return "$" .. s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function refreshPanel(permitId)
	local def = ProgressionConfig.Permits[permitId]
	local owned = PermitAccess.Owned(player)
	local cash, deliveries = leaderstat("Money"), leaderstat("Deliveries")
	local reason = PermitAccess.BlockReason(permitId, owned, cash, deliveries)
	title.Text = string.upper(def.DisplayName)
	body.Text = string.format(
		"Only permit holders may cross into the %s. Jobs there pay %sx what Old Town pays, and the permit is yours for good.",
		def.ZoneName,
		tostring(DeliveryConfig.Payout.ZoneMultipliers[def.Zone] or 1)
	)
	local lines = {
		string.format("Price: %s  (you have %s)", money(def.Price), money(cash)),
		string.format("Deliveries: %d / %d", math.min(deliveries, def.RequiredDeliveries), def.RequiredDeliveries),
	}
	if def.Requires then
		table.insert(lines, "Requires: " .. ProgressionConfig.Permits[def.Requires].DisplayName)
	end
	reqs.Text = table.concat(lines, "\n")
	if flash and os.clock() < flash.Until then
		buyButton.Text = flash.Text
		buyButton.BackgroundColor3 = WARN
		buyButton.AutoButtonColor = false
	elseif reason then
		buyButton.Text = reason
		buyButton.BackgroundColor3 = LOCKED
		buyButton.TextColor3 = BRIGHT_TEXT
		buyButton.AutoButtonColor = false
	else
		buyButton.Text = "Buy for " .. money(def.Price)
		buyButton.BackgroundColor3 = ACCENT
		buyButton.TextColor3 = PANEL
		buyButton.AutoButtonColor = true
	end
end

buyButton.Activated:Connect(function()
	local permitId = shownPermit
	if not permitId or busy then
		return
	end
	local reason = PermitAccess.BlockReason(permitId, PermitAccess.Owned(player), leaderstat("Money"), leaderstat("Deliveries"))
	if reason then
		return
	end
	busy = true
	local ok, result, why = pcall(buyPermit.InvokeServer, buyPermit, permitId)
	busy = false
	if not ok or not result then
		flash = { Text = (ok and why) or "Couldn't buy - try again", Until = os.clock() + 2.5 }
	end
end)

closeButton.Activated:Connect(function()
	dismissedPermit = shownPermit
end)

local MOUSE_STEP = "PermitPanelMouse"
local mouseBound = false
local function setMouseFree(free)
	if free == mouseBound then
		return
	end
	mouseBound = free
	if free then
		RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Last.Value, function()
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end)
	else
		RunService:UnbindFromRenderStep(MOUSE_STEP)
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

local function zoneAt(point)
	if not point then
		return nil
	end
	for _, zone in payZones do
		local localPoint = zone.Part.CFrame:PointToObjectSpace(point)
		local half = zone.Part.Size / 2 + Vector3.new(2, 6, 2)
		if math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z then
			return zone.Permit
		end
	end
	return nil
end

--=============================================================================
-- Loop
--=============================================================================

RunService.Heartbeat:Connect(function(deltaTime)
	local models, point = localBodies()
	local owned = PermitAccess.Owned(player)

	for _, entry in gates do
		updateGate(entry, owned[entry.Permit] == true, models, point)
	end
	for _, boom in booms do
		local target = owned[boom.Permit] and BOOM_UP or 0
		boom.Angle += math.clamp(target - boom.Angle, -2.5 * deltaTime, 2.5 * deltaTime)
		local hinge = boom.Pivot.CFrame * CFrame.Angles(0, 0, boom.Angle)
		boom.Arm.CFrame = hinge * CFrame.new(boom.Length / 2, 0, 0)
		boom.Stripe.CFrame = hinge * CFrame.new(boom.Length / 2, 0, 0)
	end

	local permitHere = zoneAt(point)
	if permitHere ~= dismissedPermit then
		dismissedPermit = nil
	end
	local show = permitHere ~= nil and not owned[permitHere] and dismissedPermit ~= permitHere
	shownPermit = show and permitHere or nil
	panel.Visible = show
	setMouseFree(show)
	if show then
		refreshPanel(permitHere)
	end
end)

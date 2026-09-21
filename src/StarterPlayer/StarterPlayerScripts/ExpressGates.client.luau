-- Client half of the express toll road: the gates, the boom arm, and the
-- "pay the toll" panel.
--
-- THE GATES. Every gate in workspace.Map.Express.ExpressGates is an
-- invisible, non-colliding description on the server. This client builds its
-- own solid copy of each one - but only while this player has no access, and
-- only while they are on the gate's OUTSIDE (the side its Outward attribute
-- points to). That is the same per-client wall PlotBarriers.client.luau uses,
-- for the same reason: a wall that exists only for the people it should stop
-- stops them at the surface, and never touches anybody else.
--
-- The "outside only" rule is what makes a ticket that runs out mid-drive
-- harmless. A player already on the express road is on every gate's inside,
-- so every gate is soft for them and they can leave by any exit; the wall
-- only arms behind them once they are clear of it.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)
local ExpressAccess = require(ReplicatedStorage.Modules.Express.ExpressAccess)
local ResponsiveScale = require(ReplicatedStorage.Modules.UI.ResponsiveScale)

local player = Players.LocalPlayer
local VehicleFolder = workspace:WaitForChild("Vehicles")
local testTicketEvent = ReplicatedStorage:WaitForChild("RequestExpressTestTicket")

local monetization = ProgressionConfig.Monetization

-- Clearance needed before a wall may turn solid, and how far past the gate
-- plane counts as "inside". Same numbers and same anti-trap reasoning as
-- PlotBarrier.ARM_CLEARANCE / DISARM_INSET.
local ARM_CLEARANCE = 2.5
local INSIDE_MARGIN = 1

local BOOM_UP = math.rad(80)

local wallFolder = Instance.new("Folder")
wallFolder.Name = "LocalExpressGates"
wallFolder.Parent = workspace

--=============================================================================
-- Bodies this client simulates (character + the car it is sitting in)
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
-- Gates
--=============================================================================

-- [descriptionPart] = { Box, Wall, Outward, Solid }
local gates = {}
-- Every TollPayZone (the terminal entrance and one beside each street
-- opening) and every boom, each with its own BoomLength attribute.
local payZones = {}
local booms = {}

local function trackGate(part)
	if gates[part] or not part:IsA("BasePart") then
		return
	end
	if part.Name == ExpressAccess.PAY_ZONE_NAME then
		table.insert(payZones, part)
		gates[part] = false
		return
	end
	if part.Name == "TollBoomPivot" then
		gates[part] = false
		local length = part:GetAttribute("BoomLength")
		length = if type(length) == "number" and length > 0 then length else 15
		local arm = Instance.new("Part")
		arm.Name = "TollBoomArm"
		arm.Anchored = true
		arm.CanCollide = false
		arm.CanQuery = false
		arm.CanTouch = false
		arm.CastShadow = false
		arm.Material = Enum.Material.SmoothPlastic
		arm.Color = Color3.fromRGB(220, 40, 35)
		arm.Size = Vector3.new(length, 0.5, 0.5)
		arm.Parent = wallFolder
		local stripe = arm:Clone()
		stripe.Name = "TollBoomStripe"
		stripe.Color = Color3.fromRGB(245, 245, 245)
		stripe.Size = Vector3.new(4, 0.52, 0.52)
		stripe.Parent = wallFolder
		table.insert(booms, { Pivot = part, Arm = arm, Stripe = stripe, Angle = 0, Length = length })
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
	wall.CanQuery = false -- never answers a suspension ray or the camera
	wall.CanTouch = true -- so driving into it still reads as a crash
	wall.CastShadow = false
	wall.Transparency = 1
	wall.Size = part.Size
	wall.CFrame = part.CFrame
	wall.Parent = wallFolder
	gates[part] = { Box = part, Wall = wall, Outward = outward.Unit, Solid = false }
end

task.spawn(function()
	local gatesModel = ExpressAccess.FindGates()
	while not gatesModel do
		task.wait(1)
		gatesModel = ExpressAccess.FindGates()
	end
	for _, child in gatesModel:GetChildren() do
		trackGate(child)
	end
	gatesModel.ChildAdded:Connect(trackGate)
end)

local function updateGate(entry, hasAccess, models, point)
	if hasAccess or not point then
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

local function updateBoom(hasAccess, deltaTime)
	local target = hasAccess and BOOM_UP or 0
	for _, boom in booms do
		boom.Angle += math.clamp(target - boom.Angle, -2.5 * deltaTime, 2.5 * deltaTime)
		local hinge = boom.Pivot.CFrame * CFrame.Angles(0, 0, boom.Angle)
		boom.Arm.CFrame = hinge * CFrame.new(boom.Length / 2, 0, 0)
		boom.Stripe.CFrame = hinge * CFrame.new(boom.Length / 2, 0, 0)
	end
end

--=============================================================================
-- Toll panel
--=============================================================================

local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local ACCENT = Color3.fromRGB(86, 200, 128)
local GOLD = Color3.fromRGB(240, 190, 60)

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = instance
end

local gui = Instance.new("ScreenGui")
gui.Name = "ExpressTollGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "TollPanel"
panel.Size = UDim2.fromOffset(360, 210)
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.new(0.5, 0, 1, -140)
panel.BackgroundColor3 = PANEL
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
corner(panel, 10)
local panelStroke = Instance.new("UIStroke")
panelStroke.Color = PANEL_EDGE
panelStroke.Parent = panel
ResponsiveScale.Fit(panel)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(20, 14)
title.Size = UDim2.new(1, -70, 0, 26)
title.Font = Enum.Font.GothamBlack
title.TextSize = 20
title.TextColor3 = BRIGHT_TEXT
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "EXPRESS TOLL ROAD"
title.Parent = panel

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

local body = Instance.new("TextLabel")
body.BackgroundTransparency = 1
body.Position = UDim2.fromOffset(20, 44)
body.Size = UDim2.new(1, -40, 0, 60)
body.Font = Enum.Font.Gotham
body.TextSize = 14
body.TextColor3 = DIM_TEXT
body.TextWrapped = true
body.TextXAlignment = Enum.TextXAlignment.Left
body.TextYAlignment = Enum.TextYAlignment.Top
body.Parent = panel

local function makeButton(order, color)
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Size = UDim2.fromOffset(150, 40)
	button.Position = UDim2.new(order == 1 and 0.28 or 0.72, 0, 1, -18)
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamBold
	button.TextSize = 14
	button.TextWrapped = true
	button.TextColor3 = PANEL
	button.Parent = panel
	corner(button, 8)
	return button
end
local ticketButton = makeButton(1, ACCENT)
local passButton = makeButton(2, GOLD)

local minutes = math.floor(monetization.ExpressTicketDurationSeconds / 60 + 0.5)
local ticketMode = if ExpressAccess.TicketConfigured() then "product" elseif RunService:IsStudio() then "test" else nil
local passMode = if ExpressAccess.PassConfigured() then "pass" else nil

ticketButton.Visible = ticketMode ~= nil
passButton.Visible = passMode ~= nil
ticketButton.Text = if ticketMode == "test" then "Free test ticket (Studio)" else string.format("%d-min Ticket", minutes)
passButton.Text = "Express Pass (forever)"
if not ticketMode and not passMode then
	body.Text = "The express road isn't open yet. Take the streets - or find a shortcut through the alleys."
else
	body.Text = string.format(
		"Skip the traffic. The express deck flies over Market Ave through every zone - take the ramp in the middle of the road. Zone permits still apply. A ticket lasts %d minutes.",
		minutes
	)
end
if ticketButton.Visible ~= passButton.Visible then
	local onlyButton = if ticketButton.Visible then ticketButton else passButton
	onlyButton.Position = UDim2.new(0.5, 0, 1, -18)
end

ticketButton.Activated:Connect(function()
	if ticketMode == "product" then
		MarketplaceService:PromptProductPurchase(player, monetization.ExpressTicketProductId)
	elseif ticketMode == "test" then
		testTicketEvent:FireServer()
	end
end)
passButton.Activated:Connect(function()
	if passMode then
		MarketplaceService:PromptGamePassPurchase(player, monetization.ExpressPassGamePassId)
	end
end)

-- Dismissed until the player leaves the zone, so a player who just wants to
-- look at the toll isn't nagged every frame.
local dismissed = false
closeButton.Activated:Connect(function()
	dismissed = true
end)

-- Ticket countdown chip, top centre, only while a timed ticket is running.
local chip = Instance.new("TextLabel")
chip.Name = "ExpressTimer"
chip.AnchorPoint = Vector2.new(0.5, 0)
chip.Position = UDim2.new(0.5, 0, 0, 54)
chip.Size = UDim2.fromOffset(150, 26)
chip.BackgroundColor3 = Color3.fromRGB(20, 90, 50)
chip.BackgroundTransparency = 0.15
chip.BorderSizePixel = 0
chip.Font = Enum.Font.GothamBold
chip.TextSize = 14
chip.TextColor3 = BRIGHT_TEXT
chip.Visible = false
chip.Parent = gui
corner(chip, 13)

-- Same cursor fix as the other shop panels: the first-person camera
-- re-locks the mouse every frame, so a clickable panel has to win that
-- fight every frame too.
local MOUSE_STEP = "ExpressTollMouse"
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

local function inPayZone(point)
	if not point then
		return false
	end
	for _, payZone in payZones do
		local localPoint = payZone.CFrame:PointToObjectSpace(point)
		local half = payZone.Size / 2 + Vector3.new(3, 6, 3)
		if math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z then
			return true
		end
	end
	return false
end

--=============================================================================
-- Loop
--=============================================================================

RunService.Heartbeat:Connect(function(deltaTime)
	local hasAccess = ExpressAccess.HasAccess(player)
	local models, point = localBodies()

	for _, entry in gates do
		if entry then
			updateGate(entry, hasAccess, models, point)
		end
	end
	updateBoom(hasAccess, deltaTime)

	local zone = inPayZone(point)
	if not zone then
		dismissed = false
	end
	local showPanel = zone and not hasAccess and not dismissed
	panel.Visible = showPanel
	setMouseFree(showPanel and (ticketMode ~= nil or passMode ~= nil))

	local secondsLeft = math.floor(ExpressAccess.SecondsLeft(player))
	if secondsLeft > 0 and player:GetAttribute(ExpressAccess.PASS_ATTRIBUTE) ~= true then
		chip.Visible = true
		chip.Text = string.format("EXPRESS  %d:%02d", secondsLeft // 60, secondsLeft % 60)
	else
		chip.Visible = false
	end
end)

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

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
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
-- Permit ticket
--=============================================================================

-- The permit is drawn as a paper ticket, not a HUD panel: dark ink on cream
-- paper reads as "a document you are buying", matches the delivery clipboard
-- (DeliveryHud.client.luau), and gives buying it somewhere to land - the
-- purchase is confirmed by a red APPROVED stamp slammed onto the ticket.
local PAPER = Color3.fromRGB(252, 249, 240)
local PAPER_EDGE = Color3.fromRGB(196, 182, 150)
local PAPER_RULE = Color3.fromRGB(228, 220, 202)
local INK = Color3.fromRGB(46, 50, 60)
local INK_DIM = Color3.fromRGB(122, 124, 134)
local INK_GOOD = Color3.fromRGB(40, 150, 80)
local INK_BAD = Color3.fromRGB(196, 60, 60)
local STAMP_RED = Color3.fromRGB(190, 40, 40)
local LOCKED = Color3.fromRGB(196, 190, 174)

-- ProSoundEffects "Date Stamp Big Office Impact Good Squeak 2" (Creator Store).
local STAMP_SOUND_ID = "rbxassetid://9114026047"

local TICKET_WIDTH = 420
local TICKET_HEIGHT = 290
-- The tear-off stub sits right of the perforation; the details are left of it.
local STUB_WIDTH = 100
local MAIN_WIDTH = TICKET_WIDTH - STUB_WIDTH - 30

-- How long the finished stamp stays on screen before the ticket goes away.
local STAMP_HOLD_SECONDS = 1.3

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = instance
	return c
end

local gui = Instance.new("ScreenGui")
gui.Name = "PermitGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "PermitPanel"
panel.Size = UDim2.fromOffset(TICKET_WIDTH, TICKET_HEIGHT)
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.new(0.5, 0, 1, -140)
panel.BackgroundColor3 = PAPER
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = gui
corner(panel, 10)
local stroke = Instance.new("UIStroke")
stroke.Color = PAPER_EDGE
stroke.Thickness = 2
stroke.Parent = panel
ResponsiveScale.Fit(panel)

local function label(name, pos, size, font, textSize, color, alignment)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = pos
	l.Size = size
	l.Font = font
	l.TextSize = textSize
	l.TextColor3 = color
	l.TextWrapped = true
	l.TextXAlignment = alignment or Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Parent = panel
	return l
end

-- Header band: what kind of ticket this is, plus the close button.
local band = Instance.new("Frame")
band.Name = "Band"
band.Position = UDim2.fromOffset(12, 12)
band.Size = UDim2.new(1, -24, 0, 34)
band.BackgroundColor3 = INK
band.BorderSizePixel = 0
band.Parent = panel
corner(band, 6)

local bandTitle = Instance.new("TextLabel")
bandTitle.Name = "BandTitle"
bandTitle.BackgroundTransparency = 1
bandTitle.Position = UDim2.fromOffset(12, 0)
bandTitle.Size = UDim2.new(1, -56, 1, 0)
bandTitle.Font = Enum.Font.LuckiestGuy
bandTitle.TextSize = 20
bandTitle.TextColor3 = PAPER
bandTitle.TextXAlignment = Enum.TextXAlignment.Left
bandTitle.Parent = band

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0.5)
closeButton.Position = UDim2.new(1, -6, 0.5, 0)
closeButton.Size = UDim2.fromOffset(24, 24)
closeButton.BackgroundColor3 = Color3.fromRGB(78, 84, 98)
closeButton.BorderSizePixel = 0
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 14
closeButton.TextColor3 = PAPER
closeButton.Text = "X"
closeButton.Parent = band
corner(closeButton, 5)

local zoneLabel = label("Zone", UDim2.fromOffset(20, 56), UDim2.fromOffset(MAIN_WIDTH, 32), Enum.Font.LuckiestGuy, 28, INK)
zoneLabel.TextWrapped = false
local body = label("Body", UDim2.fromOffset(20, 92), UDim2.fromOffset(MAIN_WIDTH, 54), Enum.Font.Gotham, 13, INK_DIM)
local reqs = label("Requirements", UDim2.fromOffset(20, 150), UDim2.fromOffset(MAIN_WIDTH, 54), Enum.Font.GothamBold, 14, INK)
reqs.RichText = true

local buyButton = Instance.new("TextButton")
buyButton.Name = "Buy"
buyButton.AnchorPoint = Vector2.new(0, 1)
buyButton.Position = UDim2.new(0, 20, 1, -16)
buyButton.Size = UDim2.fromOffset(MAIN_WIDTH, 42)
buyButton.BorderSizePixel = 0
buyButton.Font = Enum.Font.GothamBold
buyButton.TextSize = 16
buyButton.Parent = panel
corner(buyButton, 8)

-- The tear-off stub: a dotted perforation and "ADMIT ONE".
local perforationX = TICKET_WIDTH - STUB_WIDTH - 6
local DOTS = 12
for i = 0, DOTS - 1 do
	local dot = Instance.new("Frame")
	dot.Name = "Perforation"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Size = UDim2.fromOffset(5, 5)
	dot.Position = UDim2.fromOffset(perforationX, 62 + i * ((TICKET_HEIGHT - 76) / (DOTS - 1)))
	dot.BackgroundColor3 = PAPER_RULE
	dot.BorderSizePixel = 0
	dot.Parent = panel
	corner(dot, 3)
end

local stubX = TICKET_WIDTH - STUB_WIDTH
local admit = label("Admit", UDim2.fromOffset(stubX, 70), UDim2.fromOffset(STUB_WIDTH - 10, 30), Enum.Font.LuckiestGuy, 26, INK, Enum.TextXAlignment.Center)
admit.Text = "ADMIT"
local one = label("One", UDim2.fromOffset(stubX, 98), UDim2.fromOffset(STUB_WIDTH - 10, 30), Enum.Font.LuckiestGuy, 26, INK, Enum.TextXAlignment.Center)
one.Text = "ONE"
local forGood = label("ForGood", UDim2.fromOffset(stubX, 140), UDim2.fromOffset(STUB_WIDTH - 10, 34), Enum.Font.GothamBold, 11, INK_DIM, Enum.TextXAlignment.Center)
forGood.Text = "VALID FOR GOOD"
local ticketNumber = label("Number", UDim2.new(0, stubX, 1, -34), UDim2.fromOffset(STUB_WIDTH - 10, 18), Enum.Font.GothamBold, 12, INK_DIM, Enum.TextXAlignment.Center)

-- The stamp. Sits over the details half of the ticket, tilted like a real one,
-- and only exists while a purchase is being confirmed (see playStamp).
local stamp = Instance.new("Frame")
stamp.Name = "Stamp"
stamp.AnchorPoint = Vector2.new(0.5, 0.5)
stamp.Position = UDim2.fromOffset(20 + MAIN_WIDTH / 2, 170)
stamp.Size = UDim2.fromOffset(250, 82)
stamp.BackgroundTransparency = 1
stamp.Rotation = -12
stamp.Visible = false
stamp.ZIndex = 10
stamp.Parent = panel
corner(stamp, 10)
local stampScale = Instance.new("UIScale")
stampScale.Parent = stamp
local stampStroke = Instance.new("UIStroke")
stampStroke.Color = STAMP_RED
stampStroke.Thickness = 5
stampStroke.Parent = stamp
local stampLabel = Instance.new("TextLabel")
stampLabel.BackgroundTransparency = 1
stampLabel.Size = UDim2.fromScale(1, 1)
stampLabel.Font = Enum.Font.LuckiestGuy
stampLabel.TextSize = 46
stampLabel.TextColor3 = STAMP_RED
stampLabel.Text = "APPROVED"
stampLabel.ZIndex = 10
stampLabel.Parent = stamp

local shownPermit = nil
local dismissedPermit = nil
local busy = false
-- The permit whose purchase is in flight or whose stamp is still on screen.
-- Set BEFORE the purchase is sent, not after it succeeds: the server marks the
-- permit owned before the reply arrives, and the Heartbeat below hides the
-- ticket the moment the permit is owned - so without this the stamp would
-- land on a ticket that has already vanished.
local stamping = nil
local flash = nil -- { Text, Until }

-- Loaded once up front so the first stamp is not silent while it downloads.
task.spawn(function()
	local preload = Instance.new("Sound")
	preload.SoundId = STAMP_SOUND_ID
	ContentProvider:PreloadAsync({ preload })
	preload:Destroy()
end)

local function playStampSound()
	local sound = Instance.new("Sound")
	sound.SoundId = STAMP_SOUND_ID
	sound.Volume = 1
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	SoundService:PlayLocalSound(sound)
end

-- Slams the APPROVED stamp down, then jolts the ticket. Yields until the
-- animation has finished.
local function playStamp()
	stampScale.Scale = 2.8
	stampLabel.TextTransparency = 0.6
	stampStroke.Transparency = 0.6
	stamp.Visible = true

	-- Fast and un-eased at the end: a stamp arrives, it does not settle.
	local slam = TweenService:Create(stampScale, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Scale = 1,
	})
	slam:Play()
	slam.Completed:Wait()

	playStampSound()
	-- The ink darkens in as the stamp lands.
	local settle = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(stampLabel, settle, { TextTransparency = 0 }):Play()
	TweenService:Create(stampStroke, settle, { Transparency = 0 }):Play()

	for _, angle in { 2, -1.5, 0.8, 0 } do
		local jolt = TweenService:Create(panel, TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Rotation = angle,
		})
		jolt:Play()
		jolt.Completed:Wait()
	end
end

local function leaderstat(name)
	local stats = player:FindFirstChild("leaderstats")
	local v = stats and stats:FindFirstChild(name)
	return v and v.Value or 0
end

local function money(n)
	local s = tostring(math.floor(n))
	return "$" .. s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function requirementLine(met, text)
	return string.format('<font color="#%s">%s</font>', (if met then INK_GOOD else INK_BAD):ToHex(), text)
end

local function refreshPanel(permitId)
	local def = ProgressionConfig.Permits[permitId]
	local owned = PermitAccess.Owned(player)
	local cash, deliveries = leaderstat("Money"), leaderstat("Deliveries")
	local reason = PermitAccess.BlockReason(permitId, owned, cash, deliveries)
	bandTitle.Text = string.upper(def.DisplayName)
	zoneLabel.Text = string.upper(def.ZoneName)
	ticketNumber.Text = string.format("No. %03d", def.Zone)
	body.Text = string.format(
		"Only permit holders may cross into the %s. Jobs there pay %sx what Old Town pays.",
		def.ZoneName,
		tostring(DeliveryConfig.Payout.ZoneMultipliers[def.Zone] or 1)
	)
	local lines = {
		requirementLine(cash >= def.Price, string.format("Price: %s  (you have %s)", money(def.Price), money(cash))),
		requirementLine(
			deliveries >= def.RequiredDeliveries,
			string.format("Deliveries: %d / %d", math.min(deliveries, def.RequiredDeliveries), def.RequiredDeliveries)
		),
	}
	if def.Requires then
		table.insert(
			lines,
			requirementLine(owned[def.Requires] == true, "Requires: " .. ProgressionConfig.Permits[def.Requires].DisplayName)
		)
	end
	reqs.Text = table.concat(lines, "\n")
	if flash and os.clock() < flash.Until then
		buyButton.Text = flash.Text
		buyButton.BackgroundColor3 = INK_BAD
		buyButton.TextColor3 = PAPER
		buyButton.AutoButtonColor = false
	elseif reason then
		buyButton.Text = reason
		buyButton.BackgroundColor3 = LOCKED
		buyButton.TextColor3 = INK_DIM
		buyButton.AutoButtonColor = false
	else
		buyButton.Text = "Buy for " .. money(def.Price)
		buyButton.BackgroundColor3 = INK_GOOD
		buyButton.TextColor3 = PAPER
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
	stamping = permitId
	buyButton.Text = "Stamping..."
	buyButton.AutoButtonColor = false
	local ok, result, why = pcall(buyPermit.InvokeServer, buyPermit, permitId)
	if not ok or not result then
		stamping = nil
		busy = false
		flash = { Text = (ok and why) or "Couldn't buy - try again", Until = os.clock() + 2.5 }
		return
	end
	playStamp()
	task.wait(STAMP_HOLD_SECONDS)
	-- Reset for the next ticket before the Heartbeat can show one.
	stamp.Visible = false
	panel.Rotation = 0
	stamping = nil
	busy = false
end)

closeButton.Activated:Connect(function()
	if stamping then
		return
	end
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
	-- While a purchase is being stamped the ticket stays up even though the
	-- permit is already owned (and the player may already be rolling out of the
	-- pay zone), and it is not redrawn - it would flip to "Already owned"
	-- under the stamp.
	local show = stamping ~= nil or (permitHere ~= nil and not owned[permitHere] and dismissedPermit ~= permitHere)
	shownPermit = if show and stamping == nil then permitHere else nil
	panel.Visible = show
	setMouseFree(show)
	if show and stamping == nil then
		refreshPanel(permitHere)
	end
end)

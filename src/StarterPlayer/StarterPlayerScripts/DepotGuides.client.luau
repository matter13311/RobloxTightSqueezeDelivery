-- The depot, explaining itself: the big sign over the loading bay, and the
-- space guide that shades from red to green as you line up with a space.
--
-- WHY ALL OF THIS IS CLIENT-SIDE
--
-- The space guide is one player's private feedback. Two drivers manoeuvring
-- into adjacent bays need to see their OWN alignment, and a server-driven
-- colour would give them a single shared answer that is wrong for at least one
-- of them. It is also derived data - ParkGrade already runs on the client, and
-- the payout re-checks the geometry server-side regardless (see
-- DeliveryManager's header), so nothing here is an authority on anything.
-- Recolouring a part from the server every frame would replicate a property
-- change to every client in the game, forever, for pure decoration.
--
-- The sign is built here for a smaller reason: it is animated, and animation
-- is a client's job either way. Every client builds its own copy, so nothing
-- is replicated at all.
--
-- The guide's green means EXACTLY "the board will open" - it is driven by
-- ParkGrade.Approach, which returns 1 precisely when ParkGrade.Evaluate would
-- say Inside. That is the whole point: a player who cannot work out why the
-- job board is not appearing can watch the bay instead of guessing.
--
-- ONLY ONE PLACE IS EVER LIT, and only from a vehicle. On foot, nothing: a
-- player walking past cannot park in anything, so a glowing bay is decoration
-- pretending to be an instruction. In a vehicle with no contract, the depot -
-- that is where the game wants you. Carrying a contract, the destination for
-- that contract and nowhere else, because parking anywhere else does nothing
-- and a green outline that pays out no money is a lie.
--
-- Bays further away than Guides.ShowWithinStuds stay dark whatever the state,
-- so the map is not a field of red rectangles.
--
-- The guide is four corner posts and nothing on the floor - see
-- DeliveryConfig.Guides for why. Briefly: a floor outline is invisible from a
-- first-person driving camera at exactly the distance the colour matters
-- most, and drawn together with the posts the pair read as an upside-down
-- table rather than as a bay.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local player = Players.LocalPlayer
local VehicleFolder = workspace:WaitForChild("Vehicles")

local world = DeliveryConfig.World
local guides = DeliveryConfig.Guides

--=============================================================================
-- Palette
--=============================================================================

local FAR = Color3.fromRGB(220, 62, 52) -- nowhere near lined up
local NEAR = Color3.fromRGB(244, 176, 54) -- close
local IN = Color3.fromRGB(74, 214, 116) -- inside: the board will open

local HAZARD_YELLOW = Color3.fromRGB(250, 204, 48)
local HAZARD_DARK = Color3.fromRGB(28, 26, 22)

local function ramp(t)
	if t < 0.5 then
		return FAR:Lerp(NEAR, t / 0.5)
	end
	return NEAR:Lerp(IN, (t - 0.5) / 0.5)
end

--=============================================================================
-- World lookup
--=============================================================================

-- Lazy and retried while empty, matching DeliveryHud's findBaySpaces: the
-- depot is hand-built in Studio and can appear, move or be renamed after this
-- script has already run.
local function findLoadingBay()
	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	local depotFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DepotFolderName)
	return depotFolder and depotFolder:FindFirstChild(world.LoadingBayName)
end

local function findDestinationsFolder()
	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	return deliveryRoot and deliveryRoot:FindFirstChild(world.DestinationsFolderName)
end

local function isSpace(instance)
	return instance:IsA("BasePart") and instance.Name:sub(1, #world.SpacePrefix) == world.SpacePrefix
end

-- A prefix rather than an exact name, for the same reason SpacePrefix is one:
-- a big destination can carry Sign1 over each door without a list anywhere.
local function isSign(instance)
	return instance:IsA("BasePart") and instance.Name:sub(1, #world.SignPrefix) == world.SignPrefix
end

--=============================================================================
-- The sign
--=============================================================================

-- Which face of the Sign part the board is drawn on. An attribute rather than
-- a guess, because there is no way to tell from a Part which way it is meant
-- to be read - set `SignFace` to "Front"/"Back"/"Left"/"Right"/"Top" in Studio
-- if Front is not the one facing the road.
local function signFace(signPart)
	local named = signPart:GetAttribute("SignFace")
	if type(named) == "string" and Enum.NormalId[named] then
		return Enum.NormalId[named]
	end
	return Enum.NormalId.Front
end

-- A band of diagonal hazard stripes. Built from rotated Frames rather than an
-- image so it needs no uploaded asset and scales to whatever the sign part's
-- proportions turn out to be.
local function hazardStripe(parent, yScale)
	local band = Instance.new("Frame")
	band.Size = UDim2.new(1, 0, 0.11, 0)
	band.Position = UDim2.new(0, 0, yScale, 0)
	band.BackgroundColor3 = HAZARD_YELLOW
	band.BorderSizePixel = 0
	band.ClipsDescendants = true
	band.Parent = parent

	for i = 0, 15 do
		local slash = Instance.new("Frame")
		slash.Size = UDim2.new(0.045, 0, 3, 0)
		slash.Position = UDim2.new(i * 0.09 - 0.1, 0, -1, 0)
		slash.Rotation = 28
		slash.BackgroundColor3 = HAZARD_DARK
		slash.BorderSizePixel = 0
		slash.Parent = band
	end
	return band
end

local function buildSign(signPart)
	if signPart:FindFirstChild("DepotSignGui") then
		return
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "DepotSignGui"
	gui.Face = signFace(signPart)
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	-- Always drawn at full brightness regardless of the time of day. A depot
	-- sign that goes dim at night is a depot sign nobody finds at night.
	gui.LightInfluence = 0
	gui.Parent = signPart

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(20, 28, 46)
	backdrop.BorderSizePixel = 0
	backdrop.Parent = gui

	hazardStripe(backdrop, 0)
	hazardStripe(backdrop, 0.89)

	local headline = Instance.new("TextLabel")
	headline.Position = UDim2.fromScale(0.5, 0.34)
	headline.Size = UDim2.fromScale(0.94, 0.32)
	headline.AnchorPoint = Vector2.new(0.5, 0.5)
	headline.BackgroundTransparency = 1
	headline.Font = Enum.Font.LuckiestGuy
	headline.TextScaled = true
	headline.TextColor3 = HAZARD_YELLOW
	headline.Text = "CARGO PICKUP"
	headline.Parent = backdrop

	local headlineStroke = Instance.new("UIStroke")
	headlineStroke.Color = HAZARD_DARK
	headlineStroke.Thickness = 5
	headlineStroke.Parent = headline

	local subline = Instance.new("TextLabel")
	subline.Position = UDim2.fromScale(0.5, 0.61)
	subline.Size = UDim2.fromScale(0.9, 0.13)
	subline.AnchorPoint = Vector2.new(0.5, 0.5)
	subline.BackgroundTransparency = 1
	subline.Font = Enum.Font.GothamBold
	subline.TextScaled = true
	subline.TextColor3 = Color3.fromRGB(236, 240, 247)
	subline.Text = "PARK YOUR VEHICLE IN THE BAY TO LOAD UP"
	subline.Parent = backdrop

	-- The pulsing chevrons. Motion is what actually catches an eye that is
	-- busy driving - a static sign of any size gets read once and then tuned
	-- out, and this one needs to keep working on the player's tenth delivery.
	local chevrons = Instance.new("TextLabel")
	chevrons.Position = UDim2.fromScale(0.5, 0.775)
	chevrons.Size = UDim2.fromScale(0.6, 0.1)
	chevrons.AnchorPoint = Vector2.new(0.5, 0.5)
	chevrons.BackgroundTransparency = 1
	chevrons.Font = Enum.Font.GothamBold
	chevrons.TextScaled = true
	chevrons.TextColor3 = HAZARD_YELLOW
	chevrons.Text = "\u{25BC} \u{25BC} \u{25BC}"
	chevrons.Parent = backdrop

	-- Tweened rather than stepped per frame: TweenService runs this without a
	-- Lua callback per frame, and the sign is on screen for most of the
	-- session.
	TweenService:Create(
		chevrons,
		TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ TextTransparency = 0.75 }
	):Play()
end

--=============================================================================
-- Destination signs
--=============================================================================

-- Every destination names itself. The board is drawn from the destination
-- MODEL's name rather than from anything typed onto the sign part, so a place
-- renamed in Studio renames its own sign - and the name on the sign is
-- guaranteed to be the same string the contract board, the waypoint and the
-- payout summary all use, because it is the same string.
--
-- Two states, because a destination sign has two jobs. Idle, it is a landmark:
-- this is somewhere deliveries go, remember it for later. Lit, it is the
-- answer to "am I there yet" for the one player carrying that contract - and
-- since it is a SurfaceGui built on the client, one player seeing their
-- destination lit up costs every other player nothing at all.
local DEST_IDLE = Color3.fromRGB(120, 134, 158)
local DEST_ACTIVE = Color3.fromRGB(74, 214, 116)

local function buildDestinationSign(signPart, destinationName)
	local existing = signPart:FindFirstChild("DestinationSignGui")
	if existing then
		existing:Destroy() -- rebuilt rather than reused, so a renamed model updates
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "DestinationSignGui"
	gui.Face = signFace(signPart)
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	-- Readable at night, same reasoning as the depot sign.
	gui.LightInfluence = 0
	gui.Parent = signPart

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(18, 22, 32)
	backdrop.BorderSizePixel = 0
	backdrop.Parent = gui

	-- A colour bar down the left edge rather than a full border: it reads as a
	-- status light from a distance, where a thin outline just disappears.
	local accentBar = Instance.new("Frame")
	accentBar.Size = UDim2.new(0.035, 0, 1, 0)
	accentBar.BackgroundColor3 = DEST_IDLE
	accentBar.BorderSizePixel = 0
	accentBar.Parent = backdrop

	local kicker = Instance.new("TextLabel")
	kicker.Position = UDim2.fromScale(0.09, 0.13)
	kicker.Size = UDim2.fromScale(0.85, 0.16)
	kicker.BackgroundTransparency = 1
	kicker.Font = Enum.Font.GothamBold
	kicker.TextScaled = true
	kicker.TextXAlignment = Enum.TextXAlignment.Left
	kicker.TextColor3 = DEST_IDLE
	kicker.Text = "DELIVERY POINT"
	kicker.Parent = backdrop

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Position = UDim2.fromScale(0.09, 0.31)
	nameLabel.Size = UDim2.fromScale(0.85, 0.36)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.LuckiestGuy
	nameLabel.TextScaled = true
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.TextColor3 = Color3.fromRGB(236, 240, 247)
	nameLabel.Text = destinationName
	nameLabel.Parent = backdrop

	local status = Instance.new("TextLabel")
	status.Position = UDim2.fromScale(0.09, 0.71)
	status.Size = UDim2.fromScale(0.85, 0.16)
	status.BackgroundTransparency = 1
	status.Font = Enum.Font.GothamBold
	status.TextScaled = true
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextColor3 = DEST_IDLE
	status.Text = "TAKE A JOB AT THE DEPOT"
	status.Parent = backdrop

	-- Built once and left paused. Creating a Tween per state change would leak
	-- one every time the player took a contract.
	local pulse = TweenService:Create(
		accentBar,
		TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ BackgroundTransparency = 0.65 }
	)

	return {
		Name = destinationName,
		AccentBar = accentBar,
		Kicker = kicker,
		Status = status,
		Pulse = pulse,
		Active = false,
	}
end

local destinationSigns = {}

local function setSignActive(sign, active)
	if sign.Active == active then
		return
	end
	sign.Active = active

	local color = if active then DEST_ACTIVE else DEST_IDLE
	sign.AccentBar.BackgroundColor3 = color
	sign.Kicker.TextColor3 = color
	sign.Status.TextColor3 = color
	sign.Kicker.Text = if active then "YOUR DELIVERY" else "DELIVERY POINT"
	sign.Status.Text = if active then "DROP OFF HERE - PARK IN THE BAY" else "TAKE A JOB AT THE DEPOT"

	if active then
		sign.Pulse:Play()
	else
		sign.Pulse:Cancel()
		sign.AccentBar.BackgroundTransparency = 0
	end
end

local function refreshDestinationSigns(activeName)
	for _, sign in destinationSigns do
		setSignActive(sign, sign.Name == activeName)
	end
end

--=============================================================================
-- The space guide
--=============================================================================

-- Four client-local neon posts per space, one on each corner, standing just
-- clear of the space's own base so they never z-fight a floor decal. Created
-- here rather than asked for in Studio so the guide works on a bay that has
-- had nothing done to it - and if the space DOES carry a decal, that gets tinted with the
-- same colour below, so a hand-drawn floor outline is driven by this too
-- rather than sitting there in its painted colour contradicting the guide.
--
-- `group` is which place the space belongs to: DEPOT_GROUP for the loading
-- bay, or the destination model's name. Exactly one group is ever lit - see
-- the header.
local function buildGuide(space, group)
	local holder = Instance.new("Folder")
	holder.Name = "DepotGuide_" .. group .. "_" .. space.Name
	holder.Parent = workspace

	-- One post on each corner of the space, standing just clear of the floor.
	-- See DeliveryConfig.Guides for why the corners are the only place they
	-- go, and why they stay part-transparent at full brightness.
	local thickness = guides.CornerPostThickness
	local height = guides.CornerPostHeight
	local size = Vector3.new(thickness, height, thickness)

	-- Inset by half a post so the posts sit inside the space's footprint
	-- rather than straddling its edge.
	local cornerX = space.Size.X / 2 - thickness / 2
	local cornerZ = space.Size.Z / 2 - thickness / 2
	local y = -space.Size.Y / 2 + guides.CornerPostBase + height / 2

	local posts = {}
	for _, corner in { Vector2.new(1, 1), Vector2.new(1, -1), Vector2.new(-1, 1), Vector2.new(-1, -1) } do
		local post = Instance.new("Part")
		post.Size = size
		post.CFrame = space.CFrame * CFrame.new(cornerX * corner.X, y, cornerZ * corner.Y)
		post.Anchored = true
		post.CanCollide = false
		post.CanQuery = false -- the suspension raycasts must never see this
		post.CanTouch = false
		post.CastShadow = false
		post.Material = Enum.Material.Neon
		post.Color = FAR
		post.Transparency = 1 -- everything starts dark; the poll lights only what applies
		post.Parent = holder
		table.insert(posts, post)
	end

	-- The decal's own colour is kept so the tint can be faded back OUT again.
	-- Without it a decal tinted red once would stay red after the guide went
	-- dark, which is worse than never having tinted it at all.
	local decals = {}
	for _, child in space:GetChildren() do
		if child:IsA("Decal") or child:IsA("Texture") then
			table.insert(decals, { Instance = child, Original = child.Color3 })
		end
	end

	return {
		Space = space,
		Group = group,
		Posts = posts,
		Decals = decals,
		Color = FAR,
		Visibility = 0,
	}
end

--=============================================================================
-- Wiring
--=============================================================================

-- Contains a character no Instance name can hold, so it can never collide with
-- a destination model called "Depot".
local DEPOT_GROUP = "\0Depot"

-- Which destination the player is carrying for, or nil.
--
-- Read straight off the same RemoteEvent DeliveryHud listens to rather than
-- asked of the HUD: a RemoteEvent takes as many connections as you like, and
-- routing it through the HUD would make the space guide depend on a script
-- that is otherwise only about the screen.
local deliveryUpdateEvent = ReplicatedStorage:WaitForChild("DeliveryUpdate")
local activeDestination = nil

deliveryUpdateEvent.OnClientEvent:Connect(function(update)
	if type(update) ~= "table" then
		return
	end
	activeDestination = update.Active and update.Active.Stops[1] or nil
	refreshDestinationSigns(activeDestination)
end)

local entries = nil

local function build()
	local loadingBay = findLoadingBay()
	if not loadingBay then
		return false
	end

	local built = {}
	for _, descendant in loadingBay:GetDescendants() do
		if isSpace(descendant) then
			table.insert(built, buildGuide(descendant, DEPOT_GROUP))
		elseif isSign(descendant) then
			buildSign(descendant)
		end
	end

	-- Every destination gets the same treatment, built once up front. A dark
	-- guide costs nothing - anchored, non-colliding, fully transparent parts
	-- that no raycast can see - and building them on accept instead would mean
	-- the outline popping into existence just as the player arrives to use it.
	local destinationsFolder = findDestinationsFolder()
	for _, model in destinationsFolder and destinationsFolder:GetChildren() or {} do
		for _, descendant in model:GetDescendants() do
			if isSpace(descendant) then
				table.insert(built, buildGuide(descendant, model.Name))
			elseif isSign(descendant) then
				-- The MODEL's name, not the sign part's - see the section
				-- header. Warehouse1.Sign reads "Warehouse1".
				table.insert(destinationSigns, buildDestinationSign(descendant, model.Name))
			end
		end
	end

	if #built == 0 then
		return false
	end

	entries = built
	return true
end

-- Retried on a slow tick until the depot exists, then stops. Same reasoning as
-- DeliveryHud's lazy lookup - during development the geometry appears after
-- this script has already run, and a one-shot lookup would leave the guide
-- silently dead with no clue why.
task.spawn(function()
	while not build() do
		task.wait(2)
	end
	-- The depot geometry can finish appearing after a contract is already in
	-- hand (a slow first load, or a builder dropping the folder in mid-session),
	-- so the signs are brought into step once rather than waiting for the next
	-- DeliveryUpdate - which, mid-contract, is the delivery itself.
	refreshDestinationSigns(activeDestination)
end)

-- Target colour and visibility are recomputed on a slow tick (a lit space
-- costs a GetBoundingBox and eight transforms) while the actual values ease
-- toward them every frame. That split is what makes the guide read as a light
-- fading up rather than values snapping between poll results.
local POLL_INTERVAL = 0.1
local EASE_PER_SECOND = 9

local accumulator = POLL_INTERVAL

local function repoll()
	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	local chassis = carModel and carModel.PrimaryPart

	-- On foot, litGroup is nil and every guide goes dark - see the header.
	local litGroup = if chassis then (activeDestination or DEPOT_GROUP) else nil

	for _, entry in entries do
		if entry.Group ~= litGroup then
			entry.TargetVisibility = 0
			continue
		end

		-- Distance to the space's centre rather than to its nearest face: a
		-- cheap number that only has to decide whether this bay is the
		-- player's business at all. ParkGrade does the precise work once it
		-- is.
		local distance = (entry.Space.Position - chassis.Position).Magnitude
		local fade = math.max(guides.FadeBandStuds, 0.001)
		local visibility = math.clamp((guides.ShowWithinStuds - distance) / fade, 0, 1)
		entry.TargetVisibility = visibility

		-- Only worth grading a space the player can actually see. A guide that
		-- is fading out keeps whatever colour it had, which is what a light
		-- going dark looks like.
		if visibility > 0 then
			entry.TargetColor = ramp(ParkGrade.Approach(carModel, entry.Space))
		end
	end
end

RunService.RenderStepped:Connect(function(delta)
	if not entries then
		return
	end

	accumulator += delta
	if accumulator >= POLL_INTERVAL then
		accumulator = 0
		repoll()
	end

	-- Framerate-independent exponential ease, so the fade looks the same on a
	-- 30fps tablet as on a 240Hz monitor.
	local alpha = 1 - math.exp(-EASE_PER_SECOND * delta)

	for _, entry in entries do
		local targetVisibility = entry.TargetVisibility or 0

		-- Nothing to write once a dark guide has finished going dark - which
		-- is every guide in the map bar the handful around the player, so this
		-- is the check that keeps a map full of destinations free.
		if entry.Visibility ~= 0 or targetVisibility ~= 0 then
			entry.Visibility += (targetVisibility - entry.Visibility) * alpha
			if math.abs(entry.Visibility - targetVisibility) < 0.002 then
				entry.Visibility = targetVisibility
			end
			entry.Color = entry.Color:Lerp(entry.TargetColor or FAR, alpha)

			-- The posts top out part-transparent, so the brightest they ever
			-- get is still something the player can see the bay through.
			local transparency = 1 - entry.Visibility * (1 - guides.CornerPostTransparency)
			for _, post in entry.Posts do
				post.Color = entry.Color
				post.Transparency = transparency
			end
			-- The decal fades from its own painted colour TO the guide colour
			-- rather than fading out, so a floor outline stays readable the
			-- whole time and simply stops carrying a message.
			for _, decal in entry.Decals do
				decal.Instance.Color3 = decal.Original:Lerp(entry.Color, entry.Visibility)
			end
		end
	end
end)

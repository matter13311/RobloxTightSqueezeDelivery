-- The driver-facing half of hitching: a card that says what the tractor can do
-- about a trailer RIGHT NOW, and one key (or one tap) that does it.
--
-- WHAT IS SHOWN, in order of what the driver needs to know:
--   * nothing at all, when they are not driving something with a hitch
--   * the key to hitch, when the trailer behind them can be taken
--   * why it cannot be taken yet ("Not lined up", "Stop to hitch up"), which
--     is the feedback that teaches the manoeuvre
--   * the key to bring their trailer back to the stalls, when they are in the
--     yard without it
--   * where to go, when they have parked a tractor somewhere it cannot load
--
-- Showing the REASON rather than going quiet is the whole point: a prompt that
-- only appears once you are already correct tells the player nothing about how
-- to get there, and backing a trailer is exactly the manoeuvre where a driver
-- needs to know which of distance and angle they are still getting wrong.
--
-- WHERE IT IS, AND WHY "DROP TRAILER" IS NOT ON IT. The first version was one
-- black strip in the lower middle of the screen that said "[T] Drop trailer"
-- for every second the trailer was on - which is most of a rig's life - over
-- the back of the truck the player was trying to watch. Two different things
-- had been given one loud place:
--
--   A STANDING FACT ("T drops the trailer") belongs with the other standing
--   facts, in the controls legend along the top (VehicleControlsHint), and is
--   handed to it through the TOW_HINT_ATTRIBUTE below. It costs no screen.
--
--   A MOMENT ("you can hitch now", "you are not lined up") is the card: docked
--   on top of the dashboard, bottom-centre, where the eye already goes for
--   gear and speed while reversing. It is on screen only while there is
--   something to do or to fix, so appearing IS the message.
--
-- Bottom-centre is also the only band that is free in every mode: the pedals
-- and the secondary buttons own both bottom corners on touch, the job panel
-- owns the top, and the tutorial banner sits below it (the card lifts clear of
-- the banner while the tutorial is running - see cardPosition).
--
-- THE CARD IS A BUTTON. Touch has no legend and no T key, so tapping the card
-- is how a phone hitches - and on touch the card does stay up while towing, as
-- the only way to drop.
--
-- The colour of its edge is the state, readable before the words are:
--   green  - press the key, it will work
--   amber  - not yet; the line says what to fix
--   grey   - information only

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
local Haulage = require(ReplicatedStorage.Modules.Delivery.Haulage)
local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)

local player = Players.LocalPlayer
local hitchRequest = ReplicatedStorage:WaitForChild("TrailerHitchRequest")

local HITCH_ACTION = "TrailerHitchToggle"
-- T for "tow". Every other letter within reach of WASD is already spoken
-- for while seated: F exits, L is the headlights, Q/E are the turn signals,
-- C cycles the camera (VehicleCamera), Space is the handbrake, A/D steer - and
-- H is the HORN (VehicleHorn in RayCastSuspension.client.luau), which is what
-- this was originally and wrongly bound to. Check that list before rebinding.
local HITCH_KEY = Enum.KeyCode.T

-- What T does while it is a standing fact rather than a moment - "drop
-- trailer", today - or nil. Read by VehicleControlsHint, which appends it to
-- the legend. Client-only, like TutorialActive.
local TOW_HINT_ATTRIBUTE = "TowKeyHint"
-- Matches TutorialGuide's attribute.
local TUTORIAL_ACTIVE_ATTRIBUTE = "TutorialActive"

-- How near a bay (studs, truck to the nearest space) counts as "parked at it"
-- for the two where-to-go hints. Roughly a bay's own length: close enough that
-- the player is plainly trying to use it, far enough to catch a truck stopped
-- just short.
local AT_BAY_STUDS = 45

-- How long a line sent by the server (a refusal, "your trailer is waiting")
-- stays up before the ordinary prompt takes the card back.
local NOTICE_SECONDS = 4

-- The HUD's own palette (DeliveryHud, VehicleTouchControls, the tutorial
-- banner), so the card reads as part of the same dashboard.
local PANEL = Color3.fromRGB(18, 20, 25)
local CARD = Color3.fromRGB(28, 31, 38)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(160, 170, 188)
local TONES = {
	Action = Color3.fromRGB(86, 200, 128),
	Warn = Color3.fromRGB(236, 168, 40),
	Info = Color3.fromRGB(96, 106, 124),
}

-- The key cap: a pale face on a darker lip, like a key on a keyboard. See the
-- comment where it is built for why it is not in the card's tone colour.
local KEY_FACE_COLOR = Color3.fromRGB(240, 243, 248)
local KEY_LIP_COLOR = Color3.fromRGB(128, 138, 156)
local KEY_SIZE = 34
local KEY_LIP = 4 -- how far the lip shows under the face, and how far a press travels
-- The press animation: down for PRESS_HOLD seconds out of every PRESS_PERIOD.
local PRESS_PERIOD = 1.1
local PRESS_HOLD = 0.22

--=============================================================================
-- The card
--=============================================================================

local gui = Instance.new("ScreenGui")
gui.Name = "TrailerHitchPrompt"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

-- Sized by its contents (a short line makes a small card), capped so a long
-- hint wraps instead of spanning a phone.
local card = Instance.new("TextButton")
card.Name = "Card"
card.AnchorPoint = Vector2.new(0.5, 1)
card.AutomaticSize = Enum.AutomaticSize.XY
card.Size = UDim2.fromOffset(0, 0)
card.BackgroundColor3 = PANEL
card.BackgroundTransparency = 0.06
card.BorderSizePixel = 0
card.AutoButtonColor = false
card.Text = ""
card.Parent = gui
Instance.new("UICorner", card).CornerRadius = UDim.new(0, 12)

local cardStroke = Instance.new("UIStroke")
cardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
cardStroke.Thickness = 2
cardStroke.Color = TONES.Info
cardStroke.Parent = card

local cardPadding = Instance.new("UIPadding")
cardPadding.PaddingLeft = UDim.new(0, 10)
cardPadding.PaddingRight = UDim.new(0, 16)
cardPadding.PaddingTop = UDim.new(0, 8)
cardPadding.PaddingBottom = UDim.new(0, 8)
cardPadding.Parent = card

local cardLayout = Instance.new("UIListLayout")
cardLayout.FillDirection = Enum.FillDirection.Horizontal
cardLayout.VerticalAlignment = Enum.VerticalAlignment.Center
cardLayout.Padding = UDim.new(0, 12)
cardLayout.SortOrder = Enum.SortOrder.LayoutOrder
cardLayout.Parent = card

-- The key cap: the one thing on the card that says "press", so it is the one
-- thing that changes shape between a prompt and a piece of information - it
-- is simply not there when there is nothing to press.
--
-- DRAWN AS A KEY, not as a badge. The first pass was a flat square in the
-- card's own green with a T in it, and it read as a status light - "T for
-- trailer, and it is green" - rather than as something to press. Three things
-- make it a key instead: the word PRESS in front of it; a pale keyboard-key
-- face with a darker lip under it, the same in every state, so it is plainly
-- an object and not part of the colour coding; and the face dipping onto its
-- lip every second or so, which is a key being pressed.
local keyGroup = Instance.new("Frame")
keyGroup.Name = "Key"
keyGroup.LayoutOrder = 1
keyGroup.AutomaticSize = Enum.AutomaticSize.X
keyGroup.Size = UDim2.fromOffset(0, KEY_SIZE + KEY_LIP)
keyGroup.BackgroundTransparency = 1
keyGroup.Parent = card

local keyGroupLayout = Instance.new("UIListLayout")
keyGroupLayout.FillDirection = Enum.FillDirection.Horizontal
keyGroupLayout.VerticalAlignment = Enum.VerticalAlignment.Center
keyGroupLayout.Padding = UDim.new(0, 8)
keyGroupLayout.SortOrder = Enum.SortOrder.LayoutOrder
keyGroupLayout.Parent = keyGroup

local pressLabel = Instance.new("TextLabel")
pressLabel.Name = "Press"
pressLabel.LayoutOrder = 1
pressLabel.AutomaticSize = Enum.AutomaticSize.X
pressLabel.Size = UDim2.fromOffset(0, KEY_SIZE)
pressLabel.BackgroundTransparency = 1
pressLabel.Font = Enum.Font.GothamBold
pressLabel.TextSize = 12
pressLabel.TextColor3 = DIM_TEXT
pressLabel.Text = "PRESS"
pressLabel.Parent = keyGroup

-- Holds the lip and the face. Its width is set per input type in show(): a
-- square for a letter, wider for the word TAP.
local keyHolder = Instance.new("Frame")
keyHolder.Name = "Cap"
keyHolder.LayoutOrder = 2
keyHolder.Size = UDim2.fromOffset(KEY_SIZE, KEY_SIZE + KEY_LIP)
keyHolder.BackgroundTransparency = 1
keyHolder.Parent = keyGroup

local keyLip = Instance.new("Frame")
keyLip.Name = "Lip"
keyLip.Position = UDim2.fromOffset(0, KEY_LIP)
keyLip.Size = UDim2.new(1, 0, 0, KEY_SIZE)
keyLip.BackgroundColor3 = KEY_LIP_COLOR
keyLip.BorderSizePixel = 0
keyLip.Parent = keyHolder
Instance.new("UICorner", keyLip).CornerRadius = UDim.new(0, 7)

local keyFace = Instance.new("TextLabel")
keyFace.Name = "Face"
keyFace.Size = UDim2.new(1, 0, 0, KEY_SIZE)
keyFace.BackgroundColor3 = KEY_FACE_COLOR
keyFace.BorderSizePixel = 0
keyFace.Font = Enum.Font.GothamBlack
keyFace.TextSize = 18
keyFace.TextColor3 = PANEL
keyFace.Text = HITCH_KEY.Name
keyFace.Parent = keyHolder
Instance.new("UICorner", keyFace).CornerRadius = UDim.new(0, 7)

local keyFaceStroke = Instance.new("UIStroke")
keyFaceStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
keyFaceStroke.Color = KEY_LIP_COLOR
keyFaceStroke.Thickness = 1
keyFaceStroke.Parent = keyFace

-- A small coloured dot standing in for the key cap on an information card, so
-- the text does not jump to the card's edge when the cap goes.
local dot = Instance.new("Frame")
dot.Name = "Dot"
dot.LayoutOrder = 1
dot.Size = UDim2.fromOffset(10, 10)
dot.BackgroundColor3 = TONES.Warn
dot.BorderSizePixel = 0
dot.Parent = card
Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

local textBlock = Instance.new("Frame")
textBlock.Name = "Text"
textBlock.LayoutOrder = 2
textBlock.AutomaticSize = Enum.AutomaticSize.XY
textBlock.Size = UDim2.fromOffset(0, 0)
textBlock.BackgroundTransparency = 1
textBlock.Parent = card

local textLayout = Instance.new("UIListLayout")
textLayout.FillDirection = Enum.FillDirection.Vertical
textLayout.Padding = UDim.new(0, 1)
textLayout.SortOrder = Enum.SortOrder.LayoutOrder
textLayout.Parent = textBlock

-- Each line wraps at this width, so the card is never wider than a phone held
-- sideways can spare between the exit button and the pedals.
local TEXT_MAX_WIDTH = 300

local function textLine(order, font, size, color)
	local line = Instance.new("TextLabel")
	line.LayoutOrder = order
	line.AutomaticSize = Enum.AutomaticSize.XY
	line.Size = UDim2.fromOffset(0, 0)
	line.BackgroundTransparency = 1
	line.Font = font
	line.TextSize = size
	line.TextColor3 = color
	line.TextXAlignment = Enum.TextXAlignment.Left
	line.TextWrapped = true
	line.Text = ""
	line.Parent = textBlock
	local width = Instance.new("UISizeConstraint")
	width.MaxSize = Vector2.new(TEXT_MAX_WIDTH, math.huge)
	width.Parent = line
	return line
end

local titleLabel = textLine(1, Enum.Font.GothamBold, 17, BRIGHT_TEXT)
local detailLabel = textLine(2, Enum.Font.GothamMedium, 13, DIM_TEXT)

-- Docked on the dashboard; lifted above the tutorial banner while that is up,
-- because the tutorial's hitch step is the one time this card MUST be
-- readable and the banner would otherwise sit on top of it.
local function cardPosition()
	local lifted = player:GetAttribute(TUTORIAL_ACTIVE_ATTRIBUTE) == true
	return UDim2.new(0.5, 0, 1, if lifted then -136 else -100)
end

--=============================================================================
-- What to say
--=============================================================================

-- The truck this player is currently DRIVING, or nil. Read off the humanoid
-- rather than tracked through Seated events, because this script has no other
-- reason to hold session state and a stale one would be worse than a lookup.
local function drivenVehicle()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not (seat and seat.Name == "DriverSeat") then
		return nil
	end
	local model = seat.Parent
	return (model and model:IsA("Model") and model.PrimaryPart) and model or nil
end

local trailersFolder = workspace:FindFirstChild(TrailerHitch.WorkspaceFolderName)

local function onTouch()
	return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
end

-- Whether the truck is stopped at (or just short of) any of these spaces.
local function nearAny(position, spaces)
	for _, space in spaces do
		if (space.Position - position).Magnitude <= AT_BAY_STUDS then
			return true
		end
	end
	return false
end

-- Looked up once each: the bays never move, and a GetDescendants on the depot
-- every frame to answer "is the truck near a bay" would be the most expensive
-- thing in this file by a distance.
local baySpaces = { [true] = {}, [false] = {} }
local function spacesFor(rig)
	if #baySpaces[rig] == 0 then
		baySpaces[rig] = Haulage.DepotSpaces(rig)
	end
	return baySpaces[rig]
end

-- What the card should say this frame, or nil for no card.
--
--   Title    the line
--   Detail   one smaller line under it, or nil
--   Tone     "Action" | "Warn" | "Info" - see the header
--   Action   what pressing the key sends, or nil when there is nothing to press
--   Standing true when this is a standing fact rather than a moment: it goes
--            to the legend, and only makes a card on touch
local function promptFor(tractorModel)
	local chassis = tractorModel.PrimaryPart
	local position = chassis.Position

	if TrailerHitch.GetHitchedTrailer(tractorModel) then
		-- Towing, and stopped in the ordinary loading bay: the other half of
		-- the "why is there no job list" playtest bug.
		if ParkGrade.IsStopped(chassis) and nearAny(position, spacesFor(false)) then
			return {
				Title = "Trailers load at the FREIGHT building",
				Detail = "This bay is for trucks - follow the FREIGHT marker.",
				Tone = "Warn",
			}
		end
		return { Title = "Drop trailer", Tone = "Action", Action = "unhitch", Standing = true }
	end

	trailersFolder = trailersFolder or workspace:FindFirstChild(TrailerHitch.WorkspaceFolderName)

	-- FindCandidate only returns a trailer that already passes the geometry
	-- test, so a near-miss would produce no prompt and no explanation at all.
	-- Fall back to the nearest trailer by raw distance purely so there is
	-- something to explain the failure about.
	local candidate = trailersFolder and TrailerHitch.FindCandidate(tractorModel, trailersFolder)
	if candidate then
		if not ParkGrade.IsStopped(chassis) then
			return { Title = "Stop to hitch up", Detail = "You are lined up - hold still.", Tone = "Warn" }
		end
		return { Title = "Hitch trailer", Detail = "Lined up and stopped.", Tone = "Action", Action = "hitch" }
	end

	local hitch = TrailerHitch.GetHitchAttachment(tractorModel)
	if not hitch then
		return nil
	end
	local nearest, nearestDistance = nil, math.huge
	for _, trailer in (if trailersFolder then trailersFolder:GetChildren() else {}) do
		local kingpin = trailer:IsA("Model") and TrailerHitch.GetKingpinAttachment(trailer)
		if
			kingpin
			and not trailer:GetAttribute(TrailerHitch.Attributes.Hitched)
			-- Somebody else's trailer is not a near miss, it is not an option.
			and TrailerHitch.CanUse(player.UserId, trailer)
		then
			local distance = (hitch.WorldPosition - kingpin.WorldPosition).Magnitude
			if distance < nearestDistance then
				nearest, nearestDistance = trailer, distance
			end
		end
	end
	-- Only once they are close enough that the trailer is plainly what they
	-- are aiming at. Twice the coupling distance is near enough to be trying
	-- and far enough that the card is not permanently on screen in a yard.
	if nearest and nearestDistance <= TrailerHitch.MaxDistance * 2 then
		local _, reason = TrailerHitch.CheckAlignment(tractorModel, nearest)
		if reason then
			return {
				Title = reason,
				Detail = "Back up straight to the front of the trailer.",
				Tone = "Warn",
			}
		end
	end

	-- Nothing to hitch here. In the yard without the trailer, it can be
	-- fetched: the way back for one that was dropped somewhere, jackknifed
	-- into an alley, or left behind when the truck was respawned.
	if trailersFolder and TrailerHitch.CanRecall(position, trailersFolder, player.UserId) then
		local owned = TrailerHitch.FindOwnedTrailer(trailersFolder, player.UserId)
		-- A recall is a NEW trailer, so a load on the old one goes with it -
		-- said before the key is pressed, not after.
		local units = owned and owned:GetAttribute(CargoLoad.Attributes.Units)
		local loaded = type(units) == "number" and units > 0
		return {
			Title = "Bring your trailer here",
			Detail = if loaded then "This cancels the job loaded on it." else "It will be parked in a free stall.",
			Tone = if loaded then "Warn" else "Action",
			Action = "recall",
		}
	end

	-- Bobtail, and parked somewhere a job is taken. Say why no list opened.
	if ParkGrade.IsStopped(chassis) then
		if nearAny(position, spacesFor(true)) then
			return {
				Title = "Hitch your trailer first",
				Detail = "Then back the TRAILER into this bay.",
				Tone = "Warn",
			}
		end
		if nearAny(position, spacesFor(false)) then
			return {
				Title = "This truck hauls trailers",
				Detail = "Pick yours up at the FREIGHT yard.",
				Tone = "Warn",
			}
		end
	end

	return nil
end

--=============================================================================
-- Acting
--=============================================================================

local function act()
	local tractorModel = drivenVehicle()
	if not (tractorModel and TrailerHitch.CanTow(tractorModel)) then
		return false
	end
	-- Decided at the moment of the press, from the same function that drew the
	-- card, so the key can never do something other than what the card said.
	-- The server re-derives all of it and is the only thing that decides;
	-- sending the intent rather than the target is what keeps it that way (see
	-- TrailerHitch.server.luau's header).
	local prompt = promptFor(tractorModel)
	if not (prompt and prompt.Action) then
		return false
	end
	hitchRequest:FireServer(prompt.Action)
	return true
end

ContextActionService:BindAction(HITCH_ACTION, function(_, inputState)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	return if act() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
end, false, HITCH_KEY)

card.Activated:Connect(act)

-- A line from the server: why a hitch was refused, or that a recalled trailer
-- has arrived. Held over the ordinary prompt for a few seconds, since it is
-- the answer to something the player just did.
local noticeText, noticeUntil = nil, 0

hitchRequest.OnClientEvent:Connect(function(kind, text)
	if kind == "notice" and type(text) == "string" then
		noticeText, noticeUntil = text, os.clock() + NOTICE_SECONDS
	end
end)

--=============================================================================
-- Drawing
--=============================================================================

-- What is on the card now, as one string, so the pop below fires when the
-- MESSAGE changes and not sixty times a second while it stands.
local shownKey = nil
local popScale = Instance.new("UIScale")
popScale.Parent = card

local function show(prompt)
	local touch = onTouch()
	local pressable = prompt.Action ~= nil
	local tone = TONES[prompt.Tone] or TONES.Info

	titleLabel.Text = prompt.Title
	detailLabel.Text = prompt.Detail or ""
	detailLabel.Visible = prompt.Detail ~= nil
	cardStroke.Color = tone

	keyGroup.Visible = pressable
	-- On touch there is no key to press: the cap says TAP, and the word
	-- PRESS in front of it would only be wrong.
	pressLabel.Visible = not touch
	keyFace.Text = if touch then "TAP" else HITCH_KEY.Name
	keyFace.TextSize = if touch then 14 else 18
	keyHolder.Size = UDim2.fromOffset(if touch then 52 else KEY_SIZE, KEY_SIZE + KEY_LIP)
	-- The press: the face drops onto its lip for a moment, over and over.
	local pressed = (os.clock() % PRESS_PERIOD) < PRESS_HOLD
	keyFace.Position = UDim2.fromOffset(0, if pressed then KEY_LIP - 1 else 0)
	dot.Visible = not pressable
	dot.BackgroundColor3 = tone
	-- Only looks like a button when it is one.
	card.BackgroundColor3 = if pressable and touch then CARD else PANEL
	card.Active = pressable

	card.Position = cardPosition()

	local key = prompt.Title .. "\0" .. (prompt.Detail or "") .. "\0" .. tostring(prompt.Action)
	if key ~= shownKey then
		shownKey = key
		-- A small pop on every new message: the card arriving (or changing
		-- its mind) is the event, and a reversing driver is looking at the
		-- mirrors, not at this.
		popScale.Scale = 0.9
		TweenService:Create(popScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	end
	gui.Enabled = true
end

local function hide()
	gui.Enabled = false
	shownKey = nil
end

RunService.Heartbeat:Connect(function()
	local tractorModel = drivenVehicle()
	if not (tractorModel and TrailerHitch.CanTow(tractorModel)) then
		hide()
		player:SetAttribute(TOW_HINT_ATTRIBUTE, nil)
		return
	end

	local prompt = promptFor(tractorModel)

	-- The standing fact goes to the legend whatever the card is showing.
	player:SetAttribute(TOW_HINT_ATTRIBUTE, if prompt and prompt.Standing then string.lower(prompt.Title) else nil)

	if noticeText and os.clock() < noticeUntil then
		show({ Title = noticeText, Tone = "Info" })
		return
	end
	noticeText = nil

	-- A standing fact makes no card on a keyboard - the legend has it. On
	-- touch there is no legend and no key, so the card is the button.
	if not prompt or (prompt.Standing and not onTouch()) then
		hide()
		return
	end
	show(prompt)
end)

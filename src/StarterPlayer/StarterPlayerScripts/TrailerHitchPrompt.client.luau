-- PROTOTYPE: articulated vehicles. The driver-facing half of hitching.
--
-- Deliberately the crudest possible UI - one line of text at the bottom of the
-- screen - because what is being prototyped is whether the APPROACH feels
-- good, and a polished prompt would only make it harder to tell a bad
-- tolerance from a pretty label. Replace wholesale with a CustomPrompt /
-- GuideMarker treatment once the tolerances are settled.
--
-- Shows, in order of what the driver needs to know:
--   * nothing at all, when they are not driving something with a hitch
--   * why the nearest trailer cannot be taken yet ("Not lined up", "Stop
--     completely first"), which is the feedback that teaches the manoeuvre
--   * the key to press, when it can
--   * the key to drop it, while towing
--
-- Showing the REASON rather than going quiet is the whole point: a prompt that
-- only appears once you are already correct tells the player nothing about how
-- to get there, and backing a trailer is exactly the manoeuvre where a driver
-- needs to know which of distance and angle they are still getting wrong.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)

local player = Players.LocalPlayer
local hitchRequest = ReplicatedStorage:WaitForChild("TrailerHitchRequest")

local HITCH_ACTION = "TrailerHitchToggle"
-- C for "couple". Every other letter within reach of WASD is already spoken
-- for while seated: F exits, L is the headlights, Q/E are the turn signals, T
-- is the third-person shop, Space is the handbrake, A/D steer - and H is the
-- HORN (VehicleHorn in RayCastSuspension.client.luau), which is what this was
-- originally and wrongly bound to. Check that list before rebinding this.
local HITCH_KEY = Enum.KeyCode.C

local gui = Instance.new("ScreenGui")
gui.Name = "TrailerHitchPrompt"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.new(0, 460, 0, 34)
label.Position = UDim2.new(0.5, -230, 1, -160)
label.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
label.BackgroundTransparency = 0.45
label.TextColor3 = Color3.fromRGB(255, 255, 255)
label.TextScaled = true
label.Font = Enum.Font.GothamMedium
label.Text = ""
label.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 6)
corner.Parent = label

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

local function onHitchKey(_, inputState)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	local tractorModel = drivenVehicle()
	if not tractorModel then
		return Enum.ContextActionResult.Pass
	end
	-- The server re-derives all of this itself and is the only thing that
	-- decides; sending the intent rather than the target is what keeps it that
	-- way (see TrailerHitch.server.luau's header).
	hitchRequest:FireServer(if TrailerHitch.GetHitchedTrailer(tractorModel) then "unhitch" else "hitch")
	return Enum.ContextActionResult.Sink
end

ContextActionService:BindAction(HITCH_ACTION, onHitchKey, false, HITCH_KEY)

-- Derived from the bound key rather than typed into each string, so rebinding
-- HITCH_KEY cannot leave the on-screen prompt telling the player to press a
-- key that does nothing - which is exactly what happened when this was moved
-- off the horn's H.
local KEY_LABEL = "[" .. HITCH_KEY.Name .. "] "

-- What the prompt should say this frame, or nil for "show nothing".
local function promptText(tractorModel)
	if TrailerHitch.GetHitchedTrailer(tractorModel) then
		return KEY_LABEL .. "Drop trailer"
	end

	trailersFolder = trailersFolder or workspace:FindFirstChild(TrailerHitch.WorkspaceFolderName)
	if not trailersFolder then
		return nil
	end

	-- FindCandidate only returns a trailer that already passes the geometry
	-- test, so a near-miss would produce no prompt and no explanation at all.
	-- Fall back to the nearest trailer by raw distance purely so there is
	-- something to explain the failure about.
	local candidate = TrailerHitch.FindCandidate(tractorModel, trailersFolder)
	if candidate then
		if not ParkGrade.IsStopped(tractorModel.PrimaryPart) then
			return "Stop completely to hitch up"
		end
		return KEY_LABEL .. "Hitch trailer"
	end

	local hitch = TrailerHitch.GetHitchAttachment(tractorModel)
	if not hitch then
		return nil
	end
	local nearest, nearestDistance = nil, math.huge
	for _, trailer in trailersFolder:GetChildren() do
		local kingpin = trailer:IsA("Model") and TrailerHitch.GetKingpinAttachment(trailer)
		if kingpin and not trailer:GetAttribute(TrailerHitch.Attributes.Hitched) then
			local distance = (hitch.WorldPosition - kingpin.WorldPosition).Magnitude
			if distance < nearestDistance then
				nearest, nearestDistance = trailer, distance
			end
		end
	end
	-- Only once they are close enough that the trailer is plainly what they
	-- are aiming at. Twice the coupling distance is near enough to be trying
	-- and far enough that the prompt is not permanently on screen in a yard.
	if not nearest or nearestDistance > TrailerHitch.MaxDistance * 2 then
		return nil
	end
	local _, reason = TrailerHitch.CheckAlignment(tractorModel, nearest)
	return reason
end

RunService.Heartbeat:Connect(function()
	local tractorModel = drivenVehicle()
	if not (tractorModel and TrailerHitch.CanTow(tractorModel)) then
		gui.Enabled = false
		return
	end

	local text = promptText(tractorModel)
	gui.Enabled = text ~= nil
	if text then
		label.Text = text
	end
end)

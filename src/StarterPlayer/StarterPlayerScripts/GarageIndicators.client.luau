-- The "In Garage" tag over other players' heads.
--
-- The garage view is entirely local (see GarageStage.luau): the player using
-- it sees their car parked in the bay and a camera orbiting it, and everyone
-- else sees them standing motionless at a terminal with an empty bay beside
-- them. This tag is the whole explanation, and a small advert - it is the one
-- sign to anybody walking past that cars in this game can be customised.
--
-- Driven by the InGarage attribute PlotManager sets on the Player (from the
-- SetGarageOpen remote), so every client agrees on it. Never drawn over the
-- local player's own head - they know where they are.

local Players = game:GetService("Players")

local IN_GARAGE_ATTRIBUTE = "InGarage"
local TAG_NAME = "GarageTag"
local MAX_DISTANCE = 90

local localPlayer = Players.LocalPlayer

local function buildTag(head)
	local gui = Instance.new("BillboardGui")
	gui.Name = TAG_NAME
	gui.Size = UDim2.fromOffset(136, 30)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = MAX_DISTANCE
	gui.LightInfluence = 0

	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = Color3.fromRGB(18, 20, 25)
	pill.BackgroundTransparency = 0.15
	pill.BorderSizePixel = 0
	pill.Parent = gui
	Instance.new("UICorner", pill).CornerRadius = UDim.new(1, 0)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(86, 200, 128)
	stroke.Thickness = 1.5
	stroke.Parent = pill

	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextSize = 14
	text.TextColor3 = Color3.fromRGB(236, 240, 247)
	text.Text = "\u{1F527} In Garage"
	text.Parent = pill

	gui.Adornee = head
	gui.Parent = head
	return gui
end

local function refresh(player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	if not head then
		return
	end
	local existing = head:FindFirstChild(TAG_NAME)
	local inGarage = player:GetAttribute(IN_GARAGE_ATTRIBUTE) == true
	if inGarage and not existing then
		buildTag(head)
	elseif not inGarage and existing then
		existing:Destroy()
	end
end

local function watch(player)
	if player == localPlayer then
		return
	end
	player:GetAttributeChangedSignal(IN_GARAGE_ATTRIBUTE):Connect(function()
		refresh(player)
	end)
	player.CharacterAdded:Connect(function(character)
		-- The head can arrive a moment after the character does.
		character:WaitForChild("Head", 10)
		refresh(player)
	end)
	refresh(player)
end

for _, player in Players:GetPlayers() do
	watch(player)
end
Players.PlayerAdded:Connect(watch)

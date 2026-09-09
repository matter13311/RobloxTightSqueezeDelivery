-- The "Loading Cargo..." overlay shown while crates are being placed on the
-- truck you are sitting in.
--
-- WHY IT EXISTS. The crates go on one at a time, behind the player, and the
-- player is looking forward out of the windscreen (see DeliveryConfig.Loading).
-- The staggering, the thuds and the suspension dip are the real message - this
-- panel is the caption on it. It says three things a child can read at a
-- glance: something is happening, it is happening to YOUR cargo, and it is
-- nearly done. Without it the immobilised truck reads as the game being stuck.
--
-- It is deliberately a caption and not the event. If this file were deleted
-- the loading sequence would still work and still communicate; nothing here is
-- load-bearing for the mechanic.
--
-- NOTHING HERE IS A SECURITY BOUNDARY, and nothing here drives the game state.
-- CargoManager owns the sequence and publishes its progress as two attributes
-- on the vehicle Model (CargoLoad.Attributes.LoadingPlaced counting up,
-- CargoUnits as the total). This script only reads them - the same split
-- DeliveryHud's header describes, and the reason a rejoining or spectating
-- client needs no replication code of its own.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
local CargoTypes = require(ReplicatedStorage.Modules.Delivery.CargoTypes)
local ResponsiveScale = require(ReplicatedStorage.Modules.UI.ResponsiveScale)

local player = Players.LocalPlayer

-- Matches DeliveryHud / PlotTerminal / VehicleDashboard, so this reads as the
-- same UI system rather than a second one bolted on.
local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local SLOT = Color3.fromRGB(28, 31, 38)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local ACCENT = Color3.fromRGB(86, 200, 128)

-- The panel is designed against these pixel sizes and then scaled to fit by
-- ResponsiveScale, exactly like every other panel in the game.
local PANEL_WIDTH = 360
local PANEL_HEIGHT = 150
-- Beyond this many crates the pips stop being individually readable and the
-- bar underneath is doing all the work anyway, so the row is dropped rather
-- than squeezed into slivers.
local MAX_PIPS = 12
-- Pulled out because popTitle animates back to it - two places holding the
-- same literal is exactly how a pop ends up settling at the wrong size.
local TITLE_TEXT_SIZE = 22

--=============================================================================
-- The panel
--=============================================================================

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = instance
	return c
end

local gui = Instance.new("ScreenGui")
gui.Name = "CargoLoadingHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

-- Middle of the screen, on purpose. The truck is held still for the whole time
-- this is up, so there is nothing behind the panel the player needs to see,
-- and the centre is the one place a distracted seven-year-old cannot miss it.
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT)
panel.BackgroundColor3 = PANEL
panel.BackgroundTransparency = 0.1
panel.BorderSizePixel = 0
panel.Parent = gui
corner(panel, 12)

local edge = Instance.new("UIStroke")
edge.Color = PANEL_EDGE
edge.Thickness = 1
edge.Parent = panel

ResponsiveScale.Fit(panel)

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Position = UDim2.fromOffset(0, 16)
title.Size = UDim2.new(1, 0, 0, 26)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = TITLE_TEXT_SIZE
title.TextColor3 = BRIGHT_TEXT
title.Text = "Loading Cargo"
title.Parent = panel

-- One pip per crate, laid out left to right and filled as each one lands. A
-- count of boxes rather than a percentage, because "four of my six boxes are
-- on" is a sentence a child reads off this instantly and "67%" is not.
local pipRow = Instance.new("Frame")
pipRow.Name = "Pips"
pipRow.Position = UDim2.fromOffset(0, 52)
pipRow.Size = UDim2.new(1, 0, 0, 26)
pipRow.BackgroundTransparency = 1
pipRow.Parent = panel

local pipLayout = Instance.new("UIListLayout")
pipLayout.FillDirection = Enum.FillDirection.Horizontal
pipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
pipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
pipLayout.Padding = UDim.new(0, 6)
pipLayout.SortOrder = Enum.SortOrder.LayoutOrder
pipLayout.Parent = pipRow

-- The same progress again, as one continuous bar. Redundant with the pips by
-- design: the bar is what still communicates on a load too big to draw pips
-- for, and it is the part that MOVES between crates rather than jumping, which
-- is what makes the wait feel like a wait rather than a freeze.
local barTrack = Instance.new("Frame")
barTrack.Name = "BarTrack"
barTrack.AnchorPoint = Vector2.new(0.5, 0)
barTrack.Position = UDim2.new(0.5, 0, 0, 88)
barTrack.Size = UDim2.fromOffset(PANEL_WIDTH - 48, 8)
barTrack.BackgroundColor3 = SLOT
barTrack.BorderSizePixel = 0
barTrack.Parent = panel
corner(barTrack, 4)

local barFill = Instance.new("Frame")
barFill.Name = "BarFill"
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = ACCENT
barFill.BorderSizePixel = 0
barFill.Parent = barTrack
corner(barFill, 4)

-- Wrapped, and given two lines of room, because the finished-state sentence is
-- the longest thing this panel ever says and it is the one that matters most.
-- A caption that runs off the edge of the panel is a caption nobody reads.
local caption = Instance.new("TextLabel")
caption.Name = "Caption"
caption.AnchorPoint = Vector2.new(0.5, 0)
caption.Position = UDim2.new(0.5, 0, 0, 104)
caption.Size = UDim2.new(1, -32, 0, 36)
caption.BackgroundTransparency = 1
caption.Font = Enum.Font.GothamMedium
caption.TextSize = 13
caption.TextWrapped = true
caption.TextColor3 = DIM_TEXT
caption.Text = "Hold on - the boxes are going in the back!"
caption.Parent = panel

--=============================================================================
-- Drawing progress
--=============================================================================

local pips = {}

local function clearPips()
	for _, pip in pips do
		pip:Destroy()
	end
	table.clear(pips)
end

-- Rebuilt whenever the load being shown changes, not every time a crate lands:
-- the pips are a fixed row of `total` slots, and filling one is a colour
-- change, not a new instance.
local function buildPips(total, color)
	clearPips()
	if total > MAX_PIPS then
		pipRow.Visible = false
		return
	end
	pipRow.Visible = true

	for index = 1, total do
		local pip = Instance.new("Frame")
		pip.Name = "Pip" .. index
		pip.LayoutOrder = index
		pip.Size = UDim2.fromOffset(20, 20)
		pip.BackgroundColor3 = SLOT
		pip.BorderSizePixel = 0
		pip.Parent = pipRow
		corner(pip, 4)

		local stroke = Instance.new("UIStroke")
		stroke.Color = color
		stroke.Transparency = 0.65
		stroke.Thickness = 1
		stroke.Parent = pip

		pips[index] = pip
	end
end

-- Filled pips are drawn in the cargo type's OWN colour, the same one the real
-- crates and the contract board's preview use, so the row on screen and the
-- stack appearing on the bed are visibly the same objects.
local function paintPips(placed, color)
	for index, pip in pips do
		local filled = index <= placed
		pip.BackgroundColor3 = if filled then color else SLOT
		local stroke = pip:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = if filled then 0 else 0.65
		end
	end

	-- A small pop on the pip that just landed, timed to the thud the server
	-- plays with it. Nothing else on screen moves at that instant, so this is
	-- what ties the sound to the panel.
	local landed = pips[placed]
	if landed then
		landed.Size = UDim2.fromOffset(26, 26)
		TweenService:Create(landed, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.fromOffset(20, 20),
		}):Play()
	end
end

-- One overshoot on the title when the load finishes. Done on TextSize rather
-- than on the panel's Size because ResponsiveScale measured that Size once, at
-- startup, to work out its UIScale - animating it would be animating the thing
-- another module is using as its fixed reference.
local function popTitle()
	title.TextSize = TITLE_TEXT_SIZE + 8
	TweenService:Create(title, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		TextSize = TITLE_TEXT_SIZE,
	}):Play()
end

local shownCar, shownTotal, shownColor = nil, 0, BRIGHT_TEXT
-- Whether the last draw was the finished state, so the pop above fires on the
-- transition into it rather than on every redraw while it is up.
local wasDone = false

local function refresh(carModel)
	if not carModel or not CargoLoad.IsLoading(carModel) then
		gui.Enabled = false
		shownCar = nil
		-- Cleared with the panel, or the next load at the same dock would come
		-- up already "done" as far as the pop is concerned and skip it.
		wasDone = false
		return
	end

	local placed = carModel:GetAttribute(CargoLoad.Attributes.LoadingPlaced) or 0
	local total = carModel:GetAttribute(CargoLoad.Attributes.Units) or 0
	if total <= 0 then
		gui.Enabled = false
		shownCar = nil
		wasDone = false
		return
	end

	local cargoType = CargoTypes.GetOrDefault(carModel:GetAttribute(CargoLoad.Attributes.TypeId))

	-- Rebuild the row only when the load itself changed - otherwise a player
	-- who reloads at the dock gets a flicker on every single crate.
	if carModel ~= shownCar or total ~= shownTotal or cargoType.Color ~= shownColor then
		shownCar, shownTotal, shownColor = carModel, total, cargoType.Color
		buildPips(total, cargoType.Color)
	end

	-- The last crate is on but the load is still "in progress" for another
	-- CompleteHoldSeconds, and the truck is still held. That beat is the only
	-- moment in the whole run where the player is stationary, has nothing to
	-- do, and is definitely reading the screen - so it is where the one thing
	-- they actually need to know goes.
	--
	-- The panel CHANGES CHARACTER for it rather than just swapping the text:
	-- green instead of white, a different sentence, and a pop on the title. A
	-- child skim-reading gets "the state changed and it went green" from the
	-- colour alone, before reading a word of it.
	local done = placed >= total
	if done then
		title.Text = "Cargo Added!"
		title.TextColor3 = ACCENT
		caption.Text = "Your car is heavy now drive carefully!"
		caption.TextColor3 = BRIGHT_TEXT
		edge.Color = ACCENT
		-- Guarded, because refresh can run again on the same completed state
		-- (a passenger sitting down during the hold, say) and the pop should
		-- fire on the transition, not on every redraw.
		if not wasDone then
			popTitle()
		end
	else
		title.Text = string.format("Loading %s  %d/%d", cargoType.DisplayName, placed, total)
		title.TextColor3 = BRIGHT_TEXT
		caption.Text = "Hold on - the boxes are going in the back!"
		caption.TextColor3 = DIM_TEXT
		edge.Color = PANEL_EDGE
	end
	wasDone = done
	paintPips(placed, cargoType.Color)

	-- Tweened rather than set, and over most of one crate's worth of time, so
	-- the bar is still visibly creeping when the next crate lands - it is the
	-- only thing on the panel that moves during the gap between thuds, and at
	-- SecondsPerCrate = 0.8 that gap is long enough to feel dead without it.
	TweenService:Create(barFill, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(placed / total, 1),
	}):Play()

	gui.Enabled = true
end

--=============================================================================
-- Which truck we are watching
--=============================================================================

-- Only ever the car the LOCAL player is sitting in. A passenger sees it too:
-- they are in the truck, they hear the crates land, and leaving them staring
-- at an immobilised vehicle with no explanation would be the exact confusion
-- this panel exists to remove.
local watchConnections = {}

local function watch(carModel)
	for _, connection in watchConnections do
		connection:Disconnect()
	end
	table.clear(watchConnections)

	if not carModel then
		refresh(nil)
		return
	end

	-- LoadingPlaced alone is enough to drive the whole panel: CargoManager
	-- writes it once when a load starts, once per crate, and clears it at the
	-- end, so every state this UI has follows from a change to it.
	table.insert(
		watchConnections,
		carModel:GetAttributeChangedSignal(CargoLoad.Attributes.LoadingPlaced):Connect(function()
			refresh(carModel)
		end)
	)
	-- A truck despawned mid-load writes no attribute, so without this the panel
	-- would sit on screen forever. AncestryChanged rather than Destroying,
	-- because a vehicle being re-parented out of Workspace is the same thing
	-- from here and does not necessarily end in a Destroy.
	table.insert(
		watchConnections,
		carModel.AncestryChanged:Connect(function()
			if carModel.Parent == nil then
				watch(nil)
			end
		end)
	)

	-- Covers sitting down in a truck that is already mid-load.
	refresh(carModel)
end

local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")

	humanoid.Seated:Connect(function(seated, seatPart)
		if not (seated and seatPart and seatPart:FindFirstAncestor("Vehicles")) then
			watch(nil)
			return
		end
		-- Any vehicle seat, driver or passenger - see the note above.
		watch(seatPart.Parent)
	end)

	humanoid.Died:Connect(function()
		watch(nil)
	end)
end

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

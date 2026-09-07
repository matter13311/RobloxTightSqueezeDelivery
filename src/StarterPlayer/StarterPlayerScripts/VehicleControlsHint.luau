-- A small always-on control legend shown only in first person. In third
-- person the dashboard's own status line already carries the drive/brake/
-- handbrake/exit hints (see VehicleDashboard.HintText), but in first person
-- that dashboard is hidden entirely (you're looking through the windshield
-- at the real one), so a first-time player has nothing on screen telling
-- them how to get back out of the seat.
--
-- Built after a playtest where a child kept mashing SPACE (handbrake, not
-- exit) trying to leave the car, and never noticed F was the way out. So F
-- gets its own bright, bigger row up top; the secondary controls (blinkers,
-- horn, lights) are listed underneath in a quieter, smaller row so the whole
-- thing doesn't read as "one more wall of keybinds" - just "here's how to
-- get out" first, everything else second.

local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)
local EXIT_COLOR = Color3.fromRGB(232, 138, 60)

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness or 1
	s.Parent = parent
	return s
end

local function newLabel(parent, name, position, size, text, textSize, color, font)
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextSize = textSize
	label.TextColor3 = color
	label.Font = font or Enum.Font.GothamMedium
	label.Parent = parent
	return label
end

local ControlsHint = {}
ControlsHint.__index = ControlsHint

function ControlsHint.new(player)
	local self = setmetatable({}, ControlsHint)

	local gui = Instance.new("ScreenGui")
	gui.Name = "VehicleControlsHint"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	self.Gui = gui

	-- Top-centre: the one strip of screen first person doesn't already use
	-- for something else. A single slim row - just tall enough for one line
	-- of text - so it reads as a passing reminder, not a panel.
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 12)
	panel.Size = UDim2.fromOffset(430, 26)
	panel.BackgroundColor3 = PANEL
	panel.BackgroundTransparency = 0.15
	panel.BorderSizePixel = 0
	panel.Parent = gui
	corner(panel, 8)
	stroke(panel, PANEL_EDGE)
	self.Panel = panel

	-- One row, all the controls, built from RichText so "F exit" can carry
	-- its own accent colour while sitting inline with the rest rather than
	-- getting its own row. Everything else stays dim - the colour contrast
	-- alone is what makes F the one your eye catches first.
	local hexEXIT = EXIT_COLOR:ToHex()
	local hexDIM = DIM_TEXT:ToHex()
	local row = newLabel(panel, "Hint", UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), "", 13, DIM_TEXT, Enum.Font.GothamMedium)
	row.RichText = true
	row.Text = string.format(
		'<font color="#%s"><b>F</b> exit</font>   <font color="#%s">Space handbrake   Q/E blinkers   H honk   L lights</font>',
		hexEXIT,
		hexDIM
	)
	row.TextXAlignment = Enum.TextXAlignment.Center
	self.HintLabel = row

	self.Visible = false
	panel.Visible = false

	return self
end

-- Shown only in first person - in third person the dashboard's own status
-- line already carries the same hints, and stacking both on screen at once
-- would be the "too busy" clutter this HUD is trying to avoid.
function ControlsHint:SetVisible(visible)
	if self.Visible == visible then
		return
	end
	self.Visible = visible
	self.Panel.Visible = visible
end

function ControlsHint:Destroy()
	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end
end

return ControlsHint

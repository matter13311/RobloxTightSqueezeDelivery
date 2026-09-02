-- The in-car HUD: which gear you're in, how fast you're going, where the
-- revs are, and whether the handbrake is on. Built entirely in code (no
-- pre-made GUI to keep in sync in Studio) and created/destroyed with the
-- drive session, so nothing lingers on screen after you get out.
--
-- Purely a display. It reads gearbox state and never changes it - all the
-- input handling lives in RayCastSuspension.client.luau.

local Gearbox = require(game:GetService("ReplicatedStorage").Modules.Vehicles.Gearbox)

local Dashboard = {}
Dashboard.__index = Dashboard

-- studs/s -> mph. A Roblox stud is about 0.28 m, so 1 stud/s is
-- 0.28 * 2.23694 mph. Only ever used for the readout - nothing in the
-- physics knows or cares about mph.
local MPH_PER_STUD = 0.6263

local PANEL = Color3.fromRGB(18, 20, 25)
local PANEL_EDGE = Color3.fromRGB(52, 58, 70)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local BRIGHT_TEXT = Color3.fromRGB(236, 240, 247)

-- One colour per selector position, used for both the active pill and the
-- big gear readout, so the HUD's dominant colour tells you what the car will
-- do when you touch the gas without reading a single character.
local SELECTOR_COLOR = {
	R = Color3.fromRGB(232, 138, 60),
	D = Color3.fromRGB(86, 200, 128),
}

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

local function newFrame(parent, name, position, size, color)
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Position = position
	frame.Size = size
	frame.BackgroundColor3 = color or PANEL
	frame.BorderSizePixel = 0
	frame.Parent = parent
	return frame
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

function Dashboard.new(player)
	local self = setmetatable({}, Dashboard)

	local gui = Instance.new("ScreenGui")
	gui.Name = "VehicleDashboard"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	self.Gui = gui

	local panel = newFrame(gui, "Panel", UDim2.new(0.5, 0, 1, -28), UDim2.fromOffset(336, 140))
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.BackgroundTransparency = 0.08
	corner(panel, 12)
	stroke(panel, PANEL_EDGE)

	-- Big current-gear readout. In D this is the automatic box's gear NUMBER,
	-- not the letter - the letter is already obvious from the lit pill below,
	-- and the number is the part that's actually changing while you drive.
	local gearBox = newFrame(panel, "GearBox", UDim2.fromOffset(14, 14), UDim2.fromOffset(88, 88), Color3.fromRGB(28, 31, 38))
	corner(gearBox, 10)
	local gearStroke = stroke(gearBox, SELECTOR_COLOR.D, 2)
	self.GearStroke = gearStroke

	local gearLabel = newLabel(gearBox, "Gear", UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), "1", 46, SELECTOR_COLOR.D, Enum.Font.GothamBold)
	self.GearLabel = gearLabel

	-- Direction pills: R and D. The player never selects these - the car
	-- picks its own direction from the keys - so this is a readout, not a
	-- control. It still earns its space: knowing which way the truck is about
	-- to move before you touch a key is the whole point of showing it.
	self.Pills = {}
	local pillGap = 8
	local pillWidth = (206 - pillGap * (#Gearbox.SelectorOrder - 1)) / #Gearbox.SelectorOrder
	for index, name in Gearbox.SelectorOrder do
		local x = 116 + (index - 1) * (pillWidth + pillGap)
		local pill = newFrame(panel, "Pill" .. name, UDim2.fromOffset(x, 14), UDim2.fromOffset(pillWidth, 30), Color3.fromRGB(28, 31, 38))
		corner(pill, 8)
		local pillStroke = stroke(pill, PANEL_EDGE)
		local label = newLabel(pill, "Text", UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), name, 17, DIM_TEXT, Enum.Font.GothamBold)
		self.Pills[name] = { Frame = pill, Stroke = pillStroke, Label = label }
	end

	-- Tachometer. Deliberately just a bar rather than a dial: the only thing
	-- it needs to communicate is "the revs are climbing, and they just fell
	-- back because the box shifted", which a bar does at a glance.
	local rpmTrack = newFrame(panel, "RpmTrack", UDim2.fromOffset(116, 54), UDim2.fromOffset(206, 8), Color3.fromRGB(34, 38, 46))
	corner(rpmTrack, 4)
	local rpmFill = newFrame(rpmTrack, "Fill", UDim2.fromOffset(0, 0), UDim2.new(0, 0, 1, 0), SELECTOR_COLOR.D)
	corner(rpmFill, 4)
	self.RpmFill = rpmFill

	local speedLabel = newLabel(panel, "Speed", UDim2.fromOffset(116, 66), UDim2.fromOffset(150, 36), "0", 30, BRIGHT_TEXT, Enum.Font.GothamBold)
	speedLabel.TextXAlignment = Enum.TextXAlignment.Left
	self.SpeedLabel = speedLabel

	local unitLabel = newLabel(panel, "Unit", UDim2.fromOffset(116, 66), UDim2.fromOffset(206, 36), "MPH", 13, DIM_TEXT)
	unitLabel.TextXAlignment = Enum.TextXAlignment.Right

	-- Bottom strip does double duty: the control hints while you're driving
	-- normally, and a loud handbrake warning the moment it matters. They can
	-- share the space because you don't need to be told which key shifts gear
	-- at the exact moment you're sideways with the handbrake up.
	local status = newLabel(panel, "Status", UDim2.fromOffset(14, 108), UDim2.fromOffset(308, 20), "", 12, DIM_TEXT)
	self.StatusLabel = status

	local handbrakeBadge = newFrame(panel, "HandbrakeBadge", UDim2.fromOffset(14, 108), UDim2.fromOffset(308, 22), Color3.fromRGB(214, 66, 62))
	corner(handbrakeBadge, 6)
	handbrakeBadge.Visible = false
	newLabel(handbrakeBadge, "Text", UDim2.fromOffset(0, 0), UDim2.fromScale(1, 1), "HANDBRAKE", 12, Color3.fromRGB(255, 236, 236), Enum.Font.GothamBold)
	self.HandbrakeBadge = handbrakeBadge

	self.HintText = "W  drive      S  brake, hold to reverse      SPACE  handbrake      F  exit"
	status.Text = self.HintText

	return self
end

function Dashboard:Update(gearboxState, speedStuds, handbrakeOn)
	local selector = gearboxState.Selector
	local color = SELECTOR_COLOR[selector]

	self.GearLabel.Text = Gearbox.DisplayGear(gearboxState)
	self.GearLabel.TextColor3 = color
	self.GearStroke.Color = color
	-- Dim the readout for the length of the shift, so the gap in power has a
	-- matching visual rather than the number just silently swapping over.
	self.GearLabel.TextTransparency = if gearboxState.ShiftTimeRemaining > 0 then 0.55 else 0

	-- While the player is holding the opposite key at a standstill, the
	-- direction they're heading for lights up in proportion to how far
	-- through AutoReverseDelay they are. It's the only feedback that the hold
	-- is doing anything at all - without it, half a second of apparently
	-- nothing happening reads as the car being stuck, which is exactly the
	-- confusion the automatic box exists to avoid.
	local pending = gearboxState.DirectionHoldProgress or 0
	for name, pill in self.Pills do
		local active = name == selector
		local glow = if active then 1 elseif pending > 0 then pending else 0
		pill.Stroke.Color = PANEL_EDGE:Lerp(SELECTOR_COLOR[name], glow)
		pill.Label.TextColor3 = DIM_TEXT:Lerp(SELECTOR_COLOR[name], glow)
		pill.Frame.BackgroundColor3 = Color3.fromRGB(28, 31, 38):Lerp(Color3.fromRGB(38, 43, 52), glow)
	end

	local rpm = math.clamp(gearboxState.Rpm, 0, 1)
	self.RpmFill.Size = UDim2.new(rpm, 0, 1, 0)
	-- Green through most of the range, amber approaching the top of the gear,
	-- red at the point the box is about to shift.
	self.RpmFill.BackgroundColor3 = if rpm > 0.9
		then Color3.fromRGB(224, 76, 72)
		elseif rpm > 0.72 then Color3.fromRGB(232, 176, 64)
		else SELECTOR_COLOR.D

	self.SpeedLabel.Text = tostring(math.floor(speedStuds * MPH_PER_STUD + 0.5))

	self.HandbrakeBadge.Visible = handbrakeOn == true
	self.StatusLabel.Visible = not self.HandbrakeBadge.Visible
end

function Dashboard:Destroy()
	if self.Gui then
		self.Gui:Destroy()
		self.Gui = nil
	end
end

return Dashboard

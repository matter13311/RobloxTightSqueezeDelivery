-- Marks the local player's claimed plot so it can be found again in a lane of
-- identical terminals. Purely client-side: reads the OwnerUserId attribute that
-- PlotOwnership already replicates, so nothing is added on the server.
--
-- Deliberately NOT always on screen (the HUD already carries depot/cargo
-- indicators): the cues fade in only when the camera is within SHOW_DISTANCE of
-- the terminal - i.e. when you are in the lane looking for it - and fade out
-- again as you leave. They are a Highlight outline (occluded normally, so it
-- never shows through walls) and a small "Your garage" tag.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)

local player = Players.LocalPlayer
local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")

local MARK_COLOR = Color3.fromRGB(80, 255, 140)
local TAG_HEIGHT_STUDS = 7
local SHOW_DISTANCE = 110 -- fully visible inside this many studs
local FADE_BAND = 40 -- ...and fades out over the next this-many
local FADE_SPEED = 4 -- alpha per second

local marker -- { Plot, Highlight, Gui, Label, Adornee } or nil

local function clearMarker()
	if marker then
		marker.Highlight:Destroy()
		marker.Gui:Destroy()
		marker = nil
	end
end

local function applyAlpha(m, alpha)
	m.Highlight.OutlineTransparency = 1 - alpha
	m.Label.TextTransparency = 1 - alpha
	m.Label.BackgroundTransparency = 1 - alpha * 0.6
	m.Stroke.Transparency = 1 - alpha
	m.Gui.Enabled = alpha > 0
end

local function buildMarker(plotModel)
	local terminal = plotModel:FindFirstChild("Terminal")
	if not terminal then
		return false
	end
	local adornee = terminal:FindFirstChild("Screen") or terminal:FindFirstChildWhichIsA("BasePart", true)
	if not adornee then
		return false
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "MyPlotHighlight"
	highlight.Adornee = terminal
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = MARK_COLOR
	highlight.FillTransparency = 1
	highlight.OutlineColor = MARK_COLOR
	highlight.OutlineTransparency = 1
	highlight.Parent = terminal

	local gui = Instance.new("BillboardGui")
	gui.Name = "MyPlotTag"
	gui.Adornee = adornee
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(96, 24)
	gui.StudsOffsetWorldSpace = Vector3.new(0, TAG_HEIGHT_STUDS, 0)
	gui.MaxDistance = SHOW_DISTANCE + FADE_BAND
	gui.ResetOnSpawn = false
	gui.Parent = adornee

	local label = Instance.new("TextLabel")
	label.BackgroundColor3 = Color3.fromRGB(10, 30, 18)
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.Gotham
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = 1
	label.TextSize = 13
	label.Text = "Your garage"
	label.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Color = MARK_COLOR
	stroke.Thickness = 1
	stroke.Transparency = 1
	stroke.Parent = label

	marker = { Plot = plotModel, Highlight = highlight, Gui = gui, Label = label, Adornee = adornee, Alpha = 0, Stroke = stroke }
	applyAlpha(marker, 0)
	return true
end

local function findMyPlot()
	for _, plotModel in VehiclePlotsFolder:GetChildren() do
		if PlotOwnership.GetOwnerUserId(plotModel) == player.UserId then
			return plotModel
		end
	end
	return nil
end

local function refresh()
	local mine = findMyPlot()
	if marker and marker.Plot ~= mine then
		clearMarker()
	end
	if mine and not marker then
		buildMarker(mine)
	end
end

local function watchPlot(plotModel)
	plotModel:GetAttributeChangedSignal(PlotOwnership.OWNER_USERID_ATTRIBUTE):Connect(refresh)
	plotModel.ChildAdded:Connect(function()
		if not marker then
			refresh() -- Terminal may replicate after the attribute
		end
	end)
end

for _, plotModel in VehiclePlotsFolder:GetChildren() do
	watchPlot(plotModel)
end
VehiclePlotsFolder.ChildAdded:Connect(function(plotModel)
	watchPlot(plotModel)
	refresh()
end)
VehiclePlotsFolder.ChildRemoved:Connect(refresh)

RunService.RenderStepped:Connect(function(deltaTime)
	if not marker then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local distance = (camera.CFrame.Position - marker.Adornee.Position).Magnitude
	local target = if distance <= SHOW_DISTANCE then 1 else 0
	local step = FADE_SPEED * deltaTime
	local alpha = marker.Alpha
	alpha = if target > alpha then math.min(alpha + step, target) else math.max(alpha - step, target)
	if alpha ~= marker.Alpha then
		marker.Alpha = alpha
		applyAlpha(marker, alpha)
	end
end)

refresh()

-- The physical in-cab instrument cluster: the speedometer/tachometer needles
-- and the two blinker arrow indicators on the dash. Same lazy per-vehicle rig
-- pattern as VehicleLights.luau - built from parts already sitting under the
-- car's Dashboard folder the first time each is seen, then purely event/frame
-- driven after that.
--
-- Two different sources of truth, same split as VehicleLights:
--   * Needle rotation (UpdateGauges) is continuous driving telemetry. Speed
--     comes straight off the chassis' own replicated AssemblyLinearVelocity -
--     unlike Rpm there's no separate "Net" copy of it, because velocity is
--     already an ordinary replicated physics property every client sees for
--     any unanchored car, driven or not. Rpm has no such property (it's a
--     gearbox concept, not a physics one), so the caller hands in whatever it
--     already resolved for the engine sound/exhaust - live DriveRpm for the
--     client's own car, replicated NetRpm for everyone else's.
--   * The blinker arrows are a discrete switch position, same as the actual
--     turn signal lights - they react to the server-authoritative TurnSignal
--     Attribute directly, with their own blink loop kept in lockstep with
--     VehicleLights' timing so the dash and the exterior lights flash together.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local VehicleDashboardGauges = {}

-- ===== Gauge needles =====

local NEEDLE_NAMES = { "SpeedNeedle", "RPMNeedle" }

local gaugeRigs = {} -- [vehicle] = { SpeedNeedle = {Part, Weld, BaseC0}, RPMNeedle = {...} }

local function buildNeedleEntry(part)
	local weld = part:FindFirstChild(part.Name .. "Weld")
	local baseC0 = weld and weld:GetAttribute("BaseC0")
	if not baseC0 then
		return nil -- server hasn't finished rigging this needle yet - try again next frame
	end
	return { Part = part, Weld = weld, BaseC0 = baseC0 }
end

local function getGaugeRig(vehicle)
	local rig = gaugeRigs[vehicle]
	if rig then
		return rig
	end

	rig = {}
	local sawAny = false
	for _, name in NEEDLE_NAMES do
		local part = VehiclePhysics.GetDashboardPart(vehicle, name)
		if part then
			local entry = buildNeedleEntry(part)
			if not entry then
				return nil -- weld not ready yet
			end
			rig[name] = entry
			sawAny = true
		end
	end

	if not sawAny then
		return nil -- car has no gauge needles at all, which is fine
	end

	gaugeRigs[vehicle] = rig
	return rig
end

-- Builds the gauge rig the first time this car is seen. Same
-- call-it-whenever-convenient, no-op-after-the-first-success contract as
-- VehicleLights.EnsureHeadlights.
function VehicleDashboardGauges.EnsureGauges(vehicle)
	getGaugeRig(vehicle)
end

local function updateNeedle(entry, axisConfig, value, maxValue, minAngle, maxAngle, invert)
	-- Clamped rather than left to run past the painted min/max marks - a
	-- needle that could swing past its own gauge face would read as broken
	-- the first time a car exceeded MaxSpeed (going downhill, say).
	local t = math.clamp(value / maxValue, 0, 1)
	local direction = if invert then -1 else 1
	local angle = math.rad((minAngle + t * (maxAngle - minAngle)) * direction)
	entry.Weld.C0 = entry.BaseC0 * CFrame.fromAxisAngle(VehiclePhysics.AxisFromConfig(axisConfig, entry.Part), angle)
end

-- `speed` is studs/s (magnitude, always known - see the module comment),
-- `rpm` is 0-1. Call every frame for every visible, unanchored vehicle.
function VehicleDashboardGauges.UpdateGauges(vehicle, config, speed, rpm)
	local rig = getGaugeRig(vehicle)
	if not rig then
		return
	end

	if rig.SpeedNeedle then
		updateNeedle(rig.SpeedNeedle, config.SpeedNeedleAxis, speed, config.MaxSpeed, config.SpeedNeedleMinAngle, config.SpeedNeedleMaxAngle, config.SpeedNeedleInvert)
	end
	if rig.RPMNeedle then
		updateNeedle(rig.RPMNeedle, config.RPMNeedleAxis, rpm, 1, config.RPMNeedleMinAngle, config.RPMNeedleMaxAngle, config.RPMNeedleInvert)
	end
end

-- ===== Blinker indicators =====

-- Same blink cadence as VehicleLights' turn signal lights, so the dash arrow
-- and the exterior lights flash in lockstep rather than visibly out of phase.
local BLINK_ON_TIME = 0.35
local BLINK_OFF_TIME = 0.35

local BLINKER_SIDES = { "Left", "Right" }
local ARROW_TEXT = { Left = "<", Right = ">" }
local ARROW_COLOR = Color3.fromRGB(60, 220, 90)

local blinkerRigs = {} -- [vehicle] = { Left = {Part, Label}, Right = {...}, ActiveSide, BlinkGeneration, Connection }

local function buildArrowGui(part, text)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "BlinkerGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Name = "Arrow"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = ARROW_COLOR
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Visible = false
	label.Parent = gui

	return label
end

local function setArrowLit(entry, on)
	entry.Label.Visible = on
end

-- Same generation-counter trick as VehicleLights.runBlinkLoop: switching sides
-- or turning the signal off bumps BlinkGeneration, which is this loop's only
-- cue to stop.
local function runBlinkLoop(rig, side, generation)
	local entry = rig[side]
	task.spawn(function()
		while rig.BlinkGeneration == generation do
			setArrowLit(entry, true)
			task.wait(BLINK_ON_TIME)
			if rig.BlinkGeneration ~= generation then
				break
			end
			setArrowLit(entry, false)
			task.wait(BLINK_OFF_TIME)
		end
		setArrowLit(entry, false)
	end)
end

local function onTurnSignalChanged(vehicle, rig)
	local active = vehicle:GetAttribute("TurnSignal")
	if active == rig.ActiveSide then
		return
	end

	local previous = rig.ActiveSide
	rig.ActiveSide = active
	rig.BlinkGeneration += 1

	if previous and rig[previous] then
		setArrowLit(rig[previous], false)
	end

	if active == "Left" or active == "Right" then
		runBlinkLoop(rig, active, rig.BlinkGeneration)
	end
end

local function getBlinkerRig(vehicle)
	local rig = blinkerRigs[vehicle]
	if rig then
		return rig
	end

	local parts = {}
	for _, side in BLINKER_SIDES do
		local part = VehiclePhysics.GetDashboardPart(vehicle, "Blinker" .. side)
		if not part then
			return nil -- car has no dashboard blinker indicators, which is fine
		end
		parts[side] = part
	end

	rig = { ActiveSide = nil, BlinkGeneration = 0 }
	for _, side in BLINKER_SIDES do
		local part = parts[side]
		local label = part:FindFirstChild("BlinkerGui") and part.BlinkerGui:FindFirstChild("Arrow")
		if not label then
			label = buildArrowGui(part, ARROW_TEXT[side])
		end
		rig[side] = { Part = part, Label = label }
	end

	blinkerRigs[vehicle] = rig

	rig.Connection = vehicle:GetAttributeChangedSignal("TurnSignal"):Connect(function()
		onTurnSignalChanged(vehicle, rig)
	end)
	onTurnSignalChanged(vehicle, rig) -- sync to whatever it's already set to

	return rig
end

-- Builds the blinker rig (and wires it to the TurnSignal Attribute) the first
-- time this car is seen. Same call-it-whenever-convenient contract as
-- VehicleLights.EnsureTurnSignals.
function VehicleDashboardGauges.EnsureBlinkers(vehicle)
	getBlinkerRig(vehicle)
end

-- ===== Cleanup =====

function VehicleDashboardGauges.Clear(vehicle)
	gaugeRigs[vehicle] = nil

	local rig = blinkerRigs[vehicle]
	if rig then
		rig.Connection:Disconnect()
		rig.BlinkGeneration += 1 -- lets any in-flight blink loop stop itself
		blinkerRigs[vehicle] = nil
	end
end

return VehicleDashboardGauges

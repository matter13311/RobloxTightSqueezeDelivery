-- All the car's electrical lights: brake/reverse, headlights, and turn
-- signals. Each is built lazily from parts already sitting under the car's
-- Lights folder, the same lazy per-vehicle rig pattern as VehicleEffects.
--
-- Two different sources of truth, by design:
--   * Brake/reverse (VehicleLights.Update) is continuous pedal state, only
--     known for the car THIS client is driving - like Burnout in
--     VehicleEffects, a bystander has no way to derive it from replicated
--     velocity, so it's read fresh from the drive session every frame.
--   * Headlights and turn signals are discrete switches anyone can see the
--     current position of - a real light switch doesn't need the driver
--     nearby to stay lit. They're server-authoritative Attributes on the
--     vehicle (see VehicleLightSwitches.server.luau) that every client,
--     including the driver's own, reacts to identically via
--     GetAttributeChangedSignal - so the switch-click and turn-signal
--     on/off/tick sounds only ever play once per real toggle, everywhere.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local VehicleLights = {}

-- Per-car brightness multiplier (see VehiclePhysics.Defaults.LightBrightness
-- for what it defaults to and why). Same defensive pattern as
-- VehicleDamage.server.luau's bodyStrengthOf: a missing chassis, a bad config
-- value, or anything non-positive just falls back to "unscaled", so a
-- misconfigured car gets an ordinary-brightness light rather than a dark or
-- blown-out one.
local function lightBrightnessOf(vehicle)
	local chassis = vehicle.PrimaryPart
	if not chassis then
		return 1
	end
	local brightness = VehiclePhysics.GetConfig(chassis).LightBrightness
	if type(brightness) ~= "number" or brightness ~= brightness or brightness <= 0 then
		return 1
	end
	return brightness
end

-- ===== Brake / reverse =====

local BRAKE_COLOR = Color3.fromRGB(255, 0, 0)
local REVERSE_COLOR = Color3.fromRGB(255, 255, 255)

local BRAKE_PART_NAMES = { "BrakeLeft", "BrakeRight", "ReverseLeft", "ReverseRight" }

local rigs = {} -- [vehicle] = { [partName] = { Part, Light, OffMaterial } }

local function buildPointLight(part, color, name, brightnessMultiplier)
	local light = Instance.new("PointLight")
	light.Name = name
	light.Color = color
	light.Brightness = 2 * (brightnessMultiplier or 1)
	light.Range = 12
	light.Enabled = false
	light.Parent = part
	return light
end

local function getRig(vehicle)
	local rig = rigs[vehicle]
	if rig then
		return rig
	end

	local lights = vehicle:FindFirstChild("Lights")
	local brakeRear = lights and lights:FindFirstChild("BrakeRear")
	if not brakeRear then
		return nil -- car isn't fully set up yet; try again next frame
	end

	local brightness = lightBrightnessOf(vehicle)

	rig = {}
	for _, name in BRAKE_PART_NAMES do
		local part = brakeRear:FindFirstChild(name)
		if not part then
			return nil
		end
		local isReverse = name:find("Reverse") ~= nil
		rig[name] = {
			Part = part,
			Light = buildPointLight(part, if isReverse then REVERSE_COLOR else BRAKE_COLOR, "TailLight", brightness),
			-- Whatever material the part was built with (Plastic, SmoothPlastic,
			-- ...) - restored when the light turns back off, so the lit look
			-- comes purely from switching to Neon plus the PointLight, without
			-- ever touching the BrickColor that already makes these red/white.
			OffMaterial = part.Material,
		}
	end

	rigs[vehicle] = rig
	return rig
end

local function setPair(rig, leftName, rightName, on)
	for _, name in { leftName, rightName } do
		local entry = rig[name]
		entry.Light.Enabled = on
		entry.Part.Material = if on then Enum.Material.Neon else entry.OffMaterial
	end
end

-- `isBraking` / `isReversing` should only be true for the car this client is
-- driving - see the module comment above. Call every frame for every visible
-- vehicle.
function VehicleLights.Update(vehicle, isBraking, isReversing)
	local rig = getRig(vehicle)
	if not rig then
		return
	end

	setPair(rig, "BrakeLeft", "BrakeRight", isBraking)
	setPair(rig, "ReverseLeft", "ReverseRight", isReversing)
end

-- ===== Shared sound helper =====

-- Fire-and-forget: parents a Sound, plays it once, and lets Debris clean it
-- up once it's done rather than leaking a Sound instance per toggle.
--
-- Named anything other than the default "Sound": VehiclePhysics.Step finds
-- the engine sound with carModel:FindFirstChild("Sound", true), a recursive
-- search for the first descendant named exactly "Sound" anywhere in the car.
-- An unnamed Instance.new("Sound") defaults to that same name, so while one
-- of these was alive under the car it could win that search instead of the
-- real engine sound - freezing the engine pitch until Debris cleaned this one
-- up, at which point the pitch would jump to wherever it should have been
-- all along. That was the bug: toggling a light created exactly this clash.
local function playOneShot(parent, soundId, volume)
	local sound = Instance.new("Sound")
	sound.Name = "VehicleLightsOneShot"
	sound.SoundId = "rbxassetid://" .. soundId
	sound.Volume = volume or 0.7
	sound.RollOffMaxDistance = 100
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 6)
end

-- ===== Headlights =====

local HEADLIGHT_SWITCH_SOUND = "129921942229278"
local HEADLIGHT_PART_NAMES = { "HeadlightLeft", "HeadlightRight" }

local headlightRigs = {} -- [vehicle] = { [partName] = { Part, Light, OffMaterial }, Connection }

-- A SpotLight, not a PointLight: a headlight throws a directed beam, not an
-- even glow in every direction. Face defaults to Front (-Z locally) - if a
-- headlight part is built facing some other way, change Face here to match.
local function buildSpotlight(part, brightnessMultiplier)
	local light = Instance.new("SpotLight")
	light.Name = "Headlight"
	light.Color = Color3.fromRGB(255, 255, 240)
	light.Brightness = 3 * (brightnessMultiplier or 1)
	light.Range = 60
	light.Angle = 80
	light.Face = Enum.NormalId.Front
	light.Enabled = false
	light.Parent = part
	return light
end

local function applyHeadlights(rig, on)
	for _, name in HEADLIGHT_PART_NAMES do
		local entry = rig[name]
		entry.Light.Enabled = on
		entry.Part.Material = if on then Enum.Material.Neon else entry.OffMaterial
	end
end

local function getHeadlightRig(vehicle)
	local rig = headlightRigs[vehicle]
	if rig then
		return rig
	end

	local lights = vehicle:FindFirstChild("Lights")
	local frontLights = lights and lights:FindFirstChild("FrontLights")
	if not frontLights then
		return nil
	end

	local brightness = lightBrightnessOf(vehicle)

	rig = {}
	for _, name in HEADLIGHT_PART_NAMES do
		local part = frontLights:FindFirstChild(name)
		if not part then
			return nil
		end
		rig[name] = {
			Part = part,
			Light = buildSpotlight(part, brightness),
			OffMaterial = part.Material,
		}
	end

	-- Sync immediately to whatever the switch is already set to - covers a
	-- client that starts observing this car after the headlights were
	-- switched (joining late, or just walking within render distance), with
	-- no sound played for what is a sync, not a toggle.
	applyHeadlights(rig, vehicle:GetAttribute("HeadlightsOn") == true)

	rig.Connection = vehicle:GetAttributeChangedSignal("HeadlightsOn"):Connect(function()
		local on = vehicle:GetAttribute("HeadlightsOn") == true
		applyHeadlights(rig, on)
		playOneShot(rig.HeadlightLeft.Part, HEADLIGHT_SWITCH_SOUND)
	end)

	headlightRigs[vehicle] = rig
	return rig
end

-- Builds the headlight rig (and wires it to react to the HeadlightsOn
-- Attribute) the first time this car is seen. After that it's entirely
-- event-driven - call once per car whenever convenient, it's a no-op past
-- the first successful call.
function VehicleLights.EnsureHeadlights(vehicle)
	getHeadlightRig(vehicle)
end

-- ===== Turn signals =====

local TURN_SIGNAL_ON_SOUND = "6725066621"
local TURN_SIGNAL_OFF_SOUND = "6725066960"
local TURN_SIGNAL_TICK_SOUND = "114212126315936"

-- Real turn signals blink at roughly 60-120 flashes a minute (1-2 Hz).
-- 0.35s on / 0.35s off lands at ~1.4 Hz - a steady, unhurried blink rather
-- than a frantic one.
local TURN_SIGNAL_ON_TIME = 0.35
local TURN_SIGNAL_OFF_TIME = 0.35

local TURN_SIGNAL_COLOR = Color3.fromRGB(255, 170, 0)
local TURN_SIGNAL_SIDES = { "Left", "Right" }

local turnSignalRigs = {} -- [vehicle] = { Left = {...}, Right = {...}, ActiveSide, BlinkGeneration, Connection }

local function setSignalLit(entry, on)
	entry.Light.Enabled = on
	entry.Part.Material = if on then Enum.Material.Neon else entry.OffMaterial
end

-- Runs one side's blink cycle for as long as `generation` is still current -
-- switching sides or turning the signal off bumps BlinkGeneration, which is
-- this loop's only cue to stop; nothing ever needs to reach in and cancel it
-- directly.
local function runBlinkLoop(rig, side, generation)
	local entry = rig[side]
	task.spawn(function()
		while rig.BlinkGeneration == generation do
			setSignalLit(entry, true)
			playOneShot(entry.Part, TURN_SIGNAL_TICK_SOUND, 0.5)
			task.wait(TURN_SIGNAL_ON_TIME)
			if rig.BlinkGeneration ~= generation then
				break
			end
			setSignalLit(entry, false)
			task.wait(TURN_SIGNAL_OFF_TIME)
		end
		-- However this loop is ending, never leave the light stuck on
		-- mid-flash.
		setSignalLit(entry, false)
	end)
end

-- Reacts to the TurnSignal Attribute changing ("None" / "Left" / "Right").
-- The on/off sound plays exactly once per real toggle; a side switching
-- straight to the other plays only the on sound, per how a real column
-- stalk works. The very first call (when a client starts observing a car
-- whose signal is already active - joining late, or just coming into view)
-- syncs the light and starts the blink silently, without pretending the
-- signal was just switched on.
local function onTurnSignalChanged(vehicle, rig)
	local active = vehicle:GetAttribute("TurnSignal")
	if active == rig.ActiveSide then
		return
	end

	local previous = rig.ActiveSide
	local firstObservation = previous == nil
	rig.ActiveSide = active
	rig.BlinkGeneration += 1

	if previous and rig[previous] then
		setSignalLit(rig[previous], false)
	end

	if active == "Left" or active == "Right" then
		if not firstObservation then
			playOneShot(rig[active].Part, TURN_SIGNAL_ON_SOUND)
		end
		runBlinkLoop(rig, active, rig.BlinkGeneration)
	elseif not firstObservation then
		playOneShot(rig.Left.Part, TURN_SIGNAL_OFF_SOUND)
	end
end

local function getTurnSignalRig(vehicle)
	local rig = turnSignalRigs[vehicle]
	if rig then
		return rig
	end

	local lights = vehicle:FindFirstChild("Lights")
	local folder = lights and lights:FindFirstChild("TurnSignal")
	if not folder then
		return nil
	end

	local brightness = lightBrightnessOf(vehicle)

	rig = { ActiveSide = nil, BlinkGeneration = 0 }
	for _, side in TURN_SIGNAL_SIDES do
		local part = folder:FindFirstChild("TurnSignal" .. side)
		if not part then
			return nil
		end
		rig[side] = {
			Part = part,
			Light = buildPointLight(part, TURN_SIGNAL_COLOR, "TurnSignalLight", brightness),
			OffMaterial = part.Material,
		}
	end

	turnSignalRigs[vehicle] = rig

	rig.Connection = vehicle:GetAttributeChangedSignal("TurnSignal"):Connect(function()
		onTurnSignalChanged(vehicle, rig)
	end)
	onTurnSignalChanged(vehicle, rig) -- sync to whatever it's already set to

	return rig
end

-- Builds the turn-signal rig the first time this car is seen. Same
-- call-it-whenever-convenient contract as EnsureHeadlights.
function VehicleLights.EnsureTurnSignals(vehicle)
	getTurnSignalRig(vehicle)
end

-- ===== Cleanup =====

-- Called when a car goes away, and when the client stops tracking it.
function VehicleLights.Clear(vehicle)
	local rig = rigs[vehicle]
	if rig then
		for _, entry in rig do
			entry.Light:Destroy()
		end
		rigs[vehicle] = nil
	end

	local headlightRig = headlightRigs[vehicle]
	if headlightRig then
		headlightRig.Connection:Disconnect()
		for _, name in HEADLIGHT_PART_NAMES do
			headlightRig[name].Light:Destroy()
		end
		headlightRigs[vehicle] = nil
	end

	local turnRig = turnSignalRigs[vehicle]
	if turnRig then
		turnRig.Connection:Disconnect()
		turnRig.BlinkGeneration += 1 -- lets any in-flight blink loop stop itself
		for _, side in TURN_SIGNAL_SIDES do
			turnRig[side].Light:Destroy()
		end
		turnSignalRigs[vehicle] = nil
	end
end

return VehicleLights

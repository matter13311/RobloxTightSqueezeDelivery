-- Switches the city's street lamps on after dark.
--
-- The lamp heads are Neon and so always look lit, but Neon emits no light onto
-- anything around it - without a real light source a night street was a row of
-- glowing blobs hanging over black tarmac. Each lamp carries a PointLight
-- (added to the kit template in tools/mapgen/Main.luau, so it survives a
-- RunZones) which this enables.
--
-- WHY THIS IS A CLIENT SCRIPT AND WHY IT CULLS BY DISTANCE. There are ~270
-- lamps in the city and they are all on at once after dark. Under Voxel
-- lighting that many live PointLights is a real cost on a low-end phone, and
-- none of the ones across the map are contributing anything the player can
-- see. Only the lamps within RANGE of the camera are enabled, which is a few
-- dozen at a time. Light.Enabled is purely visual, so doing this per-client
-- costs nothing in replication and lets each machine light only its own view.
--
-- The cost of deciding is ~270 distance checks twice a second. That is the
-- whole budget - there is no light-level probing here or anywhere else (see
-- VehicleLights' interior rig for why that idea was dropped).
--
-- Lamps are looked up lazily rather than cached when the tag appears, for the
-- same StreamingEnabled reason as StalledCarHazards: a tagged lamp can reach
-- the client before its parts do, so a list built at that moment would be
-- empty forever.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DayNight = require(ReplicatedStorage.Modules.World.DayNight)

local TAG = "StreetLamp"
local RANGE = 260 -- studs from the camera
local INTERVAL = 0.5

local lamps = {} -- [model] = { Light = PointLight?, Enabled = bool? }

local function track(model)
	lamps[model] = { Light = nil, Enabled = nil }
end

for _, model in CollectionService:GetTagged(TAG) do
	track(model)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(model)
	lamps[model] = nil
end)

local function lightOf(entry, model)
	local light = entry.Light
	if light and light.Parent then
		return light
	end
	light = model:FindFirstChildWhichIsA("PointLight", true)
	entry.Light = light
	entry.Enabled = nil -- freshly streamed in, in whatever state it arrived with
	return light
end

local timer = 0
RunService.Heartbeat:Connect(function(deltaTime)
	timer += deltaTime
	if timer < INTERVAL then
		return
	end
	timer = 0

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local origin = camera.CFrame.Position

	-- Read straight off Lighting rather than running a clock: the server owns
	-- the time of day (DayNight.server.luau) and ClockTime is already
	-- replicated here, so this can never disagree with what the sky is doing.
	local dark = DayNight.IsDark(Lighting.ClockTime)

	for model, entry in lamps do
		if not model.Parent then
			lamps[model] = nil
			continue
		end

		local wanted = dark and (model:GetPivot().Position - origin).Magnitude <= RANGE

		-- Only touched when it actually changes: setting Enabled re-dirties the
		-- voxel lighting around the lamp, so writing the same value every pass
		-- would make a still camera pay for a static scene.
		if entry.Enabled == wanted then
			continue
		end

		-- Never lit, and not wanted now: there is nothing to switch off. Worth
		-- its own case because most of the city is in this state most of the
		-- time, and without it every distant lamp pays for a recursive search
		-- twice a second - on a lamp whose parts StreamingEnabled has very
		-- likely not even sent yet, so the search would fail anyway.
		if not wanted and entry.Enabled == nil then
			continue
		end

		local light = lightOf(entry, model)
		if light then
			light.Enabled = wanted
			entry.Enabled = wanted
		end
	end
end)

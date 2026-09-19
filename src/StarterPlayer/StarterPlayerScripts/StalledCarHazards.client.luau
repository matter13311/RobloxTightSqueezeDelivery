-- Flashing hazard lights on the stalled cars in workspace.Map.Traffic.Stalled
-- (and the Canal St crash scene).
--
-- Without them a car sitting in a driving lane reads as parked, which is the
-- wrong story: parked cars belong at the kerb, and anything stopped in a lane
-- should look broken down. The lamps are ordinary parts added to each car in
-- the place file; this just blinks them.
--
-- Every stalled car in the city blinks on the same beat, taken from the shared
-- clock, so all players see the same thing. Only cars near the camera are
-- touched each blink; the rest are usually not even streamed in.
--
-- The lamps are looked up lazily rather than cached when the tag appears:
-- with StreamingEnabled a tagged car can reach the client before its parts do,
-- so a list built at that moment would be empty forever.

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local TAG = "StalledCar"
local PERIOD = 1.1 -- seconds for a full on/off cycle
local ON_FRACTION = 0.5
local RANGE = 320 -- studs from the camera
local INTERVAL = 0.1

local ON_COLOR = Color3.fromRGB(255, 120, 20)
local OFF_COLOR = Color3.fromRGB(120, 60, 10)

local cars = {} -- [model] = { Parts = {BasePart} or nil, Lit = bool? }

local function track(model)
	cars[model] = { Parts = nil, Lit = nil }
end

for _, model in CollectionService:GetTagged(TAG) do
	track(model)
end
CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(model)
	cars[model] = nil
end)

local function lampsOf(entry, model)
	local parts = entry.Parts
	if parts and #parts > 0 and parts[1].Parent then
		return parts
	end
	parts = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Name == "HazardLight" then
			table.insert(parts, part)
		end
	end
	entry.Parts = parts
	entry.Lit = nil -- freshly found lamps are in whatever state they streamed in with
	return parts
end

local timer = 0
RunService.Heartbeat:Connect(function(dt)
	timer += dt
	if timer < INTERVAL then
		return
	end
	timer = 0

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local origin = camera.CFrame.Position
	local lit = (workspace:GetServerTimeNow() % PERIOD) < PERIOD * ON_FRACTION

	for model, entry in cars do
		if not model.Parent then
			cars[model] = nil
			continue
		end
		local pivot = model:GetPivot().Position
		if (pivot - origin).Magnitude > RANGE then
			continue
		end
		local parts = lampsOf(entry, model)
		if #parts > 0 and entry.Lit ~= lit then
			entry.Lit = lit
			for _, part in parts do
				part.Material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic
				part.Color = if lit then ON_COLOR else OFF_COLOR
			end
		end
	end
end)

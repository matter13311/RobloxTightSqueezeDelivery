-- Draws the NPC traffic that TrafficServer.server.luau simulates, so every
-- player sees the same cars. Routes and tuning: Modules/Traffic/TrafficConfig.
-- Wire format: Modules/Traffic/TrafficNet.
--
-- The server sends a snapshot of every car (route, distance along it, speed,
-- how far it may go before stopping) about ten times a second. This script
-- keeps a local model per car and moves it along the same path every frame
-- (wrapping round at the end of a circuit), steering its distance toward where
-- the latest snapshot says the car should be by now. Cars never drive
-- backwards to correct: one that is ahead of the server just slows until the
-- server catches up, and it never passes the stopping point the server sent,
-- so a queue never visibly overlaps.
--
-- Cars are anchored and moved with one BulkMoveTo per frame. The local
-- player's own vehicle collides with these local copies (this client
-- simulates that vehicle), and VehicleCrashDetector reports the crash like
-- any other. When the local player's vehicle touches a traffic car, the bump
-- is shown here immediately and reported to the server, which stops the car
-- for everyone and tells the other clients to play the same bump.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TrafficConfig = require(ReplicatedStorage.Modules.Traffic.TrafficConfig)
local TrafficPath = require(ReplicatedStorage.Modules.Traffic.TrafficPath)
local TrafficNet = require(ReplicatedStorage.Modules.Traffic.TrafficNet)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local player = Players.LocalPlayer

local templatesFolder = ReplicatedStorage:WaitForChild("TrafficCars", 30)
if not templatesFolder then
	warn("[Traffic] ReplicatedStorage.TrafficCars is missing - no traffic this session")
	return
end
local vehicleFolder = workspace:WaitForChild("Vehicles")
local snapshotRemote = ReplicatedStorage:WaitForChild(TrafficNet.SnapshotRemote)
local eventRemote = ReplicatedStorage:WaitForChild(TrafficNet.EventRemote)
local bumpRemote = ReplicatedStorage:WaitForChild(TrafficNet.BumpRemote)
local cameraRemote = ReplicatedStorage:WaitForChild(TrafficNet.CameraRemote)

local AHEAD_SAMPLE = 4 -- studs ahead of the centre a car points at, smooths corners
local SNAP_DISTANCE = 25 -- further than this from the server and the car just jumps
local CORRECTION_GAIN = 2 -- extra studs/s per stud behind the server
-- Ceiling on that correction. Catching up a big gap at full gain looks like a
-- car sprinting; at 12 studs/s it closes ~25 studs in two seconds instead.
local MAX_CATCHUP = 12
local PREDICTION_SLACK = 1.5 -- studs a car may run ahead of the predicted position
local CAMERA_REPORT_INTERVAL = 0.5

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local templates = TrafficNet.SortedTemplates(templatesFolder)

local routes = {}
for index, route in TrafficConfig.Routes do
	routes[index] = TrafficPath.Build(TrafficConfig, route)
	routes[index].Closed = route.Closed
end

local trafficFolder = Instance.new("Folder")
trafficFolder.Name = "NpcTraffic"
trafficFolder.Parent = workspace

--=============================================================================
-- Car models
--=============================================================================

local visuals = {} -- [id] = visual
local pools = {} -- [templateIndex] = { model record }

-- Defined with the bump handling below; Touched needs it first.
local onTouched

local function buildModel(templateIndex)
	local model = templates[templateIndex]:Clone()
	local root = model.PrimaryPart

	local parts, offsets, lights = { root }, { CFrame.identity }, {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			table.insert(parts, part)
			table.insert(offsets, root.CFrame:ToObjectSpace(part.CFrame))
			if part.Name == "BrakeLight" then
				table.insert(lights, part)
			end
		end
	end

	local horn = Instance.new("Sound")
	horn.Name = "Horn"
	horn.SoundId = TrafficConfig.HornSoundId
	horn.Looped = true
	horn.Volume = TrafficConfig.HornVolume
	horn.RollOffMode = Enum.RollOffMode.InverseTapered
	horn.RollOffMaxDistance = TrafficConfig.HornRollOffMaxDistance
	horn.Parent = root

	local record = {
		TemplateIndex = templateIndex,
		Model = model,
		Root = root,
		Parts = parts,
		Offsets = offsets,
		Lights = lights,
		Horn = horn,
		Height = root.Size.Y / 2,
		Visual = nil, -- the car currently using this model
	}
	root.Touched:Connect(function(hit)
		if record.Visual then
			onTouched(record.Visual, hit)
		end
	end)
	return record
end

local function setBrakeLights(visual, on)
	if visual.LightsOn == on then
		return
	end
	visual.LightsOn = on
	for _, light in visual.Record.Lights do
		light.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
		light.Color = if on then TrafficConfig.BrakeLightOnColor else TrafficConfig.BrakeLightOffColor
	end
end

local function createVisual(entry)
	local pool = pools[entry.TemplateIndex]
	local record = pool and table.remove(pool) or buildModel(entry.TemplateIndex)
	local visual = {
		Id = entry.Id,
		RouteIndex = entry.RouteIndex,
		TemplateIndex = entry.TemplateIndex,
		Path = routes[entry.RouteIndex],
		Record = record,
		S = entry.S,
		Cursor = 1,
		Snap = nil,
		Bump = nil,
		LocalBumpAt = 0,
		HoldUntil = 0,
		LastCFrame = nil,
		LightsOn = nil,
	}
	record.Visual = visual
	record.Horn.PlaybackSpeed = TrafficNet.HornPitch(TrafficConfig, entry.Id)
	record.Model.Parent = trafficFolder
	visuals[entry.Id] = visual
	return visual
end

local function releaseVisual(visual)
	visuals[visual.Id] = nil
	local record = visual.Record
	record.Visual = nil
	record.Horn:Stop()
	record.Model.Parent = nil
	pools[record.TemplateIndex] = pools[record.TemplateIndex] or {}
	table.insert(pools[record.TemplateIndex], record)
end

--=============================================================================
-- Snapshots
--=============================================================================

local lastSnapshotTime = -math.huge
local currentSeq = nil
local seenThisSnapshot = {}
local chunksOutstanding = 0

snapshotRemote.OnClientEvent:Connect(function(payload)
	local serverTime, entries, seq, _chunkIndex, chunkCount = TrafficNet.Decode(payload)
	-- Unreliable: a late chunk can arrive after a newer snapshot. Drop it.
	if not serverTime or serverTime < lastSnapshotTime then
		return
	end

	if serverTime > lastSnapshotTime or seq ~= currentSeq then
		-- A new snapshot. Anything still outstanding from the previous one was
		-- lost, so that snapshot never gets to decide what disappeared.
		lastSnapshotTime = serverTime
		currentSeq = seq
		seenThisSnapshot = {}
		chunksOutstanding = chunkCount
	end

	local seen = seenThisSnapshot
	for _, entry in entries do
		local path = routes[entry.RouteIndex]
		if not path or not templates[entry.TemplateIndex] then
			continue
		end
		seen[entry.Id] = true

		local visual = visuals[entry.Id]
		-- Ids wrap; a reused id on a different route or body is a different car.
		if visual and (visual.RouteIndex ~= entry.RouteIndex or visual.TemplateIndex ~= entry.TemplateIndex) then
			releaseVisual(visual)
			visual = nil
		end
		if not visual then
			visual = createVisual(entry)
		end

		-- Room at the cap means nothing is in front of it: no stop point at all.
		-- Anything less is a real distance from `S` to where it must stop.
		local unlimited = entry.Room >= TrafficNet.MaxRoom - 1
		visual.Snap = {
			Time = serverTime,
			S = entry.S,
			Unlimited = unlimited,
			Stop = if unlimited
				then nil
				else entry.S + (if path.Closed then entry.Room else math.min(path.Length - entry.S, entry.Room)),
			Speed = entry.Speed,
		}
		setBrakeLights(visual, entry.Braking)
	end

	-- Only once every chunk of this snapshot has arrived is the "seen" set
	-- complete enough to retire the cars missing from it.
	chunksOutstanding -= 1
	if chunksOutstanding <= 0 then
		for id, visual in visuals do
			if not seen[id] then
				releaseVisual(visual)
			end
		end
	end
end)

--=============================================================================
-- Horn
--=============================================================================

local function playHonk(visual, pattern)
	-- {on, off, on, ...} in seconds.
	local beeps = if pattern == "long" then { 0.7 } elseif pattern == "double" then { 0.18, 0.12, 0.22 } else { 0.25 }
	local record = visual.Record
	local horn = record.Horn
	task.spawn(function()
		for i, duration in beeps do
			if record.Visual ~= visual then
				return
			end
			if i % 2 == 1 then
				horn:Play()
			else
				horn:Stop()
			end
			task.wait(duration)
		end
		if record.Visual == visual then
			horn:Stop()
		end
	end)
end

--=============================================================================
-- Bumps
--=============================================================================

local function startBump(visual, direction, strength, yawSign)
	visual.Bump = {
		Start = os.clock(),
		Direction = direction,
		Strength = strength,
		YawSign = yawSign,
	}
end

local function bumpOffset(visual, now)
	local bump = visual.Bump
	local k = (now - bump.Start) / TrafficConfig.BumpSettleSeconds
	if k >= 1 then
		visual.Bump = nil
		return nil
	end
	-- Quick shove out over the first 15%, then an eased settle back.
	local shove = if k < 0.15 then k / 0.15 else (1 - (k - 0.15) / 0.85) ^ 2
	local offset = bump.Direction * shove * bump.Strength * TrafficConfig.BumpMaxShove
	local yaw = math.rad(TrafficConfig.BumpMaxYaw * bump.Strength * bump.YawSign) * math.sin(k * math.pi * 3) * (1 - k)
	return offset, yaw
end

local function vehicleModelOf(part)
	local node = part
	while node and node.Parent ~= vehicleFolder do
		node = node.Parent
	end
	return node
end

onTouched = function(visual, hit)
	-- Every client sees every vehicle touch every car; only the driver of the
	-- vehicle reports it, so a crash is reported once.
	if not hit:IsDescendantOf(vehicleFolder) then
		return
	end
	local vehicle = vehicleModelOf(hit)
	if not vehicle or VehicleSeats.GetDriverPlayer(vehicle) ~= player then
		return
	end

	local now = os.clock()
	if now - visual.LocalBumpAt < 0.5 or not visual.Snap then
		return
	end
	local carVelocity = (visual.Forward or Vector3.zero) * visual.Snap.Speed
	local relativeSpeed = flat(hit.AssemblyLinearVelocity - carVelocity).Magnitude
	if relativeSpeed < TrafficConfig.BumpMinSpeed then
		return
	end

	visual.LocalBumpAt = now
	local away = flat(visual.Record.Root.Position - hit.Position)
	local direction = if away.Magnitude > 0.1 then away.Unit else flat(hit.AssemblyLinearVelocity).Unit
	startBump(visual, direction, math.clamp(relativeSpeed / 35, 0.25, 1), if math.random() < 0.5 then -1 else 1)
	-- Stop it here straight away; the server's stop arrives a round-trip later.
	visual.HoldUntil = now + 0.6
	bumpRemote:FireServer(visual.Id, relativeSpeed)
end

eventRemote.OnClientEvent:Connect(function(kind, id, ...)
	local visual = visuals[id]
	if not visual then
		return
	end
	if kind == "honk" then
		playHonk(visual, ...)
	elseif kind == "bump" then
		local dx, dz, strength, yawSign, bumper = ...
		-- The player who hit it already played this bump locally.
		if bumper == player and os.clock() - visual.LocalBumpAt < 1.5 then
			return
		end
		startBump(visual, Vector3.new(dx, 0, dz), strength, yawSign)
	end
end)

--=============================================================================
-- Camera reports (the server only recycles cars nobody can see)
--=============================================================================

local cameraTimer = 0

local function reportCamera(dt)
	cameraTimer += dt
	if cameraTimer < CAMERA_REPORT_INTERVAL then
		return
	end
	cameraTimer = 0
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local viewport = camera.ViewportSize
	cameraRemote:FireServer(camera.CFrame, camera.FieldOfView, viewport.X / math.max(1, viewport.Y))
end

--=============================================================================
-- Per frame
--=============================================================================

local moveParts, moveCFrames = {}, {}

RunService.Heartbeat:Connect(function(dt)
	local now = os.clock()
	local serverNow = workspace:GetServerTimeNow()

	for _, visual in visuals do
		local snap = visual.Snap
		if not snap then
			continue
		end
		local path = visual.Path

		-- Where the server's car should be by now.
		local length = path.Length
		local expected = snap.S + snap.Speed * math.max(0, serverNow - snap.Time)
		if snap.Stop then
			expected = math.min(snap.Stop, expected)
		end
		local behind, room
		if path.Closed then
			-- Distances run round the loop, so compare the short way round.
			behind = (expected - visual.S) % length
			if behind > length / 2 then
				behind -= length
			end
		else
			behind = expected - visual.S
		end
		-- How far it may advance this frame. Measured against `expected` rather
		-- than the raw stop point: `expected` slides forward continuously
		-- between snapshots, so a slowly creeping car keeps creeping instead of
		-- hopping once per snapshot, while a car the server has stopped still
		-- comes to rest within SLACK of where the server put it.
		local target = expected + PREDICTION_SLACK
		if path.Closed then
			room = (target - visual.S) % length
			if room > length / 2 then
				room = 0 -- the target is behind us: hold still
			end
		else
			room = math.max(0, target - visual.S)
		end

		if math.abs(behind) > SNAP_DISTANCE then
			visual.S = if path.Closed then expected % length else expected
		elseif now >= visual.HoldUntil then
			local speed = math.max(0, snap.Speed + math.min(behind * CORRECTION_GAIN, MAX_CATCHUP))
			visual.S += math.min(speed * dt, room)
			if path.Closed then
				visual.S %= length
			end
		end
		visual.S = if path.Closed then visual.S % length else math.clamp(visual.S, 0, length)

		local position, direction, cursor = TrafficPath.Sample(path, visual.S, visual.Cursor)
		visual.Cursor = cursor
		local aheadPosition = TrafficPath.Sample(path, visual.S + AHEAD_SAMPLE, cursor)
		local look = aheadPosition - position
		if look.Magnitude < 0.5 then
			look = direction
		end
		look = flat(look).Unit
		visual.Forward = look

		local record = visual.Record
		local centre = position + Vector3.new(0, TrafficConfig.RoadY + record.Height, 0)
		local cf = CFrame.lookAt(centre, centre + look)
		if visual.Bump then
			local offset, yaw = bumpOffset(visual, now)
			if offset then
				cf = (cf + offset) * CFrame.Angles(0, yaw, 0)
			end
		end

		if cf ~= visual.LastCFrame then
			visual.LastCFrame = cf
			local parts, offsets = record.Parts, record.Offsets
			for i = 1, #parts do
				table.insert(moveParts, parts[i])
				table.insert(moveCFrames, cf * offsets[i])
			end
		end
	end

	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveParts)
		table.clear(moveCFrames)
	end

	reportCamera(dt)
end)

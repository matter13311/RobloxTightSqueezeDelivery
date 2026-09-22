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
-- Lane changes are steered, not slid (the server drives the offset along an
-- S-curve tied to forward travel - see TrafficSim). Here the drawn offset may
-- only move this many studs sideways per stud the car moves forward, so a
-- car that is stopped or hopping to catch up never drifts sideways, and the
-- body is yawed along the direction it is actually travelling in.
local LATERAL_PER_FORWARD = 1.3
-- A drawn offset this far from the server's is a respawn/teleport: jump.
local LATERAL_SNAP = 14
-- How quickly the drawn yaw follows the travel direction (1/s).
local YAW_FOLLOW = 10
local YAW_FOLLOW_ON_CURVE = 30
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
	-- The only offsets a lane change runs between (TrafficSim: 0 or
	-- Lanes.Offset), so a predicted offset can be clamped to them.
	routes[index].LaneOffset = route.Lanes and route.Lanes.Offset or 0
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
-- Lane changes
--=============================================================================

-- The server moves a car across on a smoothstep of forward travel (TrafficSim:
-- Lane = From + (Goal - From) * smoothstep(Progress), Progress += travel /
-- LaneLength), always between the route line (0) and Lanes.Offset. Only the
-- current offset reaches the client, 10 times a second. Chasing that raw value
-- moved cars sideways in a staircase - catch up, wait for the next packet,
-- catch up - and the yaw read off each frame's step flicked between angled and
-- straight with it: the lane-change jitter. Even a rate extrapolated from two
-- packets lags the curve by half a packet and overshoots its end, so cars
-- reached the new lane still angled.
--
-- So the client rebuilds the curve itself. With both ends known, an offset IS
-- a progress (inverse smoothstep), and two packets give the curve's length:
-- travel between them / progress between them. From then on the drawn offset
-- and its slope are exact functions of the car's own distance along the route.

-- Copies of TrafficSim's LANE_STUDS_PER_OFFSET / LANE_MIN_LENGTH: keep equal.
local LANE_STUDS_PER_OFFSET = 4.5
local LANE_MIN_LENGTH = 16

-- 0..1 -> 0..1, the inverse of t * t * (3 - 2t).
local function inverseSmoothstep(f)
	f = math.clamp(f, 0, 1)
	return 0.5 - math.sin(math.asin(1 - 2 * f) / 3)
end

local function smoothstep(t)
	return t * t * (3 - 2 * t)
end

-- Forward distance from s0 to s1 along the route (short way round a loop).
local function travelled(path, s0, s1)
	local ds = s1 - s0
	if path.Closed then
		ds %= path.Length
		if ds > path.Length / 2 then
			ds -= path.Length
		end
	end
	return ds
end

-- Fed every snapshot. Keeps visual.Change = { From, Goal, AnchorS, AnchorP,
-- S, P, Length } while a change is running, nil otherwise.
local function trackLaneChange(visual, path, s, lateral)
	local offset = path.LaneOffset
	local previous = visual.Snap
	local change = visual.Change
	if offset == 0 then
		visual.Change = nil
		return
	end
	local atZero, atOffset = math.abs(lateral) < 0.07, math.abs(lateral - offset) < 0.07
	if change then
		local span = change.Goal - change.From
		-- Moving back the way it came is a change of mind: start over below.
		local backwards = previous and (lateral - previous.Lateral) * span < -0.07
		if backwards then
			change = nil
		elseif math.abs(lateral - change.Goal) < 0.07 then
			change.S, change.P = s, 1
			return
		end
	end
	if atZero or atOffset then
		-- Resting in a lane. A finished change stays until the car has drawn
		-- its way to the end of it (see the per-frame code).
		if change == nil then
			visual.Change = nil
		end
		return
	end
	if change == nil then
		if not previous or previous.Lateral == lateral then
			visual.Change = nil
			return -- no direction yet: the next packet will give one
		end
		local goal = if (lateral - previous.Lateral) * offset > 0 then offset else 0
		local from = if goal == 0 then offset else 0
		local p = inverseSmoothstep((lateral - from) / (goal - from))
		-- The server picked the curve's length from the room ahead when it
		-- decided (TrafficSim: clamp(Limit + LANE_MIN_LENGTH, LANE_MIN_LENGTH,
		-- open road)), and the last snapshot's Room is that Limit near enough.
		-- Guessing the open-road length instead drew a boxed-in car's short,
		-- sharp pull-out too gently, then kinked when two packets measured it.
		local openLength = math.abs(offset) * LANE_STUDS_PER_OFFSET
		local room = if previous.Unlimited or not previous.Stop then math.huge else travelled(path, previous.S, previous.Stop)
		change = {
			From = from,
			Goal = goal,
			AnchorS = s,
			AnchorP = p,
			S = s,
			P = p,
			-- until two packets measure it
			Length = math.clamp(math.max(0, room) + LANE_MIN_LENGTH, LANE_MIN_LENGTH, math.max(LANE_MIN_LENGTH, openLength)),
		}
		visual.Change = change
		return
	end
	local p = inverseSmoothstep((lateral - change.From) / (change.Goal - change.From))
	-- Measured over the whole change so far, not packet to packet: the
	-- offsets are 1/8-stud steps, so a long baseline is a far better ruler.
	local dp = p - change.AnchorP
	local ds = travelled(path, change.AnchorS, s)
	if dp > 0.06 and ds > 0.5 then
		change.Length = math.clamp(ds / dp, 8, 400)
	end
	change.S, change.P = s, math.max(p, change.P)
end

-- The drawn offset and its slope (sideways studs per forward stud) at distance
-- `s`, or nil when no change is running.
local function laneCurveAt(visual, path, s)
	local change = visual.Change
	if not change then
		return nil
	end
	local p = math.clamp(change.P + travelled(path, change.S, s) / change.Length, 0, 1)
	local span = change.Goal - change.From
	return change.From + span * smoothstep(p), span * 6 * p * (1 - p) / change.Length, p
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
		local lateral = entry.Lateral or 0
		trackLaneChange(visual, path, entry.S, lateral)
		visual.Snap = {
			Time = serverTime,
			S = entry.S,
			Unlimited = unlimited,
			Stop = if unlimited
				then nil
				else entry.S + (if path.Closed then entry.Room else math.min(path.Length - entry.S, entry.Room)),
			Speed = entry.Speed,
			Lateral = lateral,
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

		local previousS = visual.S
		local jumped = false
		if math.abs(behind) > SNAP_DISTANCE then
			visual.S = if path.Closed then expected % length else expected
			jumped = true
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

		-- Sideways offset for a lane change: follows the server's value, but
		-- only as fast as the car is rolling forward (see LATERAL_PER_FORWARD).
		local moved = visual.S - previousS
		if path.Closed and moved < -length / 2 then
			moved += length
		end
		moved = math.max(0, moved)
		-- Where the server's S-curve has the offset at OUR distance along the
		-- route (see trackLaneChange), else the snapshot's resting offset.
		local target, rate = snap.Lateral, 0
		local curveOffset, curveSlope, progress = laneCurveAt(visual, path, visual.S)
		if curveOffset then
			target, rate = curveOffset, curveSlope
			if progress >= 1 and math.abs(snap.Lateral - visual.Change.Goal) < 0.07 then
				visual.Change = nil -- drawn to the end, and the server agrees
			end
		end
		local lateral = visual.Lateral or target
		local wanted = target - lateral
		local step
		if jumped or math.abs(wanted) > LATERAL_SNAP then
			step = wanted
		else
			local limit = moved * LATERAL_PER_FORWARD
			step = math.clamp(wanted, -limit, limit)
		end
		lateral += step
		visual.Lateral = lateral
		-- The body points where it is going: forward plus the sideways drift.
		-- Held while stopped, so a car that stops mid-change stays angled
		-- instead of snapping straight. While the drawn offset is on the
		-- predicted curve its slope IS the curve's rate; the per-frame step is
		-- only used while it is still converging onto it (a fresh car, a
		-- correction), since dividing two tiny per-frame numbers is noisy.
		if moved > 1e-3 and not jumped then
			-- Even while the drawn offset is still closing a small gap onto
			-- the curve (the first packet of a change arrives with the car
			-- already part-way across), it is the curve's slope that is
			-- drawn: the catch-up step itself can be steep for a frame or two.
			local onCurve = curveOffset ~= nil and math.abs(target - lateral) < 1.5
			local slope = math.clamp(if onCurve then rate else step / moved, -1.5, 1.5)
			local s0 = visual.Slope or 0
			-- On the curve the slope is exact, so it is followed almost at once
			-- (the only thing left to smooth is a packet refining the curve's
			-- length); a lagging yaw is what left cars angled in the new lane.
			local follow = if onCurve then YAW_FOLLOW_ON_CURVE else YAW_FOLLOW
			visual.Slope = s0 + (slope - s0) * math.min(1, follow * dt)
		elseif jumped then
			visual.Slope = 0
		end
		local right = Vector3.new(-look.Z, 0, look.X)
		local heading = look
		if visual.Slope and math.abs(visual.Slope) > 1e-3 then
			heading = (look - right * visual.Slope).Unit
		end

		local record = visual.Record
		local centre = position - right * lateral + Vector3.new(0, TrafficConfig.RoadY + record.Height, 0)
		local cf = CFrame.lookAt(centre, centre + heading)
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

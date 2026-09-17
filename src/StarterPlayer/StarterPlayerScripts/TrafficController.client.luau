-- Moving NPC traffic. Routes and tuning live in Modules/Traffic/TrafficConfig.
--
-- Entirely client-side. Each player's machine creates its own traffic cars,
-- so the server never simulates or replicates them. That works because a
-- player's own car is physically simulated by that player's client: it
-- collides with the local traffic, and VehicleCrashDetector reports the hit
-- to the server like any other crash (the server does not validate WHAT was
-- hit). The cost is that two players do not see exactly the same traffic.
-- Traffic stops for every player's vehicle it can see, which keeps the
-- mismatch from being obvious.
--
-- Cars are anchored and placed with one BulkMoveTo per frame. They never
-- take part in physics: a player hitting one hits a wall, and the car plays
-- a small scripted "bump" (rocks away, settles, honks, waits) instead of
-- being shoved.
--
-- Sensing is plain vector maths, no raycasts: every SENSE_INTERVAL each car checks
-- every other car, every player vehicle and every character for anything
-- inside its lane ahead of it. Movement runs every frame against the result.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TrafficConfig = require(ReplicatedStorage.Modules.Traffic.TrafficConfig)
local TrafficPath = require(ReplicatedStorage.Modules.Traffic.TrafficPath)

local templatesFolder = ReplicatedStorage:WaitForChild("TrafficCars", 30)
if not templatesFolder then
	warn("[Traffic] ReplicatedStorage.TrafficCars is missing - no traffic this session")
	return
end
local vehicleFolder = workspace:WaitForChild("Vehicles")

local SENSE_INTERVAL = 0.1
local AHEAD_SAMPLE = 4 -- studs ahead of the car centre it points at, smooths corners

local rng = Random.new()

local function randRange(min, max)
	return rng:NextNumber(min, max)
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

--=============================================================================
-- Routes and templates
--=============================================================================

local routes = {}
local totalWeight = 0
for _, route in TrafficConfig.Routes do
	local path = TrafficPath.Build(TrafficConfig, route)
	table.insert(routes, { Name = route.Name, Weight = route.Weight or 1, Path = path })
	totalWeight += route.Weight or 1
end

local function pickRoute()
	local roll = rng:NextNumber(0, totalWeight)
	for _, route in routes do
		roll -= route.Weight
		if roll <= 0 then
			return route
		end
	end
	return routes[#routes]
end

local templates = templatesFolder:GetChildren()

local trafficFolder = Instance.new("Folder")
trafficFolder.Name = "NpcTraffic"
trafficFolder.Parent = workspace

--=============================================================================
-- Car records
--=============================================================================

-- Defined with the bump reaction below; the Touched handler needs it first.
local onTouched

local cars = {} -- active, in no particular order
local pool = {} -- recycled records, ready to reuse
local nextId = 0

local function newCarRecord()
	local template = templates[rng:NextInteger(1, #templates)]
	local model = template:Clone()
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
	horn.PlaybackSpeed = randRange(TrafficConfig.HornPitchMin, TrafficConfig.HornPitchMax)
	horn.Parent = root

	nextId += 1
	local car = {
		Id = nextId,
		Model = model,
		Root = root,
		Parts = parts,
		Offsets = offsets,
		Lights = lights,
		Horn = horn,
		HalfLength = model:GetAttribute("HalfLength") or root.Size.Z / 2,
		HalfWidth = model:GetAttribute("HalfWidth") or root.Size.X / 2,
		Height = root.Size.Y / 2,
	}

	root.Touched:Connect(function(hit)
		if car.Active then
			onTouched(car, hit)
		end
	end)

	return car
end

local function setBrakeLights(car, on)
	if car.LightsOn == on then
		return
	end
	car.LightsOn = on
	for _, light in car.Lights do
		light.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
		light.Color = if on then TrafficConfig.BrakeLightOnColor else TrafficConfig.BrakeLightOffColor
	end
end

local function rollHonkDelays(car)
	car.PlayerHonkDelay = randRange(TrafficConfig.HonkAtPlayerDelayMin, TrafficConfig.HonkAtPlayerDelayMax)
	car.QueueHonkDelay = randRange(TrafficConfig.HonkInQueueDelayMin, TrafficConfig.HonkInQueueDelayMax)
end

local function placeCar(car, route, s, speed)
	car.Active = true
	car.Route = route
	car.S = s
	car.Cursor = 1
	car.Speed = speed
	car.Limit = math.huge
	car.Leader = nil
	car.LeaderIsPlayer = false
	car.StoppedFor = 0
	car.EndWait = randRange(TrafficConfig.QueueWaitMin, TrafficConfig.QueueWaitMax)
	car.NextHonkAt = 0
	car.HoldUntil = 0
	car.Bump = nil
	car.IgnoreCar = nil
	car.LightsOn = nil
	car.LastCFrame = nil
	-- A pooled record still holds where it was last life; sensing and the
	-- spawn clearance check read these before the first movement step.
	local position, direction = TrafficPath.Sample(route.Path, s, 1)
	car.Position = position
	car.Forward = direction
	car.Right = Vector3.new(-direction.Z, 0, direction.X)
	rollHonkDelays(car)
	setBrakeLights(car, false)
	car.Model.Parent = trafficFolder
	table.insert(cars, car)
end

local function recycle(index)
	local car = cars[index]
	cars[index] = cars[#cars]
	cars[#cars] = nil
	car.Active = false
	car.Horn:Stop()
	car.Model.Parent = nil
	table.insert(pool, car)
end

local function takeCar()
	return table.remove(pool) or newCarRecord()
end

--=============================================================================
-- Visibility
--=============================================================================

local function isHidden(position)
	local camera = workspace.CurrentCamera
	if not camera then
		return true
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	if distance > TrafficConfig.HiddenDistance then
		return true
	end
	-- Right behind the camera is one quick turn away from being seen.
	if distance < 60 then
		return false
	end
	local viewport = camera.ViewportSize
	local point, inFront = camera:WorldToViewportPoint(position + Vector3.new(0, 3, 0))
	if not inFront then
		return true
	end
	-- Generous margin: a car is ~20 studs long, so its centre can be off
	-- screen while its bumper is not.
	local margin = 120
	return point.X < -margin or point.X > viewport.X + margin or point.Y < -margin or point.Y > viewport.Y + margin
end

--=============================================================================
-- Horn
--=============================================================================

local lastGlobalHonk = 0

local function honk(car, pattern)
	local now = os.clock()
	local camera = workspace.CurrentCamera
	if not camera or (camera.CFrame.Position - car.Root.Position).Magnitude > TrafficConfig.HornAudibleDistance then
		return false
	end
	if now - lastGlobalHonk < TrafficConfig.HornGlobalGap then
		return false
	end
	lastGlobalHonk = now
	car.NextHonkAt = now + randRange(TrafficConfig.HonkCooldownMin, TrafficConfig.HonkCooldownMax)

	-- {on, off, on, ...} in seconds.
	local beeps = if pattern == "long" then { 0.7 } elseif pattern == "double" then { 0.18, 0.12, 0.22 } else { 0.25 }
	local horn = car.Horn
	task.spawn(function()
		for i, duration in beeps do
			if not car.Active then
				break
			end
			if i % 2 == 1 then
				horn:Play()
			else
				horn:Stop()
			end
			task.wait(duration)
		end
		horn:Stop()
	end)
	return true
end

--=============================================================================
-- Bump reaction
--=============================================================================

onTouched = function(car, hit)
	if not hit:IsDescendantOf(vehicleFolder) then
		return
	end
	local now = os.clock()
	if car.Bump and now - car.Bump.Start < 0.4 then
		return
	end

	local carVelocity = car.Forward and car.Forward * car.Speed or Vector3.zero
	local relative = flat(hit.AssemblyLinearVelocity - carVelocity)
	local relativeSpeed = relative.Magnitude
	if relativeSpeed < TrafficConfig.BumpMinSpeed then
		return
	end

	local away = flat(car.Root.Position - hit.Position)
	if away.Magnitude < 0.1 then
		away = relative
	end

	car.Bump = {
		Start = now,
		Direction = away.Unit,
		Strength = math.clamp(relativeSpeed / 35, 0.25, 1),
		YawSign = if rng:NextNumber() < 0.5 then -1 else 1,
	}
	car.Speed = 0
	car.HoldUntil = now + randRange(TrafficConfig.BumpHoldMin, TrafficConfig.BumpHoldMax)
	honk(car, "long")
end

local function bumpOffset(car, now)
	local bump = car.Bump
	local k = (now - bump.Start) / TrafficConfig.BumpSettleSeconds
	if k >= 1 then
		car.Bump = nil
		return nil
	end
	-- Quick shove out over the first 15%, then an eased settle back.
	local shove = if k < 0.15 then k / 0.15 else (1 - (k - 0.15) / 0.85) ^ 2
	local offset = bump.Direction * shove * bump.Strength * TrafficConfig.BumpMaxShove
	local yaw = math.rad(TrafficConfig.BumpMaxYaw * bump.Strength * bump.YawSign) * math.sin(k * math.pi * 3) * (1 - k)
	return offset, yaw
end

--=============================================================================
-- Sensing
--=============================================================================

local extentsCache = setmetatable({}, { __mode = "k" })

-- Player vehicles and on-foot characters, as oriented boxes.
local function gatherPlayerObstacles()
	local obstacles = {}
	for _, model in vehicleFolder:GetChildren() do
		local root = model:IsA("Model") and model.PrimaryPart
		if root then
			local size = extentsCache[model]
			if not size then
				size = model:GetExtentsSize()
				extentsCache[model] = size
			end
			local cf = root.CFrame
			table.insert(obstacles, {
				Position = flat(cf.Position),
				Look = flat(cf.LookVector).Unit,
				Right = flat(cf.RightVector).Unit,
				HalfLength = size.Z / 2,
				HalfWidth = size.X / 2,
			})
		end
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart and humanoid and not humanoid.SeatPart and humanoid.Health > 0 then
			table.insert(obstacles, {
				Position = flat(rootPart.Position),
				Look = Vector3.zAxis,
				Right = Vector3.xAxis,
				HalfLength = 1.5,
				HalfWidth = 1.5,
			})
		end
	end
	return obstacles
end

-- Returns the bumper-to-bumper gap to `other` if it is in this car's lane
-- ahead of it, else nil.
local function gapTo(car, position, look, right, halfLength, halfWidth)
	local d = position - car.Position
	local ahead = d:Dot(car.Forward)
	if ahead <= 0 then
		return nil
	end
	local otherAlong = math.abs(look:Dot(car.Forward)) * halfLength + math.abs(right:Dot(car.Forward)) * halfWidth
	if ahead - otherAlong > TrafficConfig.LookAhead + car.HalfLength then
		return nil
	end
	local otherAcross = math.abs(look:Dot(car.Right)) * halfLength + math.abs(right:Dot(car.Right)) * halfWidth
	if math.abs(d:Dot(car.Right)) > car.HalfWidth + otherAcross + TrafficConfig.LateralSlack then
		return nil
	end
	return ahead - car.HalfLength - otherAlong
end

local function sense(now)
	local playerObstacles = gatherPlayerObstacles()

	for _, car in cars do
		local best, leader, leaderIsPlayer = math.huge, nil, false

		for _, other in cars do
			if other ~= car and not (car.IgnoreCar == other and now < car.IgnoreUntil) then
				local gap = gapTo(car, other.Position, other.Forward, other.Right, other.HalfLength, other.HalfWidth)
				if gap and gap < best then
					best, leader, leaderIsPlayer = gap, other, false
				end
			end
		end
		for _, obstacle in playerObstacles do
			local gap = gapTo(car, obstacle.Position, obstacle.Look, obstacle.Right, obstacle.HalfLength, obstacle.HalfWidth)
			if gap and gap < best then
				best, leader, leaderIsPlayer = gap, obstacle, true
			end
		end

		car.Limit = best - TrafficConfig.StopGap
		car.Leader = leader
		car.LeaderIsPlayer = leaderIsPlayer
	end

	-- Two cars that each think the other is in the way (crossing paths at a
	-- junction) would wait forever. After a moment, the older one goes.
	for _, car in cars do
		local other = car.Leader
		if
			other
			and not car.LeaderIsPlayer
			and other.Leader == car
			and car.StoppedFor > 1.5
			and other.StoppedFor > 1.5
			and car.Id < other.Id
		then
			car.IgnoreCar = other
			car.IgnoreUntil = now + 3
		end
	end

	-- Honking.
	for _, car in cars do
		if car.StoppedFor <= 0 or now < car.NextHonkAt or now < car.HoldUntil then
			continue
		end
		if car.LeaderIsPlayer then
			if car.StoppedFor > car.PlayerHonkDelay then
				honk(car, if rng:NextNumber() < 0.5 then "double" else "tap")
			end
		elseif car.StoppedFor > car.QueueHonkDelay then
			if rng:NextNumber() < TrafficConfig.HonkInQueueChance then
				honk(car, "tap")
			end
			-- Whether or not it honked, wait a while before thinking about it again.
			car.QueueHonkDelay = car.StoppedFor
				+ randRange(TrafficConfig.HonkInQueueDelayMin, TrafficConfig.HonkInQueueDelayMax)
		end
	end
end

--=============================================================================
-- Spawning and recycling
--=============================================================================

local function isClear(position, clearance)
	for _, car in cars do
		if car.Position and (car.Position - position).Magnitude < clearance then
			return false
		end
	end
	for _, model in vehicleFolder:GetChildren() do
		local root = model:IsA("Model") and model.PrimaryPart
		if root and (flat(root.Position) - position).Magnitude < clearance then
			return false
		end
	end
	return true
end

local function trySpawn()
	if #cars >= TrafficConfig.MaxCars then
		return
	end
	local route = pickRoute()
	local start = route.Path.Points[1]
	if not isHidden(start) or not isClear(start, TrafficConfig.SpawnClearance) then
		return
	end
	placeCar(takeCar(), route, 0, TrafficConfig.CruiseSpeed * 0.6)
end

-- Fill the streets at load so the city doesn't start empty and fill up from
-- the jams outward.
local function initialFill()
	local attempts = 0
	while #cars < TrafficConfig.MaxCars and attempts < TrafficConfig.MaxCars * 20 do
		attempts += 1
		local route = pickRoute()
		local s = rng:NextNumber(0, math.max(0, route.Path.Length - 2))
		local position = TrafficPath.Sample(route.Path, s, 1)
		if isClear(position, 26) then
			placeCar(takeCar(), route, s, rng:NextNumber(0, TrafficConfig.CruiseSpeed))
		end
	end
end

--=============================================================================
-- Per frame
--=============================================================================

local moveParts, moveCFrames = {}, {}
local senseTimer, spawnTimer = 0, 0

local function step(dt)
	local now = os.clock()

	-- Movement.
	for _, car in cars do
		local path = car.Route.Path
		local remaining = path.Length - car.S

		local target = TrafficConfig.CruiseSpeed
		if now < car.HoldUntil then
			target = 0
		else
			-- Slow for corners ahead: v^2 = cap^2 + 2*a*d.
			local cap, at = TrafficPath.UpcomingCap(path, car.S, 40, car.Cursor)
			if cap < math.huge then
				target = math.min(target, math.sqrt(cap * cap + 2 * TrafficConfig.Braking * 0.6 * at))
			end
			-- Stop for whatever is ahead, or the end of the route.
			local room = math.min(car.Limit, remaining)
			target = math.min(target, math.sqrt(2 * TrafficConfig.Braking * 0.7 * math.max(0, room)))
		end

		local previous = car.Speed
		if target > previous then
			car.Speed = math.min(target, previous + TrafficConfig.Acceleration * dt)
		else
			car.Speed = math.max(target, previous - TrafficConfig.Braking * 2 * dt)
		end

		local travel = car.Speed * dt
		car.Limit -= travel
		car.S = math.min(path.Length, car.S + travel)

		if car.Speed < 0.5 then
			car.StoppedFor += dt
		else
			if car.StoppedFor > 0 then
				rollHonkDelays(car)
			end
			car.StoppedFor = 0
		end
		setBrakeLights(car, car.Speed < 0.5 or car.Speed < previous - 0.2 * dt * TrafficConfig.Braking)

		local position, direction, cursor = TrafficPath.Sample(path, car.S, car.Cursor)
		car.Cursor = cursor
		local aheadPosition = TrafficPath.Sample(path, car.S + AHEAD_SAMPLE, cursor)
		local look = aheadPosition - position
		if look.Magnitude < 0.5 then
			look = direction
		end
		look = flat(look).Unit
		car.Position = position
		car.Forward = look
		car.Right = Vector3.new(-look.Z, 0, look.X)

		local centre = position + Vector3.new(0, TrafficConfig.RoadY + car.Height, 0)
		local cf = CFrame.lookAt(centre, centre + look)
		if car.Bump then
			local offset, yaw = bumpOffset(car, now)
			if offset then
				cf = (cf + offset) * CFrame.Angles(0, yaw, 0)
			end
		end

		if cf ~= car.LastCFrame then
			car.LastCFrame = cf
			local parts, offsets = car.Parts, car.Offsets
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

	senseTimer += dt
	if senseTimer >= SENSE_INTERVAL then
		senseTimer = 0
		sense(now)

		-- Recycling, checked at the sensing rate.
		for i = #cars, 1, -1 do
			local car = cars[i]
			-- Any car waiting in a queue, not just the front one: routes feed
			-- their jams faster than one car at a time could drain them, and
			-- a hidden queue shrinking from the middle is never seen.
			local atEnd = car.Route.Path.Length - car.S < 0.5
			local queued = atEnd or (car.Leader and not car.LeaderIsPlayer)
			local done = (queued and car.StoppedFor > car.EndWait)
				or car.StoppedFor > TrafficConfig.StuckRecycleSeconds
			if done and isHidden(car.Position) then
				recycle(i)
			end
		end
	end

	spawnTimer += dt
	if spawnTimer >= TrafficConfig.SpawnInterval then
		spawnTimer = 0
		trySpawn()
	end
end

initialFill()
RunService.Heartbeat:Connect(step)

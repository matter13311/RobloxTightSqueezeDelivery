-- The traffic simulation: where every NPC car is, how fast it's going, what
-- it's waiting for. No Instances - TrafficServer.server.luau feeds it the
-- world (player vehicles, who can see what) and turns its state into
-- snapshots; clients draw the result.
--
-- A car is a route index plus a distance along that route (TrafficPath).
-- Routes are closed circuits, so cars circulate rather than queue at a dead
-- end; each circuit holds up to its Cap, which is how the map gets busier the
-- further it is from the depot. Cars are only created or recycled where no
-- player can see it happen. See TrafficConfig for the routes.
--
-- LANE CHANGES. A car follows its route's line, plus a sideways offset
-- (car.Lane, + = to its left). On a route with `Lanes` (Market Ave, which has
-- two lanes each way) a car that is held up - by a slow or stopped car, a
-- player, or roadworks - moves over into the other lane if that lane is clear
-- ahead and alongside, and drifts back to its own lane only once its own lane
-- is clear. It never sits straddling the line waiting for a gap: a change is
-- only started when the target lane is already free. Outside the route's lane
-- boxes (junctions, turn-arounds) it always returns to the route line. The
-- check only runs for cars that are actually held up, so it costs next to
-- nothing when traffic is flowing.
--
-- A lane change is DRIVEN, never slid: the sideways offset follows an S-curve
-- over a stretch of forward travel (steer out, cross, straighten), and it
-- only advances as the car moves forward, so a stopped car never drifts
-- sideways. A car boxed in behind something steers out more sharply over a
-- shorter stretch, and senses what is ahead from where its NOSE will be, so
-- it can pull out of a queue rather than wait behind the thing it is
-- steering round. Cars on lane routes also stop a little further back
-- (LaneStopGap) to leave themselves room to pull out, like real drivers do.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrafficPath = require(ReplicatedStorage.Modules.Traffic.TrafficPath)

local TrafficSim = {}
TrafficSim.__index = TrafficSim

local SENSE_INTERVAL = 0.1
local AHEAD_SAMPLE = 4 -- studs ahead of the centre a car points at, smooths corners

-- Lane changes: forward studs of travel per stud of sideways offset when the
-- road ahead is open, and the shortest stretch a boxed-in car will use.
local LANE_STUDS_PER_OFFSET = 3.6
local LANE_MIN_LENGTH = 16
-- Extra stopping distance on lane routes, so a car queued behind something
-- has room to steer out of the queue.
local LANE_STOP_GAP = 8

-- 0..1 -> 0..1 with zero slope at both ends: steer out, then straighten.
local function smoothstep(t)
	return t * t * (3 - 2 * t)
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- templates: array of { HalfLength, HalfWidth, Weight, Routes }, in
-- TrafficNet.SortedTemplates order. Weight (default 1) is how often it is
-- picked; Routes, if set, is a plain substring a route's Name must contain
-- (the buses and big trucks only run the "Market" circuits, whose 12-stud
-- lanes have no kerb parking for them to clip).
-- maxCars: already capped to what a snapshot can carry.
function TrafficSim.new(config, templates, maxCars)
	local self = setmetatable({}, TrafficSim)
	self.Config = config
	self.Templates = templates
	self.MaxCars = maxCars
	self.Rng = Random.new()
	self.Cars = {}
	self.ById = {}
	self.NextId = 0
	self.SenseTimer = 0
	self.SpawnTimer = 0

	self.Routes = {}
	for index, route in config.Routes do
		local path = TrafficPath.Build(config, route)
		table.insert(self.Routes, {
			Index = index,
			Name = route.Name,
			Closed = route.Closed,
			Cap = route.Cap or 4,
			Count = 0,
			Path = path,
			KeepClear = TrafficSim.KeepClearIntervals(path, config.KeepClear or {}),
			Lanes = route.Lanes,
		})
	end
	-- Permanent obstacles (roadworks), as oriented boxes in the same shape as
	-- the per-tick obstacles from the server.
	self.Static = {}
	for _, r in config.Static or {} do
		table.insert(self.Static, {
			Position = Vector3.new((r[1] + r[3]) / 2, 0, (r[2] + r[4]) / 2),
			Look = Vector3.zAxis,
			Right = Vector3.xAxis,
			HalfLength = (r[4] - r[2]) / 2,
			HalfWidth = (r[3] - r[1]) / 2,
			Static = true,
		})
	end
	return self
end

-- The stretches of a route (as {StartS, EndS} along it, in order) where the
-- path runs through a TrafficConfig.KeepClear box.
function TrafficSim.KeepClearIntervals(path, boxes)
	local intervals = {}
	local current = nil
	local s = 0
	while s <= path.Length do
		local point = TrafficPath.Sample(path, s, 1)
		local inside = false
		for _, box in boxes do
			if point.X >= box[1] and point.X <= box[3] and point.Z >= box[2] and point.Z <= box[4] then
				inside = true
				break
			end
		end
		if inside and not current then
			current = { StartS = s, EndS = s }
		elseif inside then
			current.EndS = s
		elseif current then
			table.insert(intervals, current)
			current = nil
		end
		s += 1
	end
	if current then
		table.insert(intervals, current)
	end
	return intervals
end

-- Shrinks `room` so a car never comes to rest across an alley exit: if where
-- it would stop overlaps a keep-clear stretch it hasn't entered yet, it stops
-- short of that stretch instead. A car already in one carries on through.
-- Returns the new room and whether a keep-clear stretch is what limited it.
local function applyKeepClear(car, room)
	local front = car.S + car.HalfLength
	local stopCentre = car.S + room
	for _, interval in car.Route.KeepClear do
		if interval.EndS + car.HalfLength < car.S then
			continue -- already past it (this lap, on a circuit)
		end
		if front > interval.StartS - 0.5 then
			continue -- already in it: keep going
		end
		if stopCentre - car.HalfLength >= interval.EndS then
			continue -- has room to get all the way through
		end
		if stopCentre + car.HalfLength <= interval.StartS then
			return room, false -- stops before this one anyway
		end
		return math.max(0, interval.StartS - 1 - front), true
	end
	return room, false
end

function TrafficSim:_rand(min, max)
	return self.Rng:NextNumber(min, max)
end

-- A route with room on it, chosen in proportion to how far below its cap it
-- is. Caps are the difficulty curve: deep circuits hold more cars.
function TrafficSim:_pickRoute()
	local total = 0
	for _, route in self.Routes do
		total += math.max(0, route.Cap - route.Count)
	end
	if total <= 0 then
		return nil
	end
	local roll = self.Rng:NextNumber(0, total)
	for _, route in self.Routes do
		roll -= math.max(0, route.Cap - route.Count)
		if roll <= 0 then
			return route
		end
	end
	return nil
end

function TrafficSim:_nextId()
	-- u16 on the wire. Wrapping is fine as long as the id isn't still in use;
	-- a client that sees an id change route or template treats it as a new car.
	repeat
		self.NextId = self.NextId % 65535 + 1
	until not self.ById[self.NextId]
	return self.NextId
end

function TrafficSim:_rollHonkDelays(car)
	local config = self.Config
	car.PlayerHonkDelay = self:_rand(config.HonkAtPlayerDelayMin, config.HonkAtPlayerDelayMax)
	car.QueueHonkDelay = self:_rand(config.HonkInQueueDelayMin, config.HonkInQueueDelayMax)
end

-- A body for a new car on `route`, weighted, from the templates allowed there.
function TrafficSim:_pickTemplate(route)
	local total = 0
	for _, t in self.Templates do
		if not t.Routes or string.find(route.Name, t.Routes, 1, true) then
			total += t.Weight or 1
		end
	end
	local roll = self.Rng:NextNumber(0, total)
	local last = 1
	for index, t in self.Templates do
		if not t.Routes or string.find(route.Name, t.Routes, 1, true) then
			last = index
			roll -= t.Weight or 1
			if roll <= 0 then
				return index
			end
		end
	end
	return last
end

-- Extra spawn clearance for a body longer than an ordinary car.
function TrafficSim:_extraClearance(templateIndex)
	return math.max(0, self.Templates[templateIndex].HalfLength - 9.5) * 2
end

function TrafficSim:_place(route, s, speed, templateIndex)
	templateIndex = templateIndex or self:_pickTemplate(route)
	local template = self.Templates[templateIndex]
	local position, direction = TrafficPath.Sample(route.Path, s, 1)
	local car = {
		Id = self:_nextId(),
		Route = route,
		RouteIndex = route.Index,
		TemplateIndex = templateIndex,
		HalfLength = template.HalfLength,
		HalfWidth = template.HalfWidth,
		S = s,
		Cursor = 1,
		Speed = speed,
		Limit = math.huge,
		Room = math.huge,
		Braking = false,
		Leader = nil,
		LeaderIsPlayer = false,
		StoppedFor = 0,
		EndWait = self:_rand(self.Config.QueueWaitMin, self.Config.QueueWaitMax),
		NextHonkAt = 0,
		HoldUntil = 0,
		LastBump = 0,
		Position = position,
		Base = position,
		Forward = direction,
		Right = Vector3.new(-direction.Z, 0, direction.X),
		Lane = 0,
		LaneTarget = 0,
		LaneSince = 0,
		-- the change in progress: from which offset, how far along (0..1) and
		-- over how many studs of forward travel
		LaneFrom = 0,
		LaneGoal = 0,
		LaneProgress = 1,
		LaneLength = LANE_MIN_LENGTH,
	}
	self:_rollHonkDelays(car)
	route.Count += 1
	table.insert(self.Cars, car)
	self.ById[car.Id] = car
	return car
end

function TrafficSim:_remove(index)
	local cars = self.Cars
	local car = cars[index]
	cars[index] = cars[#cars]
	cars[#cars] = nil
	car.Route.Count -= 1
	self.ById[car.Id] = nil
end

--=============================================================================
-- Sensing
--=============================================================================

-- Bumper-to-bumper gap to an oriented box if it is in this car's lane ahead
-- of it, else nil.
function TrafficSim:_gapTo(car, position, look, right, halfLength, halfWidth)
	local config = self.Config
	local d = position - (car.SensePosition or car.Position)
	local ahead = d:Dot(car.Forward)
	if ahead <= 0 then
		return nil
	end
	local otherAlong = math.abs(look:Dot(car.Forward)) * halfLength + math.abs(right:Dot(car.Forward)) * halfWidth
	if ahead - otherAlong > config.LookAhead + car.HalfLength then
		return nil
	end
	local otherAcross = math.abs(look:Dot(car.Right)) * halfLength + math.abs(right:Dot(car.Right)) * halfWidth
	if math.abs(d:Dot(car.Right)) > car.HalfWidth + otherAcross + config.LateralSlack then
		return nil
	end
	return ahead - car.HalfLength - otherAlong
end

-- obstacles: array of { Position, Look, Right, HalfLength, HalfWidth } (flat)
-- tryHonk(car, pattern) -> bool
function TrafficSim:_sense(now, obstacles, tryHonk)
	local config = self.Config
	local cars = self.Cars

	for _, car in cars do
		-- Mid lane change, look ahead from where the nose will be once it has
		-- covered the stopping distance, not from the body's current offset:
		-- otherwise a car pulling out from behind a stopped car keeps
		-- "seeing" it and can never move forward to finish the manoeuvre.
		car.SensePosition = nil
		if car.LaneProgress < 1 then
			local p = math.min(1, car.LaneProgress + (car.HalfLength + config.StopGap) / car.LaneLength)
			local noseLane = car.LaneFrom + (car.LaneGoal - car.LaneFrom) * smoothstep(p)
			car.SensePosition = car.Base - car.Right * noseLane
		end
		local best, leader, leaderIsPlayer = math.huge, nil, false
		for _, other in cars do
			if other ~= car and not (car.IgnoreCar == other and now < car.IgnoreUntil) then
				local gap = self:_gapTo(car, other.Position, other.Forward, other.Right, other.HalfLength, other.HalfWidth)
				if gap and gap < best then
					best, leader, leaderIsPlayer = gap, other, false
				end
			end
		end
		for _, list in { obstacles, self.Static } do
			for _, obstacle in list do
				local gap = self:_gapTo(car, obstacle.Position, obstacle.Look, obstacle.Right, obstacle.HalfLength, obstacle.HalfWidth)
				if gap and gap < best then
					-- roadworks are not somebody to honk at
					best, leader, leaderIsPlayer = gap, obstacle, not obstacle.Static
				end
			end
		end
		car.Limit = best - config.StopGap - (if car.Route.Lanes then LANE_STOP_GAP else 0)
		car.SensePosition = nil
		car.Leader = leader
		car.LeaderIsPlayer = leaderIsPlayer
	end

	self:_lanes(now, obstacles)

	-- Two cars that each think the other is in the way (crossing paths at a
	-- junction) would wait forever. After a moment, the older one goes.
	for _, car in cars do
		local other = car.Leader
		if
			other
			and not car.LeaderIsPlayer
			and not other.Static
			and other.Leader == car
			and car.StoppedFor > 1.5
			and other.StoppedFor > 1.5
			and car.Id < other.Id
		then
			car.IgnoreCar = other
			car.IgnoreUntil = now + 3
		end
	end

	-- Patience at a merge. A car waiting to turn across or into a steady stream
	-- yields to it, which at a busy junction can mean waiting forever. After
	-- MergePatience it takes the gap and the through traffic brakes for it.
	for _, car in cars do
		local other = car.Leader
		if
			other
			and not car.LeaderIsPlayer
			and not other.Static
			and car.StoppedFor > config.MergePatience
			and car.Forward:Dot(other.Forward) < 0.7
		then
			car.IgnoreCar = other
			car.IgnoreUntil = now + 3
		end
	end

	for _, car in cars do
		if car.StoppedFor <= 0 or now < car.NextHonkAt or now < car.HoldUntil then
			continue
		end
		if car.LeaderIsPlayer then
			if car.StoppedFor > car.PlayerHonkDelay then
				local pattern = if self.Rng:NextNumber() < 0.5 then "double" else "tap"
				if tryHonk(car, pattern) then
					car.NextHonkAt = now + self:_rand(config.HonkCooldownMin, config.HonkCooldownMax)
				end
			end
		elseif car.StoppedFor > car.QueueHonkDelay then
			if self.Rng:NextNumber() < config.HonkInQueueChance and tryHonk(car, "tap") then
				car.NextHonkAt = now + self:_rand(config.HonkCooldownMin, config.HonkCooldownMax)
			end
			-- Whether or not it honked, wait a while before thinking about it again.
			car.QueueHonkDelay = car.StoppedFor + self:_rand(config.HonkInQueueDelayMin, config.HonkInQueueDelayMax)
		end
	end
end

--=============================================================================
-- Lane changes
--=============================================================================

local function inBoxes(boxes, p)
	for _, b in boxes do
		if p.X >= b[1] and p.X <= b[3] and p.Z >= b[2] and p.Z <= b[4] then
			return true
		end
	end
	return false
end

-- Is the lane at sideways offset `offset` clear for `car`: nothing within
-- `ahead` studs in front or `behind` studs behind (bumper to bumper)?
function TrafficSim:_laneClear(car, offset, ahead, behind, obstacles)
	local p = car.Base - car.Right * offset
	local function blocks(position, look, right, halfLength, halfWidth)
		local d = position - p
		local across = math.abs(d:Dot(car.Right))
		local otherAcross = math.abs(look:Dot(car.Right)) * halfLength + math.abs(right:Dot(car.Right)) * halfWidth
		if across > car.HalfWidth + otherAcross + 0.8 then
			return false
		end
		local along = d:Dot(car.Forward)
		local otherAlong = math.abs(look:Dot(car.Forward)) * halfLength + math.abs(right:Dot(car.Forward)) * halfWidth
		local gap = math.abs(along) - car.HalfLength - otherAlong
		if along >= 0 then
			return gap < ahead
		end
		return gap < behind
	end
	for _, other in self.Cars do
		if other ~= car and blocks(other.Position, other.Forward, other.Right, other.HalfLength, other.HalfWidth) then
			return false
		end
	end
	for _, list in { obstacles, self.Static } do
		for _, o in list do
			if blocks(o.Position, o.Look, o.Right, o.HalfLength, o.HalfWidth) then
				return false
			end
		end
	end
	return true
end

function TrafficSim:_lanes(now, obstacles)
	for _, car in self.Cars do
		local lanes = car.Route.Lanes
		if not lanes then
			continue
		end
		-- only on the multi-lane stretches, and not starting a change right
		-- before one ends (a junction or turn-around is coming)
		local here = inBoxes(lanes.Boxes, car.Base)
		local ahead = here and inBoxes(lanes.Boxes, car.Base + car.Forward * 45)
		if not here then
			car.LaneTarget = 0
			continue
		end
		local leader = car.Leader
		local heldUp = leader ~= nil
			and car.Limit < 30
			and (car.LeaderIsPlayer or leader.Static or leader.Speed < 10 or (leader.StoppedFor or 0) > 0.5)
		if car.LaneTarget == 0 then
			if heldUp and ahead and self:_laneClear(car, lanes.Offset, 30, 10, obstacles) then
				car.LaneTarget = lanes.Offset
				car.LaneSince = now
			end
		elseif now - car.LaneSince > 3 then
			-- back to its own lane once that is free (it never waits across
			-- the line for it: until then it simply stays where it is)
			if not ahead or self:_laneClear(car, 0, 40, 10, obstacles) then
				car.LaneTarget = 0
				car.LaneSince = now
			end
		end
	end
end

--=============================================================================
-- Public
--=============================================================================

-- Fill the streets at start so the city doesn't begin empty.
-- isClear(position, clearance) -> bool, for anything the sim doesn't own.
function TrafficSim:Fill(isClear)
	local attempts = 0
	while #self.Cars < self.MaxCars and attempts < self.MaxCars * 20 do
		attempts += 1
		local route = self:_pickRoute()
		if not route then
			break
		end
		local s = self.Rng:NextNumber(0, math.max(0, route.Path.Length - 2))
		local position = TrafficPath.Sample(route.Path, s, 1)
		local templateIndex = self:_pickTemplate(route)
		local clearance = 26 + self:_extraClearance(templateIndex)
		if self:IsClear(position, clearance) and isClear(position, clearance) then
			self:_place(route, s, self.Rng:NextNumber(0, self.Config.CruiseSpeed), templateIndex)
		end
	end
end

function TrafficSim:IsClear(position, clearance)
	for _, car in self.Cars do
		if (car.Position - position).Magnitude < clearance then
			return false
		end
	end
	return true
end

-- A player's vehicle hit car `id`. Returns the car if the bump was applied.
function TrafficSim:Bump(id, now)
	local car = self.ById[id]
	if not car or now - car.LastBump < 0.4 then
		return nil
	end
	car.LastBump = now
	car.Speed = 0
	car.HoldUntil = now + self:_rand(self.Config.BumpHoldMin, self.Config.BumpHoldMax)
	return car
end

-- world = {
--   GetObstacles = function() -> obstacles (see _sense), called at the sensing rate
--   IsHidden = function(position) -> bool, true if no player can see it
--   IsClear = function(position, clearance) -> bool, for player vehicles
--   TryHonk = function(car, pattern) -> bool
-- }
function TrafficSim:Step(dt, now, world)
	local config = self.Config

	for _, car in self.Cars do
		local path = car.Route.Path
		-- A closed circuit has no end to stop at.
		local remaining = if car.Route.Closed then math.huge else path.Length - car.S

		local target = config.CruiseSpeed
		local room = math.min(car.Limit, remaining)
		room, car.HeldByKeepClear = applyKeepClear(car, room)
		if now < car.HoldUntil then
			target = 0
			room = 0
		else
			-- Slow for corners ahead: v^2 = cap^2 + 2*a*d.
			local cap, at = TrafficPath.UpcomingCap(path, car.S, 40, car.Cursor)
			if cap < math.huge then
				target = math.min(target, math.sqrt(cap * cap + 2 * config.Braking * 0.6 * at))
			end
			target = math.min(target, math.sqrt(2 * config.Braking * 0.7 * math.max(0, room)))
		end

		local previous = car.Speed
		if target > previous then
			car.Speed = math.min(target, previous + config.Acceleration * dt)
		else
			car.Speed = math.max(target, previous - config.Braking * 2 * dt)
		end

		-- Braking above is gradual, which is right for a queue seen coming. It
		-- is wrong for something that appears inside the stopping distance - a
		-- player cutting in: the car would roll on into it, and an anchored car
		-- rolling into a player's vehicle shoves it. So never move past the
		-- stopping point, even if that means stopping dead.
		local travel = math.min(car.Speed * dt, math.max(0, room))
		if dt > 0 and travel < car.Speed * dt then
			car.Speed = travel / dt
		end
		car.Limit -= travel
		car.S += travel
		if car.Route.Closed then
			if car.S >= path.Length then
				car.S -= path.Length
				car.Cursor = 1
			end
		else
			car.S = math.min(path.Length, car.S)
		end
		car.Room = math.max(0, room - travel)

		if car.Speed < 0.5 then
			car.StoppedFor += dt
		else
			if car.StoppedFor > 0 then
				self:_rollHonkDelays(car)
			end
			car.StoppedFor = 0
		end
		-- Lit when it's stopped or actually wants to be slower, not for every
		-- small easing while following another car.
		car.Braking = car.Speed < 0.5 or target < previous - 2

		local position, direction, cursor = TrafficPath.Sample(path, car.S, car.Cursor)
		car.Cursor = cursor
		local aheadPosition = TrafficPath.Sample(path, car.S + AHEAD_SAMPLE, cursor)
		local look = aheadPosition - position
		if look.Magnitude < 0.5 then
			look = direction
		end
		look = flat(look).Unit
		car.Forward = look
		car.Right = Vector3.new(-look.Z, 0, look.X)
		car.Base = position
		if car.LaneTarget ~= car.LaneGoal then
			-- a new change (or a change of mind part-way): start a fresh
			-- S-curve from wherever the car is now
			local offset = math.abs(car.LaneTarget - car.Lane)
			car.LaneFrom = car.Lane
			car.LaneGoal = car.LaneTarget
			car.LaneProgress = if offset < 0.05 then 1 else 0
			-- the open-road length, cut short when boxed in (but never so
			-- short it becomes a sideways hop)
			local open = math.max(LANE_MIN_LENGTH, offset * LANE_STUDS_PER_OFFSET)
			car.LaneLength = math.clamp(math.max(0, car.Limit) + LANE_MIN_LENGTH, LANE_MIN_LENGTH, open)
		end
		if car.LaneProgress < 1 then
			-- only forward travel moves it across
			car.LaneProgress = math.min(1, car.LaneProgress + travel / car.LaneLength)
			car.Lane = car.LaneFrom + (car.LaneGoal - car.LaneFrom) * smoothstep(car.LaneProgress)
			if car.LaneProgress >= 1 then
				car.Lane = car.LaneGoal
			end
		end
		car.Position = position - car.Right * car.Lane
	end

	self.SenseTimer += dt
	if self.SenseTimer >= SENSE_INTERVAL then
		self.SenseTimer = 0
		self:_sense(now, world.GetObstacles(), world.TryHonk)

		for i = #self.Cars, 1, -1 do
			local car = self.Cars[i]
			-- Any car waiting in a queue, not just the front one: routes feed
			-- their jams faster than one car at a time could drain them, and a
			-- hidden queue shrinking from the middle is never seen.
			local atEnd = not car.Route.Closed and car.Route.Path.Length - car.S < 0.5
			local queued = atEnd or car.HeldByKeepClear or (car.Leader and not car.LeaderIsPlayer)
			local done = (queued and car.StoppedFor > car.EndWait) or car.StoppedFor > config.StuckRecycleSeconds
			if done and world.IsHidden(car.Position) then
				self:_remove(i)
			end
		end
	end

	self.SpawnTimer += dt
	if self.SpawnTimer >= config.SpawnInterval then
		self.SpawnTimer = 0
		if #self.Cars < self.MaxCars then
			local route = self:_pickRoute()
			if route then
				-- On a circuit there is no single entry point, so try a few
				-- places around it and take the first one nobody can see.
				local tries = if route.Closed then 6 else 1
				local templateIndex = self:_pickTemplate(route)
				local clearance = config.SpawnClearance + self:_extraClearance(templateIndex)
				for _ = 1, tries do
					local s = if route.Closed then self.Rng:NextNumber(0, route.Path.Length) else 0
					local point = TrafficPath.Sample(route.Path, s, 1)
					if
						world.IsHidden(point)
						and self:IsClear(point, clearance)
						and world.IsClear(point, clearance)
					then
						self:_place(route, s, config.CruiseSpeed * 0.6, templateIndex)
						break
					end
				end
			end
		end
	end
end

return TrafficSim

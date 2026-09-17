-- Turns a TrafficConfig route (a list of {x, z} corner points) into a dense
-- polyline a car can be placed on by distance.
--
-- Corners are rounded with a circular arc so cars turn instead of snapping.
-- Arcs are sampled every ARC_STEP studs and straights are left as two points,
-- so a route is a few dozen samples; a car keeps a cursor into them and never
-- searches.

local TrafficPath = {}

local ARC_STEP = 1.5

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- config: TrafficConfig. route: one entry of TrafficConfig.Routes.
-- Returns {
--   Points = { Vector3 },     -- Y = 0
--   Dist = { number },        -- cumulative distance to each point
--   SpeedCap = { number },    -- speed limit on the segment starting at each point
--   Length = number,
-- }
function TrafficPath.Build(config, route)
	local corners = {}
	for _, p in route.Points do
		table.insert(corners, Vector3.new(p[1], 0, p[2]))
	end

	local points = { corners[1] }
	local caps = {}
	local function push(point, cap)
		-- Two arcs can meet exactly (a short straight shared by both); a
		-- zero-length segment would have no direction.
		if (point - points[#points]).Magnitude < 0.01 then
			return
		end
		caps[#points] = cap
		table.insert(points, point)
	end

	for i = 2, #corners - 1 do
		local prev, corner, nextPoint = corners[i - 1], corners[i], corners[i + 1]
		local inDir = flat(corner - prev).Unit
		local outDir = flat(nextPoint - corner).Unit
		local turn = math.acos(math.clamp(inDir:Dot(outDir), -1, 1))
		if turn < 1e-3 then
			push(corner, config.CruiseSpeed)
			continue
		end

		-- In Roblox's top-down XZ plane (+X east, +Z south), this cross product
		-- is positive for a right turn.
		local cross = inDir.X * outDir.Z - inDir.Z * outDir.X
		local isSharp = turn > math.rad(60)
		local radius = if not isSharp
			then config.GentleTurnRadius
			elseif cross > 0 then config.RightTurnRadius
			else config.LeftTurnRadius

		-- Tangent length, capped so an arc never eats more than half of either
		-- neighbouring straight (a lane change's short diagonal, mostly).
		local maxTangent = math.min((corner - prev).Magnitude, (nextPoint - corner).Magnitude) * 0.5
		local tangent = math.min(radius * math.tan(turn / 2), maxTangent)
		radius = tangent / math.tan(turn / 2)

		local arcStart = corner - inDir * tangent
		local arcEnd = corner + outDir * tangent
		local side = if cross > 0 then 1 else -1
		-- Right-hand normal of the incoming direction, flipped for a left turn.
		local normal = Vector3.new(-inDir.Z, 0, inDir.X) * side
		local centre = arcStart + normal * radius
		local cap = if isSharp
			then config.TurnSpeed
			elseif turn > math.rad(30) then config.GentleTurnSpeed
			else config.CruiseSpeed

		push(arcStart, config.CruiseSpeed)
		local fromCentre = arcStart - centre
		local steps = math.max(2, math.ceil(radius * turn / ARC_STEP))
		for s = 1, steps do
			local angle = turn * s / steps * side
			local c, sn = math.cos(angle), math.sin(angle)
			-- Rotation about +Y by `angle` (positive = clockwise seen from above,
			-- which is a right turn in this plane).
			local rotated = Vector3.new(fromCentre.X * c - fromCentre.Z * sn, 0, fromCentre.X * sn + fromCentre.Z * c)
			push(centre + rotated, cap)
		end
		-- Snap the last sample exactly onto the outgoing straight.
		points[#points] = arcEnd
	end
	push(corners[#corners], config.CruiseSpeed)
	caps[#points] = 0

	local dist = { 0 }
	for i = 2, #points do
		dist[i] = dist[i - 1] + (points[i] - points[i - 1]).Magnitude
	end

	return {
		Points = points,
		Dist = dist,
		SpeedCap = caps,
		Length = dist[#dist],
	}
end

-- Position and forward direction at distance s. `cursor` is the index to
-- start scanning from (a car's s only increases, so it only moves forward).
-- Returns position, direction, new cursor.
function TrafficPath.Sample(path, s, cursor)
	local points, dist = path.Points, path.Dist
	local i = math.max(1, cursor or 1)
	local last = #points
	if s >= path.Length then
		local dir = (points[last] - points[last - 1]).Unit
		return points[last], dir, last - 1
	end
	while i < last - 1 and dist[i + 1] <= s do
		i += 1
	end
	local a, b = points[i], points[i + 1]
	local segLen = dist[i + 1] - dist[i]
	local t = if segLen > 0 then (s - dist[i]) / segLen else 0
	return a:Lerp(b, t), (b - a).Unit, i
end

-- The lowest speed cap between s and s + ahead, so a car slows BEFORE a
-- corner rather than inside it. Also returns the distance to that cap.
function TrafficPath.UpcomingCap(path, s, ahead, cursor)
	local dist, caps = path.Dist, path.SpeedCap
	local lowest, at = caps[cursor] or math.huge, 0
	local i = cursor + 1
	while i <= #dist and dist[i] <= s + ahead do
		if caps[i] and caps[i] < lowest then
			lowest, at = caps[i], dist[i] - s
		end
		i += 1
	end
	return lowest, at
end

return TrafficPath

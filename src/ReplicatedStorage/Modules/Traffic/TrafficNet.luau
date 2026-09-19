-- The wire format between TrafficServer.server.luau and
-- TrafficController.client.luau, plus the remote names both sides agree on.
--
-- The server owns the traffic; clients only draw it. Several times a second
-- the server sends ONE snapshot buffer describing every car. A car is fully
-- described by which route it is on and how far along it is, because both
-- sides build the identical paths from TrafficConfig - so a car costs 11
-- bytes, and 42 of them fit comfortably under an UnreliableRemoteEvent's
-- ~900 byte payload limit; past that a snapshot is split into chunks that
-- share a sequence number. Snapshots are full, never deltas, so a dropped one
-- costs nothing and a player who just joined is up to date on the next.
--
-- Header: f64 server time, u8 cars in this chunk, u8 sequence, u8 chunk index,
-- u8 chunk count. Per car:
--   u16 id
--   u8  route index (TrafficConfig.Routes order)
--   u8  template index (ReplicatedStorage.TrafficCars children sorted by Name)
--   u16 s        - distance along the route, 1/16 stud
--   u16 room     - how much further it may go before stopping, 1/16 stud,
--                 capped at MaxRoom, which means "no limit"
--   u8  speed    - studs/s, 1/4 stud
--   u8  flags    - bit 0 braking

local TrafficNet = {}

TrafficNet.SnapshotRemote = "TrafficSnapshot" -- UnreliableRemoteEvent, server -> clients
TrafficNet.EventRemote = "TrafficEvent" -- RemoteEvent, server -> clients: honks and bumps
TrafficNet.BumpRemote = "TrafficBump" -- RemoteEvent, client -> server: "I hit car N"
TrafficNet.CameraRemote = "TrafficCamera" -- UnreliableRemoteEvent, client -> server: where I'm looking

local HEADER_BYTES = 12
local CAR_BYTES = 11
-- An UnreliableRemoteEvent payload has to stay under ~900 bytes, so a snapshot
-- of more cars than this is split into several packets ("chunks") that share a
-- sequence number. The client applies each chunk as it arrives and only decides
-- which cars have gone once it has the whole set.
TrafficNet.MaxCarsPerChunk = 70
-- Total cars the format allows: 4 chunks' worth, far more than the simulation
-- is tuned for.
TrafficNet.MaxCars = 280

local FLAG_BRAKING = 1

-- Cap on the "how much further it may go" field. A car with nothing in front
-- of it has effectively unlimited room, and sending that as a huge number
-- breaks the client's wrap-around maths on a closed circuit: once the value
-- exceeds the circuit's length, the distance "round the loop" to the stop
-- point comes out as behind the car, which reads as no room at all and the car
-- can only move by snapping. So room is capped here, and the client treats a
-- value at the cap as unlimited. It must stay well under half the shortest
-- circuit (~700 studs) and well over a car's braking distance (~25 studs).
TrafficNet.MaxRoom = 250

local function fixed16(value)
	return math.clamp(math.floor(value * 16 + 0.5), 0, 65535)
end

-- cars: array of { Id, RouteIndex, TemplateIndex, S, Room, Speed, Braking }
-- seq: a per-snapshot counter (wraps at 256) tying this snapshot's chunks
-- together. Returns an array of buffers to send.
function TrafficNet.Encode(serverTime, cars, seq)
	local total = math.min(#cars, TrafficNet.MaxCars)
	local chunkCount = math.max(1, math.ceil(total / TrafficNet.MaxCarsPerChunk))
	local chunks = table.create(chunkCount)
	local index = 1
	for chunk = 1, chunkCount do
		local count = math.min(TrafficNet.MaxCarsPerChunk, total - index + 1)
		local b = buffer.create(HEADER_BYTES + count * CAR_BYTES)
		buffer.writef64(b, 0, serverTime)
		buffer.writeu8(b, 8, count)
		buffer.writeu8(b, 9, seq % 256)
		buffer.writeu8(b, 10, chunk)
		buffer.writeu8(b, 11, chunkCount)
		local offset = HEADER_BYTES
		for _ = 1, count do
			local car = cars[index]
			index += 1
			buffer.writeu16(b, offset, car.Id)
			buffer.writeu8(b, offset + 2, car.RouteIndex)
			buffer.writeu8(b, offset + 3, car.TemplateIndex)
			buffer.writeu16(b, offset + 4, fixed16(car.S))
			buffer.writeu16(b, offset + 6, fixed16(math.min(car.Room, TrafficNet.MaxRoom)))
			buffer.writeu8(b, offset + 8, math.clamp(math.floor(car.Speed * 4 + 0.5), 0, 255))
			buffer.writeu8(b, offset + 9, if car.Braking then FLAG_BRAKING else 0)
			-- offset + 10 reserved
			offset += CAR_BYTES
		end
		chunks[chunk] = b
	end
	return chunks
end

-- Returns serverTime, entries, seq, chunkIndex, chunkCount - or nil for a
-- malformed buffer. Entries are { Id, RouteIndex, TemplateIndex, S, Room,
-- Speed, Braking }.
function TrafficNet.Decode(b)
	if typeof(b) ~= "buffer" or buffer.len(b) < HEADER_BYTES then
		return nil
	end
	local serverTime = buffer.readf64(b, 0)
	local count = buffer.readu8(b, 8)
	local seq = buffer.readu8(b, 9)
	local chunkIndex = buffer.readu8(b, 10)
	local chunkCount = buffer.readu8(b, 11)
	if buffer.len(b) < HEADER_BYTES + count * CAR_BYTES or chunkCount == 0 then
		return nil
	end
	local cars = table.create(count)
	local offset = HEADER_BYTES
	for i = 1, count do
		cars[i] = {
			Id = buffer.readu16(b, offset),
			RouteIndex = buffer.readu8(b, offset + 2),
			TemplateIndex = buffer.readu8(b, offset + 3),
			S = buffer.readu16(b, offset + 4) / 16,
			Room = buffer.readu16(b, offset + 6) / 16,
			Speed = buffer.readu8(b, offset + 8) / 4,
			Braking = bit32.band(buffer.readu8(b, offset + 9), FLAG_BRAKING) ~= 0,
		}
		offset += CAR_BYTES
	end
	return serverTime, cars, seq, chunkIndex, chunkCount
end

-- Both sides must index templates identically.
function TrafficNet.SortedTemplates(folder)
	local templates = folder:GetChildren()
	table.sort(templates, function(a, b)
		return a.Name < b.Name
	end)
	return templates
end

-- A car's horn pitch, derived from its id so every client hears the same one
-- without sending it.
function TrafficNet.HornPitch(config, id)
	local t = ((id * 7919) % 101) / 100
	return config.HornPitchMin + (config.HornPitchMax - config.HornPitchMin) * t
end

return TrafficNet

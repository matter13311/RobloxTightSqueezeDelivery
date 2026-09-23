-- Runs the NPC traffic for the whole server so every player sees the same
-- cars in the same places. The simulation is Modules/TrafficSim; the drawing
-- is TrafficController.client.luau; the wire format is Modules/Traffic/TrafficNet.
--
-- Why not just move server-owned parts: 40+ cars x several parts replicating
-- CFrames every frame is a lot of bandwidth, arrives choppy, and a player's
-- car would collide with wherever the part was a round-trip ago. Instead the
-- server sends each car as "route N, S studs along, going V" a few times a
-- second (~11 bytes a car, split across packets when there are many) and every
-- client moves its own local copy along the same path between snapshots. Players' cars collide with those local
-- copies, which are within a few studs of the server's.
--
-- The server is authoritative for everything that should look the same to
-- everyone: stopping for players, queues, honks, bumps and when a car is
-- recycled - which now waits until NO player's camera can see it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TrafficConfig = require(ReplicatedStorage.Modules.Traffic.TrafficConfig)
local TrafficNet = require(ReplicatedStorage.Modules.Traffic.TrafficNet)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local TrafficSim = require(script.Parent.Modules.TrafficSim)

local templatesFolder = ReplicatedStorage:FindFirstChild("TrafficCars")
if not templatesFolder then
	warn("[Traffic] ReplicatedStorage.TrafficCars is missing - no traffic this server")
	return
end
local VehicleFolder = workspace:WaitForChild("Vehicles")
-- A towed trailer is its own Model in workspace.Trailers (see TrailerHitch),
-- not a descendant of the tractor's Model in VehicleFolder - so without this,
-- NPCs only ever "see" the truck and happily drive into the trailer hanging
-- off the back of it until they're bumper-to-bumper with the cab.
local TrailerFolder = workspace:WaitForChild("Trailers")

local SNAPSHOT_INTERVAL = 0.1
-- A camera report older than this is ignored and the player's character is
-- used instead (distance only, no view direction).
local CAMERA_REPORT_STALE = 3
-- Extra angle on top of the camera's half field of view before a point counts
-- as off screen - a car's centre can be out of frame while its bumper isn't.
local VIEW_MARGIN = math.rad(20)
local ALWAYS_VISIBLE_DISTANCE = 60

local snapshotRemote = Instance.new("UnreliableRemoteEvent")
snapshotRemote.Name = TrafficNet.SnapshotRemote
snapshotRemote.Parent = ReplicatedStorage

local eventRemote = Instance.new("RemoteEvent")
eventRemote.Name = TrafficNet.EventRemote
eventRemote.Parent = ReplicatedStorage

local bumpRemote = Instance.new("RemoteEvent")
bumpRemote.Name = TrafficNet.BumpRemote
bumpRemote.Parent = ReplicatedStorage

local cameraRemote = Instance.new("UnreliableRemoteEvent")
cameraRemote.Name = TrafficNet.CameraRemote
cameraRemote.Parent = ReplicatedStorage

local templates = {}
for _, model in TrafficNet.SortedTemplates(templatesFolder) do
	local root = model.PrimaryPart
	table.insert(templates, {
		HalfLength = model:GetAttribute("HalfLength") or root.Size.Z / 2,
		HalfWidth = model:GetAttribute("HalfWidth") or root.Size.X / 2,
		Weight = model:GetAttribute("Weight") or 1,
		Routes = model:GetAttribute("Routes"),
	})
end

local sim = TrafficSim.new(TrafficConfig, templates, math.min(TrafficConfig.MaxCars, TrafficNet.MaxCars))

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

--=============================================================================
-- Who can see what
--=============================================================================

local cameras = {} -- [Player] = { Position, Look, CosLimit, At }

cameraRemote.OnServerEvent:Connect(function(player, cframe, fieldOfView, aspect)
	if typeof(cframe) ~= "CFrame" or type(fieldOfView) ~= "number" or type(aspect) ~= "number" then
		return
	end
	if fieldOfView ~= fieldOfView or aspect ~= aspect then
		return
	end
	fieldOfView = math.clamp(fieldOfView, 1, 120)
	aspect = math.clamp(aspect, 0.3, 4)
	-- Half angle to the corner of the screen: the widest a visible point can be
	-- from the view direction.
	local halfVertical = math.rad(fieldOfView) / 2
	local halfDiagonal = math.atan(math.tan(halfVertical) * math.sqrt(1 + aspect * aspect))
	cameras[player] = {
		Position = cframe.Position,
		Look = cframe.LookVector,
		CosLimit = math.cos(math.min(halfDiagonal + VIEW_MARGIN, math.rad(89))),
		At = os.clock(),
	}
end)

Players.PlayerRemoving:Connect(function(player)
	cameras[player] = nil
end)

-- Where each player's view is from: the reported camera if fresh, else the
-- character. Returns position, camera (or nil).
local function viewpoint(player, now)
	local camera = cameras[player]
	if camera and now - camera.At < CAMERA_REPORT_STALE then
		return camera.Position, camera
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root.Position, nil
end

local function isHidden(position)
	local now = os.clock()
	local raised = position + Vector3.new(0, 3, 0)
	for _, player in Players:GetPlayers() do
		local from, camera = viewpoint(player, now)
		if from then
			local offset = raised - from
			local distance = offset.Magnitude
			if distance < ALWAYS_VISIBLE_DISTANCE then
				return false
			end
			if distance <= TrafficConfig.HiddenDistance then
				-- No camera report: assume they could be looking anywhere.
				if not camera or camera.Look:Dot(offset / distance) > camera.CosLimit then
					return false
				end
			end
		end
	end
	return true
end

--=============================================================================
-- Player vehicles and pedestrians
--=============================================================================

local extentsCache = setmetatable({}, { __mode = "k" })

local function vehicleExtents(model)
	local size = extentsCache[model]
	if not size then
		size = model:GetExtentsSize()
		extentsCache[model] = size
	end
	return size
end

-- Shared by getObstacles and isClearOfVehicles' sibling loops below: one
-- oriented-box obstacle for any Model with a PrimaryPart, whether it's a
-- player's car in VehicleFolder or a trailer in TrailerFolder.
local function addModelObstacle(obstacles, model)
	local root = model:IsA("Model") and model.PrimaryPart
	if root then
		local size = vehicleExtents(model)
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

local function getObstacles()
	local obstacles = {}
	for _, model in VehicleFolder:GetChildren() do
		addModelObstacle(obstacles, model)
	end
	for _, model in TrailerFolder:GetChildren() do
		addModelObstacle(obstacles, model)
	end
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and humanoid and not humanoid.SeatPart and humanoid.Health > 0 then
			table.insert(obstacles, {
				Position = flat(root.Position),
				Look = Vector3.zAxis,
				Right = Vector3.xAxis,
				HalfLength = 1.5,
				HalfWidth = 1.5,
			})
		end
	end
	return obstacles
end

local function isClearOfVehicles(position, clearance)
	for _, model in VehicleFolder:GetChildren() do
		local root = model:IsA("Model") and model.PrimaryPart
		if root and (flat(root.Position) - position).Magnitude < clearance then
			return false
		end
	end
	for _, model in TrailerFolder:GetChildren() do
		local root = model:IsA("Model") and model.PrimaryPart
		if root and (flat(root.Position) - position).Magnitude < clearance then
			return false
		end
	end
	return true
end

--=============================================================================
-- Horn
--=============================================================================

local lastHonkHeard = {} -- [Player] = os.clock()

Players.PlayerRemoving:Connect(function(player)
	lastHonkHeard[player] = nil
end)

-- A honk is only worth playing if somebody is close enough to hear it, and
-- never within HornGlobalGap of another honk that same player heard - so a
-- queue full of cars doesn't all go off at once for anyone.
local function tryHonk(car, pattern)
	local now = os.clock()
	local listeners = {}
	for _, player in Players:GetPlayers() do
		local from = viewpoint(player, now)
		if from and (from - car.Position).Magnitude <= TrafficConfig.HornAudibleDistance then
			if now - (lastHonkHeard[player] or 0) < TrafficConfig.HornGlobalGap then
				return false
			end
			table.insert(listeners, player)
		end
	end
	if #listeners == 0 then
		return false
	end
	for _, player in listeners do
		lastHonkHeard[player] = now
		eventRemote:FireClient(player, "honk", car.Id, pattern)
	end
	return true
end

--=============================================================================
-- Bumps
--=============================================================================

bumpRemote.OnServerEvent:Connect(function(player, id, relativeSpeed)
	if type(id) ~= "number" or type(relativeSpeed) ~= "number" or relativeSpeed ~= relativeSpeed then
		return
	end
	local car = sim.ById[id]
	if not car then
		return
	end

	-- Only the driver of a vehicle can report hitting something with it, and
	-- the vehicle has to actually be next to the car on the server.
	local vehicle = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	local root = vehicle and vehicle.PrimaryPart
	if not root then
		return
	end
	local size = vehicleExtents(vehicle)
	local reach = car.HalfLength + math.max(size.X, size.Z) / 2 + 12 + car.Speed * 0.3
	local away = flat(car.Position) - flat(root.Position)
	if away.Magnitude > reach then
		return
	end

	-- Trust the client's measurement only as far as the server's own view of
	-- how fast that vehicle is moving allows.
	local vehicleSpeed = flat(root.AssemblyLinearVelocity).Magnitude
	local speed = math.min(relativeSpeed, vehicleSpeed + car.Speed + 15)
	if speed < TrafficConfig.BumpMinSpeed then
		return
	end

	local now = os.clock()
	if not sim:Bump(id, now) then
		return
	end
	local direction = if away.Magnitude > 0.1 then away.Unit else car.Right
	local strength = math.clamp(speed / 35, 0.25, 1)
	local yawSign = if math.random() < 0.5 then -1 else 1
	eventRemote:FireAllClients("bump", id, direction.X, direction.Z, strength, yawSign, player)

	-- The bumped car always honks back at the player who hit it.
	car.NextHonkAt = 0
	if tryHonk(car, "long") then
		car.NextHonkAt = now + TrafficConfig.HonkCooldownMin
	end
end)

--=============================================================================
-- Run
--=============================================================================

local world = {
	GetObstacles = getObstacles,
	IsHidden = isHidden,
	IsClear = isClearOfVehicles,
	TryHonk = tryHonk,
}

sim:Fill(isClearOfVehicles)

local snapshotTimer = 0
local snapshotSeq = 0
RunService.Heartbeat:Connect(function(dt)
	sim:Step(dt, os.clock(), world)

	snapshotTimer += dt
	if snapshotTimer >= SNAPSHOT_INTERVAL then
		snapshotTimer = 0
		if #Players:GetPlayers() > 0 then
			-- More cars than fit one unreliable packet go out as several chunks
			-- sharing this sequence number.
			snapshotSeq += 1
			for _, chunk in TrafficNet.Encode(workspace:GetServerTimeNow(), sim.Cars, snapshotSeq) do
				snapshotRemote:FireAllClients(chunk)
			end
		end
	end
end)

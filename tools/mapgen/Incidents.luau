-- Street incidents: set pieces parked in the INNER lane of West St / East St
-- (the lane next to the alleys), so the side streets stop being a free run
-- round the busy Market Ave and the alleys become worth the squeeze.
--
--   crash      two cars nose-to-tail at an angle, glass, cones, a police car
--   breakdown  one car with hazards, smoke, and a warning triangle
--   roadblock  barriers across the lane, cones, ROAD CLOSED, a police car
--   delivery   a big box truck double-parked with hazards, crates on the kerb
--
-- WHERE THEY MAY GO (see Layout: each zone's Incidents list). Only on
-- stretches where no NPC circuit drives the inner lane - the "Block"
-- circuits use it between some cross roads (TrafficRoutes), and an NPC
-- queued behind a set piece forever would read as broken. The Ring circuits
-- use the MIDDLE lane, so every piece stays inside the inner-lane band
-- (|x| 273.5..288.6): NPCs keep flowing past it and the player squeezes
-- between it and them. Kept clear of cross roads, street alley mouths and
-- street-side driveways; parked cars on the far kerb are removed alongside,
-- so a box truck always has an 18-stud channel.
--
-- Built in each zone's LOCAL frame and pivoted into place, like the zones.
-- Runs as part of Main.Run, or on its own over an existing city:
--   require(game.ServerStorage.MapGen.Incidents).Run()

local CollectionService = game:GetService("CollectionService")

local U = require(script.Parent.Util)
local L = require(script.Parent.Layout)

local Incidents = {}

local LANE_X = 281.3 -- centre of the inner-lane band
local BAND_ROAD = 288.6 -- road-side edge of the band (the Ring lane starts past this)
local SIDEWALK_TOP = 0.5
local HAZARD_OFF = Color3.fromRGB(120, 60, 10)
local ORANGE = Color3.fromRGB(240, 110, 20)

local CIVILIAN = { "Blue Sedan", "Green Station Wagon", "Red Hatchback", "Blue Pickup", "Taxi" }

local function deco(props)
	props = props or {}
	props.CanCollide = props.CanCollide == true
	props.CanQuery = props.CanQuery == true
	props.CastShadow = props.CastShadow ~= false
	return props
end

-- ctx: { parent, side (-1 west / +1 east), fwd (direction the inner lane
-- drives), cars (kit Cars folder), props (kit Props folder) }
local function rotated(ctx, yawDeg)
	return CFrame.Angles(0, math.rad(yawDeg), 0):VectorToWorldSpace(ctx.fwd)
end

local function car(ctx, name, x, z, yawDeg)
	local template = ctx.cars:FindFirstChild(name)
	if not template then
		return nil
	end
	return U.place(template, ctx.parent, x, 0, z, rotated(ctx, yawDeg or 0))
end

local function hazards(model)
	local cf, size = model:GetBoundingBox()
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			U.part(model, "HazardLight", Vector3.new(0.9, 0.5, 0.25),
				cf * CFrame.new(sx * (size.X / 2 - 0.9), -size.Y * 0.12, sz * (size.Z / 2 + 0.02)),
				deco({ Material = Enum.Material.SmoothPlastic, Color = HAZARD_OFF, CastShadow = false }))
		end
	end
	CollectionService:AddTag(model, "StalledCar")
end

local function policeBar(model)
	local cf, size = model:GetBoundingBox()
	for i, sx in { -1, 1 } do
		local p = U.part(model, "PoliceLight", Vector3.new(2, 0.5, 1),
			cf * CFrame.new(sx * 1.1, size.Y / 2 + 0.25, 0.8), deco({ Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(40, 40, 46), CastShadow = false }))
		p:SetAttribute("Blue", i == 2)
	end
	CollectionService:AddTag(model, "StalledCar")
end

local function cone(ctx, x, z)
	U.part(ctx.parent, "Cone", Vector3.new(1.2, 2.4, 1.2), CFrame.new(x, 1.2, z), {
		Material = Enum.Material.SmoothPlastic, Color = ORANGE,
	})
	U.part(ctx.parent, "ConeStripe", Vector3.new(1.3, 0.35, 1.3), CFrame.new(x, 1.5, z), deco({ Material = Enum.Material.SmoothPlastic, Color = Color3.new(1, 1, 1) }))
end

-- a line of cones tapering from the kerb out to the band's road edge,
-- starting `from` studs behind z0 and `step` apart
local function taper(ctx, z0, from, count, step)
	for i = 0, count - 1 do
		local t = if count > 1 then i / (count - 1) else 1
		local x = ctx.side * (274.5 + (BAND_ROAD - 1 - 274.5) * t)
		cone(ctx, x, z0 - ctx.fwd.Z * (from + (count - 1 - i) * step))
	end
end

local function board(ctx, text, x, z, color)
	local look = ctx.fwd
	local cf = CFrame.lookAt(Vector3.new(x, 3.4, z), Vector3.new(x, 3.4, z) + look)
	local p = U.part(ctx.parent, "IncidentSign", Vector3.new(6, 2.4, 0.2), cf, deco({ Material = Enum.Material.SmoothPlastic, Color = color }))
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		U.label(p, face, text, { PixelsPerStud = 20, TextColor3 = Color3.new(0, 0, 0) })
	end
	for _, dx in { -2.4, 2.4 } do
		U.part(ctx.parent, "SignLeg", Vector3.new(0.25, 2.3, 0.25), cf * CFrame.new(dx, -2.3, 0), deco({ Material = Enum.Material.Metal, Color = Color3.fromRGB(70, 72, 78) }))
	end
end

local function glass(ctx, x, z, radius, n)
	for _ = 1, n do
		U.part(ctx.parent, "Glass", Vector3.new(U.range(0.3, 0.9), 0.08, U.range(0.3, 0.9)),
			CFrame.new(x + U.range(-radius, radius), 0.05, z + U.range(-radius, radius)) * CFrame.Angles(0, U.range(0, 6.28), 0),
			deco({ Material = Enum.Material.Glass, Color = Color3.fromRGB(170, 200, 215), Transparency = 0.3, CastShadow = false }))
	end
end

local function triangle(ctx, x, z)
	local cf = CFrame.lookAt(Vector3.new(x, 1, z), Vector3.new(x, 1, z) + ctx.fwd)
	local p = U.part(ctx.parent, "WarningTriangle", Vector3.new(1.8, 1.6, 0.1), cf, deco({ Transparency = 1, CastShadow = false }))
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		U.label(p, face, "\u{25B2}", { PixelsPerStud = 30, TextColor3 = Color3.fromRGB(230, 30, 30) })
	end
end

local BUILD = {}

function BUILD.crash(ctx, z0)
	local f = ctx.fwd.Z
	local x = ctx.side * LANE_X
	local a = car(ctx, U.pick(CIVILIAN), x, z0 + f * 10, 12 * ctx.side)
	local b = car(ctx, U.pick(CIVILIAN), x + ctx.side * 0.6, z0 - f * 9, -9 * ctx.side)
	for _, m in { a, b } do
		if m then
			hazards(m)
		end
	end
	glass(ctx, x, z0, 4, 14)
	local police = car(ctx, "Police Car", x, z0 - f * 33, 0)
	if police then
		policeBar(police)
	end
	taper(ctx, z0, 46, 4, 6)
	board(ctx, "ACCIDENT", x, z0 - f * 66, Color3.fromRGB(240, 150, 20))
end

function BUILD.breakdown(ctx, z0)
	local f = ctx.fwd.Z
	local x = ctx.side * LANE_X
	local m = car(ctx, U.pick(CIVILIAN), x, z0, 5 * ctx.side)
	if m then
		hazards(m)
		local cf, size = m:GetBoundingBox()
		local vent = U.part(m, "Steam", Vector3.new(1, 0.2, 1), cf * CFrame.new(0, size.Y / 2 - 1, -size.Z / 2 + 3), deco({ Transparency = 1, CastShadow = false }))
		local smoke = Instance.new("Smoke")
		smoke.Color = Color3.fromRGB(200, 200, 200)
		smoke.Opacity = 0.18
		smoke.RiseVelocity = 3
		smoke.Size = 3
		smoke.Parent = vent
	end
	triangle(ctx, x, z0 - f * 17)
end

function BUILD.roadblock(ctx, z0)
	local f = ctx.fwd.Z
	local x = ctx.side * LANE_X
	local barrier = ctx.props:FindFirstChild("Barrier3")
	if barrier then
		for _, dx in { -3.6, 3.6 } do
			U.place(barrier, ctx.parent, x + dx, 0, z0, Vector3.new(1, 0, 0))
		end
	end
	board(ctx, "ROAD CLOSED", x, z0 - f * 2.2, Color3.fromRGB(235, 235, 230))
	local police = car(ctx, "Police Car", x, z0 + f * 14, 8 * ctx.side)
	if police then
		policeBar(police)
	end
	taper(ctx, z0, 9, 3, 7)
end

function BUILD.delivery(ctx, z0)
	local f = ctx.fwd.Z
	local x = ctx.side * (LANE_X + 0.3)
	local template = ctx.cars:FindFirstChild("Blue Box Truck")
	if not template then
		return
	end
	-- the kit's box truck is sedan-sized; the real delivery truck is 1.3x
	local big = template:Clone()
	big:ScaleTo(big:GetScale() * 1.3)
	local truck = U.place(big, ctx.parent, x, 0, z0, ctx.fwd)
	big:Destroy()
	hazards(truck)
	-- crates at the back of the truck and on the kerb
	local crate = ctx.props:FindFirstChild("wood_crate001a")
	local plastic = ctx.props:FindFirstChild("plasticcrate01a")
	local rear = z0 - f * 15
	if crate then
		U.place(crate, ctx.parent, x - ctx.side * 2, 0, rear, ctx.fwd)
		U.place(crate, ctx.parent, x + ctx.side * 2, 0, rear - f * 0.5, rotated(ctx, 20))
	end
	for k = 0, 2 do
		local t = if k == 1 and plastic then plastic else crate
		if t then
			local c = U.place(t, ctx.parent, ctx.side * 270, SIDEWALK_TOP, z0 - f * (6 + k * 4.5), rotated(ctx, k * 15))
			for _, d in (c:IsA("Model") and c:GetDescendants() or { c }) do
				if d:IsA("BasePart") then
					d.CanCollide = false
					d.CanTouch = false
				end
			end
		end
	end
	cone(ctx, ctx.side * (BAND_ROAD - 1), rear - f * 4)
end

-- zoneModel: the zone's built model (already pivoted to spec.Frame).
-- kitRoot: ServerStorage.MapKit.
function Incidents.Build(spec, zoneModel, kitRoot)
	local list = spec.Incidents
	if not list or #list == 0 then
		return 0
	end
	local traffic = U.folder(zoneModel, "Traffic")
	local old = traffic:FindFirstChild("Incidents")
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "Incidents"
	local frame = spec.Frame
	local parked = traffic:FindFirstChild("Parked")
	local count = 0
	for _, inc in list do
		local side = if inc.side == "West" then -1 else 1
		-- the inner lane: West St drives north (-Z), East St south (+Z)
		local fwd = Vector3.new(0, 0, side)
		local piece = U.model(model, inc.kind .. "_" .. inc.side .. "_" .. math.floor(math.abs(inc.z)))
		local ctx = { parent = piece, side = side, fwd = fwd, cars = kitRoot.Cars, props = kitRoot.Props }
		BUILD[inc.kind](ctx, inc.z)
		count += 1
		-- clear kerb parking on the same street alongside, so the channel
		-- past the piece is the whole rest of the road
		if parked then
			local _, size = piece:GetBoundingBox()
			local cf = piece:GetBoundingBox()
			local zc, half = cf.Z, size.Z / 2 + 25
			for _, pc in parked:GetChildren() do
				local p = frame:PointToObjectSpace(pc:GetPivot().Position)
				if math.sign(p.X) == side and math.abs(p.Z - zc) < half then
					pc:Destroy()
				end
			end
		end
	end
	model.WorldPivot = CFrame.new()
	model:PivotTo(frame)
	model.Parent = traffic
	return count
end

function Incidents.Run()
	local kitRoot = game:GetService("ServerStorage"):FindFirstChild("MapKit")
	local map = workspace:FindFirstChild("Map")
	assert(kitRoot and map, "needs ServerStorage.MapKit and a built Workspace.Map")
	local total = 0
	for _, spec in L.Zones do
		local zm = map:FindFirstChild(spec.Key)
		if zm and spec.Frame then
			total += Incidents.Build(spec, zm, kitRoot)
		end
	end
	return string.format("%d street incidents built", total)
end

return Incidents

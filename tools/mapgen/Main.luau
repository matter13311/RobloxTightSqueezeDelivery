-- Entry point. From the Studio command bar (Edit mode):
--
--   require(game.ServerStorage.MapGen.Main).Run()
--
-- Rebuilds workspace.Map, the garage plots, the loading/freight bays and the
-- destinations from Layout. The very first run (v3) moved the pre-zones city
-- into ServerStorage.CityV2_Backup; later runs simply replace the generated
-- city. The generated NPC traffic data is left in the MapKit attribute
-- "TrafficRoutesSource" - paste it into
-- src/ReplicatedStorage/Modules/Traffic/TrafficRoutes.luau.

local ServerStorage = game:GetService("ServerStorage")
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")

local U = require(script.Parent.Util)
local L = require(script.Parent.Layout)
local Style = require(script.Parent.Style)
local Zone = require(script.Parent.Zone)
local Connector = require(script.Parent.Connector)
local Terminal = require(script.Parent.Terminal)
local Traffic = require(script.Parent.Traffic)
local Incidents = require(script.Parent.Incidents)
local Bounds = require(script.Parent.Bounds)
local Backdrop = require(script.Parent.Backdrop)

local Main = {}

local BACKUP_NAME = "CityV2_Backup"
local FURNITURE = { "lamp", "tree", "bench", "bin", "hydrant", "news", "meter", "busstop", "bollard" }

-- The street lamps light the city after dark (see
-- StarterPlayerScripts.StreetLamps). Both the light itself and the tag the
-- client finds it by live on the KIT TEMPLATE, not on the placed copies:
-- Instance:Clone() carries tags and children, so every lamp U.place puts down
-- - in a zone, on a connector, this run or any future one - comes out already
-- lit and already tagged. That is what makes this survive a RunZones, which
-- destroys and rebuilds every placed lamp in the city.
--
-- The lamp head is Neon and has always looked lit; this is the light it never
-- actually cast. Enabled is false here because it is the client that decides
-- when a lamp is on - after dark, and only near the camera.
local function ensureLampLight(furniture)
	local lamp = furniture:FindFirstChild("lamp")
	if not lamp then
		return
	end
	CollectionService:AddTag(lamp, "StreetLamp")

	local head = lamp:FindFirstChild("LampHead", true)
	if not head or not head:IsA("BasePart") then
		return
	end
	if head:FindFirstChildWhichIsA("PointLight") then
		return -- already done on an earlier run
	end

	local bulb = Instance.new("PointLight")
	bulb.Name = "Bulb"
	bulb.Color = Color3.fromRGB(255, 226, 170)
	bulb.Brightness = 1.4
	bulb.Range = 34
	bulb.Shadows = false -- a lamp post casting its own shadow buys nothing and costs on every device
	bulb.Enabled = false
	bulb.Parent = head
end

local function ensureKit()
	local kit = ServerStorage:WaitForChild("MapKit")
	local templates = kit.Templates
	local backup = ServerStorage:FindFirstChild(BACKUP_NAME)
	local oldMap = backup and backup:FindFirstChild("Map")
	local furniture = templates:FindFirstChild("Furniture")
	if not furniture then
		furniture = Instance.new("Folder")
		furniture.Name = "Furniture"
		furniture.Parent = templates
	end
	if oldMap then
		for _, n in FURNITURE do
			if not furniture:FindFirstChild(n) then
				local m = oldMap.StreetFurniture:FindFirstChild(n)
				if m then
					m:Clone().Parent = furniture
				end
			end
		end
		if not furniture:FindFirstChild("TrafficLight") then
			local tl = oldMap.StreetFurniture.TrafficLights:FindFirstChildWhichIsA("Model")
			if tl then
				local c = tl:Clone()
				c.Name = "TrafficLight"
				c.Parent = furniture
			end
		end
		if not templates:FindFirstChild("Potholes") then
			local pf = Instance.new("Folder")
			pf.Name = "Potholes"
			local seen = {}
			for _, p in oldMap.Potholes:GetChildren() do
				if not seen[p.Name] then
					seen[p.Name] = true
					p:Clone().Parent = pf
				end
			end
			pf.Parent = templates
		end
	end
	ensureLampLight(furniture)
	return { Props = kit.Props, Templates = templates, Cars = kit.Cars, Furniture = furniture, Root = kit }
end

local function clearGenerated()
	local delivery = workspace:WaitForChild("Delivery")
	for _, inst in { workspace:FindFirstChild("Map"), workspace.Spawn:FindFirstChild("VehiclePlots"),
		delivery:FindFirstChild("Depot"), delivery:FindFirstChild("Destinations") } do
		if inst then
			inst:Destroy()
		end
	end
end

-- Transform a gate description built in a zone's local frame into a part.
local function gatePart(parent, frame, g)
	if g.rect then
		local r = g.rect
		local cf = frame * CFrame.new((r.x1 + r.x2) / 2, 8, (r.z1 + r.z2) / 2)
		local p = U.part(parent, g.name, Vector3.new(U.width(r), 16, U.depth(r)), cf, { Transparency = 1, CanCollide = false, CanQuery = false, CastShadow = false })
		if g.outward then
			p:SetAttribute("Outward", frame:VectorToWorldSpace(g.outward))
			p:SetAttribute("GateKind", g.kind)
		end
		return p
	end
	local cf = frame * CFrame.fromMatrix(g.pos, g.armDir, Vector3.yAxis)
	local p = U.part(parent, g.name, Vector3.new(0.5, 0.5, 0.5), cf, { Transparency = 1, CanCollide = false, CanQuery = false })
	p:SetAttribute("BoomLength", g.length)
	return p
end

-- Shopfront modules (see Zone.makeBuilding) are placed per facade before the
-- street furniture, landmarks and depots exist, so some land on a sign pole,
-- bus shelter, arch pillar, link column, marquee or the next building's
-- corner - two surfaces in one place, which flickers. Once the zone is in the
-- world, any module overlapping anything but the ground it stands on (or the
-- building it hangs on) is removed and that facade stays plain.
local SHOPFRONT_OK = { Building = true, Sidewalk = true, Ground = true, Promenade = true, Pavement = true, Line = true, AlleyPaving = true }
local function pruneShopfronts(zoneModel)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local removed = 0
	for _, m in zoneModel.Buildings:GetDescendants() do
		if m:IsA("Model") and m.Name:match("^Shopfront") and m.Parent then
			local cf, size = m:GetBoundingBox()
			params.FilterDescendantsInstances = { m }
			for _, p in workspace:GetPartBoundsInBox(cf, size - Vector3.new(0.3, 0.3, 0.3), params) do
				if not SHOPFRONT_OK[p.Name] and not p:IsDescendantOf(zoneModel.Ground) then
					m:Destroy()
					removed += 1
					break
				end
			end
		end
	end
	return removed
end

function Main.Run(seed)
	U.reseed(seed)
	local t0 = os.clock()
	local kit = ensureKit()
	clearGenerated()

	local map = Instance.new("Folder")
	map.Name = "Map"
	local delivery = workspace.Delivery
	local depot = Instance.new("Folder")
	depot.Name = "Depot"
	local destinations = Instance.new("Folder")
	destinations.Name = "Destinations"
	local plots = Instance.new("Folder")
	plots.Name = "VehiclePlots"

	-- sea
	local sea = U.folder(map, "Sea")
	local W = L.World
	U.box(sea, "Water", U.rect(W.x1, W.z1, W.x2, W.z2), L.SeaY - 8, L.SeaY, {
		Material = Enum.Material.Glass, Color = Style.Water, Transparency = 0.12, Reflectance = 0.12, CastShadow = false,
	})
	U.box(sea, "CatchFloor", U.rect(W.x1, W.z1, W.x2, W.z2), -60, -58, { Transparency = 1, CanQuery = false, CastShadow = false })
	for _, r in {
		U.rect(W.x1 - 2, W.z1, W.x1, W.z2), U.rect(W.x2, W.z1, W.x2 + 2, W.z2),
		U.rect(W.x1, W.z1 - 2, W.x2, W.z1), U.rect(W.x1, W.z2, W.x2, W.z2 + 2),
	} do
		U.box(sea, "Boundary", r, -60, 80, { Transparency = 1, CanQuery = false, CastShadow = false })
	end

	-- the permit and express gate descriptions (read by the clients)
	local permits = U.folder(map, "Permits")
	local permitGates = U.model(permits, "PermitGates")
	permitGates.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	local express = U.folder(map, "Express")
	local expressGates = U.model(express, "ExpressGates")
	expressGates.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

	-- zones
	local zones = {}
	for _, spec in L.Zones do
		table.insert(zones, { spec = spec })
	end
	for i, z in zones do
		local ctx = {}
		for _, c in L.Connectors do
			if c.From == i then
				ctx.linkNorth = true -- the express link leaves from this end
			end
			if c.To == i then
				ctx.linkSouth = true
			end
		end
		local res = Zone.Build(z.spec, kit, ctx)
		z.result = res
		local m = res.model
		m.WorldPivot = CFrame.new()
		m:PivotTo(z.spec.Frame)
		m.Parent = map
		Incidents.Build(z.spec, m, kit.Root)
		for _, g in res.gates do
			gatePart(expressGates, z.spec.Frame, g)
		end
		for _, d in m.Destinations:GetChildren() do
			d.Parent = destinations
		end
		m.Destinations:Destroy()
	end

	-- connectors
	for _, c in L.Connectors do
		Connector.Build(map, kit, c, zones[c.From], zones[c.To], { permitGates = permitGates })
	end

	-- terminal
	Terminal.Build(map, kit, depot, plots)

	map.Parent = workspace
	for _, z in zones do
		pruneShopfronts(z.result.model) -- needs the map in the world
	end
	depot.Parent = delivery
	destinations.Parent = delivery
	plots.Parent = workspace.Spawn

	local sp = workspace:FindFirstChild("SpawnLocation")
	if sp then
		sp.Position = Vector3.new(0, sp.Size.Y / 2, 290)
		sp.Orientation = Vector3.new(0, 180, 0)
	end

	-- layout summary + generated traffic
	local summary = { version = L.Version, zones = {}, destinations = {} }
	for _, z in zones do
		table.insert(summary.zones, { id = z.spec.Id, name = z.spec.Name, permit = z.spec.Permit })
		for _, d in z.spec.Destinations do
			table.insert(summary.destinations, { name = d.Name, zone = z.spec.Id, rig = d.rig == true })
		end
	end
	kit.Root:SetAttribute("LayoutJSON", HttpService:JSONEncode(summary))
	kit.Root:SetAttribute("TrafficRoutesSource", Traffic.Source(zones))

	local parts = 0
	for _, dd in map:GetDescendants() do
		if dd:IsA("BasePart") then
			parts += 1
		end
	end
	local boundsReport = Bounds.Build() .. " " .. Backdrop.Build() -- last: they wrap whatever the map turned out to be
	return string.format("City v%d built in %.1fs: %d map parts, %d destinations, %d plots. %s",
		L.Version, os.clock() - t0, parts, #destinations:GetChildren(), #plots:GetChildren(), boundsReport)
end

-- Rebuilds ONLY the three zones (and everything that comes from them: the
-- destinations, the express toll gates, the street incidents, the generated
-- traffic source), leaving the Terminal - hand-edited in Studio since
-- 2026-09-21 - and the connectors exactly as they are:
--
--   require(game.ServerStorage.MapGen.Main).RunZones()
--
-- What a zone contains comes from Layout, so a new junction treatment, pavement
-- or hand fix belongs THERE (Roundabouts, Style.sidewalk, Nudges) and then
-- survives every re-run. In particular the mini-roundabouts on Market
-- (Junctions.luau) and the NPC detours round them (Traffic.detour) are built
-- from the zone's `Roundabouts` list; after changing it, copy the regenerated
-- MapKit attribute TrafficRoutesSource into TrafficRoutes.luau.
--
-- It touches only workspace.Map's zone models, Delivery.Destinations, the
-- express gates, Bounds/Backdrop and two MapKit attributes. It never reads or
-- writes ReplicatedStorage (the wheel templates in ReplicatedStorage.Wheels
-- included) or any WeldConstraint outside the models it generates.
--
-- Safe as long as the zone ENDS the connectors join (Market's position and
-- width at the zone edge, and the zone frames) are unchanged.
-- Finishes by rebuilding the invisible walls round the playable area
-- (Bounds.Build), which fence off the sea so nobody can walk or jump out, and
-- the distant-city backdrop outside them (Backdrop.Build).
-- The zones are built first in Run too, so the same seed gives the same zones.
function Main.RunZones(seed)
	U.reseed(seed)
	local t0 = os.clock()
	local kit = ensureKit()
	local map = workspace:WaitForChild("Map")
	local delivery = workspace:WaitForChild("Delivery")
	local expressGates = map.Express.ExpressGates

	for _, spec in L.Zones do
		local old = map:FindFirstChild(spec.Key)
		if old then
			old:Destroy()
		end
	end
	expressGates:ClearAllChildren()
	local destinations = delivery:FindFirstChild("Destinations")
	if destinations then
		destinations:Destroy()
	end
	destinations = Instance.new("Folder")
	destinations.Name = "Destinations"

	local zones = {}
	for _, spec in L.Zones do
		table.insert(zones, { spec = spec })
	end
	for i, z in zones do
		local ctx = {}
		for _, c in L.Connectors do
			if c.From == i then
				ctx.linkNorth = true
			end
			if c.To == i then
				ctx.linkSouth = true
			end
		end
		local res = Zone.Build(z.spec, kit, ctx)
		z.result = res
		local m = res.model
		m.WorldPivot = CFrame.new()
		m:PivotTo(z.spec.Frame)
		m.Parent = map
		Incidents.Build(z.spec, m, kit.Root)
		pruneShopfronts(m)
		for _, g in res.gates do
			gatePart(expressGates, z.spec.Frame, g)
		end
		for _, d in m.Destinations:GetChildren() do
			d.Parent = destinations
		end
		m.Destinations:Destroy()
	end
	destinations.Parent = delivery

	local summary = { version = L.Version, zones = {}, destinations = {} }
	for _, z in zones do
		table.insert(summary.zones, { id = z.spec.Id, name = z.spec.Name, permit = z.spec.Permit })
		for _, d in z.spec.Destinations do
			table.insert(summary.destinations, { name = d.Name, zone = z.spec.Id, rig = d.rig == true })
		end
	end
	kit.Root:SetAttribute("LayoutJSON", HttpService:JSONEncode(summary))
	kit.Root:SetAttribute("TrafficRoutesSource", Traffic.Source(zones))

	local boundsReport = Bounds.Build() .. " " .. Backdrop.Build() -- the zone edges moved, so the walls and skyline do too
	return string.format("Zones rebuilt in %.1fs: %d destinations. %s", os.clock() - t0, #destinations:GetChildren(), boundsReport)
end

-- Rebuilds ONLY the connectors between the zones - the one local road each
-- carries, its pavements and buildings, the crossing, the express link over
-- it, the permit gates and the hazards parked on it:
--
--   require(game.ServerStorage.MapGen.Main).RunConnectors()
--
-- Leaves the zones, the Terminal (hand-edited in Studio since 2026-09-21) and
-- everything in Delivery alone, so it is the one to use while tuning
-- Layout's ConnectorSample or Hazards. It has to rebuild the zones in memory
-- first - a connector is drawn from the exact edge each zone ends at - but
-- those throwaway models never reach the world, and the same seed gives the
-- same zones, so the connectors land where the real ones do.
function Main.RunConnectors(seed)
	U.reseed(seed)
	local t0 = os.clock()
	local kit = ensureKit()
	local map = workspace:WaitForChild("Map")
	local permitGates = map.Permits.PermitGates

	local zones = {}
	for _, spec in L.Zones do
		table.insert(zones, { spec = spec })
	end
	for i, z in zones do
		local ctx = {}
		for _, c in L.Connectors do
			if c.From == i then
				ctx.linkNorth = true
			end
			if c.To == i then
				ctx.linkSouth = true
			end
		end
		z.result = Zone.Build(z.spec, kit, ctx)
		z.result.model:Destroy() -- only the edges it reports are wanted here
	end

	-- the gates belong to the connectors, so clear the ones they own first
	for _, g in permitGates:GetChildren() do
		g:Destroy()
	end
	local parts = 0
	for _, c in L.Connectors do
		local old = map:FindFirstChild("Connector_" .. c.Key)
		if old then
			old:Destroy()
		end
		local f = Connector.Build(map, kit, c, zones[c.From], zones[c.To], { permitGates = permitGates })
		for _, d in f:GetDescendants() do
			if d:IsA("BasePart") then
				parts += 1
			end
		end
	end
	local boundsReport = Bounds.Build() .. " " .. Backdrop.Build() -- the terraces moved, so the walls and skyline do too
	return string.format("%d connectors rebuilt in %.1fs: %d parts. %s", #L.Connectors, os.clock() - t0, parts, boundsReport)
end

return Main

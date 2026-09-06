-- Where deliveries can go, and how far away each one is. Scanned once out of
-- the hand-built workspace.Delivery geometry and handed to everything that
-- needs it.
--
-- This used to live inside DeliveryManager.server.luau, which was fine while
-- DeliveryManager was the only thing that generated contracts. It is not any
-- more: contracts are now a persisted, per-player pool built by ContractPool
-- (which PlotManager owns, because PlotManager owns the save), so two server
-- scripts need the same destination list and neither may be required by the
-- other. A module both can require is the only shape that works.
--
-- Everything here is optional at run time. A place file that has not had the
-- delivery geometry built yet should still boot, drive and let you test cargo
-- with the admin commands - it just cannot offer contracts. Failing loudly
-- once beats erroring on every heartbeat.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)

local Destinations = {}

local world = DeliveryConfig.World

-- [name] = { Name, Model, Spaces, Distance, DistanceBonus }
Destinations.ByName = {}
-- Sorted names. Sorted rather than left in GetChildren order because contract
-- generation indexes into it, and Lua does not promise a stable table order -
-- so without this two servers rolling the "same" contract could disagree about
-- which building it names.
Destinations.Order = {}

-- Every parking space inside a container, by DeliveryConfig's Space prefix.
-- Public because DeliveryManager needs the same answer for the loading bay,
-- which is not a destination.
function Destinations.SpacesIn(container)
	local spaces = {}
	if not container then
		return spaces
	end
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name:sub(1, #world.SpacePrefix) == world.SpacePrefix then
			table.insert(spaces, descendant)
		end
	end
	return spaces
end

function Destinations.LoadingBay()
	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	local depotFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DepotFolderName)
	return depotFolder and depotFolder:FindFirstChild(world.LoadingBayName)
end

local built = false

-- Built lazily and exactly once, on whichever of the two server scripts asks
-- first. Lazy rather than at require time because this touches Workspace, and
-- a module that scans the world the moment it is required makes the order the
-- two scripts happen to require it in matter.
function Destinations.Build()
	if built then
		return
	end
	built = true

	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	local destinationsFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DestinationsFolderName)
	if not destinationsFolder then
		warn(
			string.format(
				"Destinations: no workspace.%s.%s folder - contracts are disabled. See docs/CargoDesign.md "
					.. "section 4.2 for the folder structure to build.",
				world.RootFolderName,
				world.DestinationsFolderName
			)
		)
		return
	end

	local loadingBay = Destinations.LoadingBay()
	local depotSpaces = Destinations.SpacesIn(loadingBay)
	local depotPosition = depotSpaces[1] and depotSpaces[1].Position or Vector3.zero
	if #depotSpaces == 0 then
		warn(
			string.format(
				"Destinations: no '%s*' Part inside workspace.%s.%s.%s - distance bonuses will all be zero and "
					.. "there is nowhere to load. See docs/CargoDesign.md section 4.3.",
				world.SpacePrefix,
				world.RootFolderName,
				world.DepotFolderName,
				world.LoadingBayName
			)
		)
	end

	for _, model in destinationsFolder:GetChildren() do
		local spaces = Destinations.SpacesIn(model)
		if #spaces == 0 then
			warn(
				string.format(
					"Destinations: %s has no '%s*' Part in it, so nothing can be delivered there - skipping it.",
					model:GetFullName(),
					world.SpacePrefix
				)
			)
			continue
		end

		-- Straight-line depot-to-destination, NOT along any route. It is a
		-- difficulty proxy for pricing, not a measurement of what the player
		-- drove - see DeliveryManager's header for why the route is
		-- deliberately never measured.
		local distance = (spaces[1].Position - depotPosition).Magnitude
		Destinations.ByName[model.Name] = {
			Name = model.Name,
			Model = model,
			Spaces = spaces,
			Distance = distance,
			DistanceBonus = DeliveryConfig.Payout.DistanceBonusAtMax
				* math.clamp(distance / DeliveryConfig.Payout.DistanceForMaxBonus, 0, 1),
		}
		table.insert(Destinations.Order, model.Name)
	end

	table.sort(Destinations.Order)
end

function Destinations.Get(name)
	Destinations.Build()
	return Destinations.ByName[name]
end

function Destinations.Count()
	Destinations.Build()
	return #Destinations.Order
end

-- A random destination NAME, or nil if the map has none built. Name rather
-- than the entry itself because that is what a persisted contract stores: a
-- saved contract has to survive the destination being renamed or removed
-- between sessions, and a dangling name is something ContractPool can detect
-- and drop, where a dangling Instance reference could not even be saved.
function Destinations.RandomName()
	Destinations.Build()
	if #Destinations.Order == 0 then
		return nil
	end
	return Destinations.Order[math.random(#Destinations.Order)]
end

return Destinations

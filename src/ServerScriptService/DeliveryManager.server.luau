-- Contracts, arrival detection and payout. The authority on every one of
-- those, in the same way PlotManager is the authority on plots and money -
-- the client's job here is to display a board and press a button, and
-- everything it sends is re-checked below.
--
-- The loop this implements: take a contract at the depot (which names the
-- destination, the goods and the crate count), drive there, park, get paid on
-- arrival. Money lands the moment the truck stops in the bay, so quitting
-- after a delivery never costs the player the run they just did.
--
-- WHAT IS DELIBERATELY NOT MEASURED: the route. Payout depends on where the
-- truck ended up, never on the path it took, which is what lets the map have
-- as many alleys, shortcuts and dead ends as you like without any of them
-- needing to be scored. See docs/CargoDesign.md section 1.
--
-- A contract carries a LIST of stops even though every contract generated
-- today has exactly one. That is not speculative generality: multi-stop routes
-- are the intended replacement for a fuel system (upgrade the truck, carry
-- more, do three drops in one trip), and a single-element list now means that
-- arrives as a generation change rather than a rewrite of arrival handling.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
local CargoTypes = require(ReplicatedStorage.Modules.Delivery.CargoTypes)
local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local CargoManager = require(script.Parent.Modules.CargoManager)

local VehicleFolder = workspace:WaitForChild("Vehicles")

-- PlotManager owns every player's money and this is the only door into it.
-- WaitForChild rather than direct indexing because script execution order
-- between two ServerScriptService scripts is not defined, so this one can
-- easily run first.
local awardMoneyFunction = script.Parent:WaitForChild("AwardMoney")

--=============================================================================
-- World lookup
--=============================================================================

local world = DeliveryConfig.World

-- Everything here is optional at run time. A place file that has not had the
-- delivery geometry built yet should still boot, drive and let you test cargo
-- with the admin commands - it just cannot offer contracts. Failing loudly
-- once beats erroring on every heartbeat.
local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
local destinationsFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DestinationsFolderName)
local depotFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DepotFolderName)
local loadingBay = depotFolder and depotFolder:FindFirstChild(world.LoadingBayName)

local function spacesIn(container)
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

-- Built once at startup: every destination, its spaces, and how far it is from
-- the depot. Distance is measured depot-to-destination in a straight line, NOT
-- along any route - see the header. It is a difficulty proxy for pricing, not
-- a measurement of what the player drove.
local destinations = {}
local destinationOrder = {}

local function buildDestinations()
	if not destinationsFolder then
		warn(
			string.format(
				"DeliveryManager: no workspace.%s.%s folder - contracts are disabled. See docs/CargoDesign.md "
					.. "section 4.2 for the folder structure to build.",
				world.RootFolderName,
				world.DestinationsFolderName
			)
		)
		return
	end

	local depotSpaces = spacesIn(loadingBay)
	local depotPosition = depotSpaces[1] and depotSpaces[1].Position or Vector3.zero
	if #depotSpaces == 0 then
		warn(
			string.format(
				"DeliveryManager: no '%s*' Part inside workspace.%s.%s.%s - distance bonuses will all be zero and "
					.. "there is nowhere to load. See docs/CargoDesign.md section 4.3.",
				world.SpacePrefix,
				world.RootFolderName,
				world.DepotFolderName,
				world.LoadingBayName
			)
		)
	end

	for _, model in destinationsFolder:GetChildren() do
		local spaces = spacesIn(model)
		if #spaces == 0 then
			warn(
				string.format(
					"DeliveryManager: destination %s has no '%s*' Part in it, so nothing can be delivered there - "
						.. "skipping it.",
					model:GetFullName(),
					world.SpacePrefix
				)
			)
			continue
		end

		local distance = (spaces[1].Position - depotPosition).Magnitude
		destinations[model.Name] = {
			Name = model.Name,
			Model = model,
			Spaces = spaces,
			Distance = distance,
			DistanceBonus = DeliveryConfig.Payout.DistanceBonusAtMax
				* math.clamp(distance / DeliveryConfig.Payout.DistanceForMaxBonus, 0, 1),
		}
		table.insert(destinationOrder, model.Name)
	end

	table.sort(destinationOrder) -- stable offers between servers; table order is unspecified in Lua
end

buildDestinations()

--=============================================================================
-- Remotes
--=============================================================================

-- Client asks for the board when it decides the player is at the dock. The
-- server does not trust that judgement - AcceptContract re-checks the truck is
-- actually in the bay - so this can be answered freely.
local getContractsFunction = Instance.new("RemoteFunction")
getContractsFunction.Name = "GetDeliveryContracts"
getContractsFunction.Parent = ReplicatedStorage

local acceptContractEvent = Instance.new("RemoteEvent")
acceptContractEvent.Name = "AcceptDeliveryContract"
acceptContractEvent.Parent = ReplicatedStorage

-- Server -> one client. Everything the HUD needs to draw itself: the active
-- contract (or nil), and the result of the delivery that just completed.
local deliveryUpdateEvent = Instance.new("RemoteEvent")
deliveryUpdateEvent.Name = "DeliveryUpdate"
deliveryUpdateEvent.Parent = ReplicatedStorage

--=============================================================================
-- State
--=============================================================================

-- [Player] = contract table. Keyed by Player instance and cleared in
-- PlayerRemoving, so a leaver takes their contract with them.
local activeContracts = {}
-- [Player] = { contract, ... }, the board as last generated for them. Held so
-- accepting quotes the SAME numbers that were displayed, rather than
-- re-rolling and paying out something the player never agreed to.
local offeredContracts = {}
-- [Player] = seconds the truck has been continuously stopped in a bay.
local stoppedFor = {}

Players.PlayerRemoving:Connect(function(player)
	activeContracts[player] = nil
	offeredContracts[player] = nil
	stoppedFor[player] = nil
end)

--=============================================================================
-- Contract generation
--=============================================================================

local nextContractId = 0

-- Offers are sized to the truck the player is actually sitting in, which is
-- what makes CargoCapacity worth buying: a bigger bed does not merely let you
-- carry more of the same job, it changes what the board is willing to offer.
local function capacityOf(carModel)
	local chassis = carModel and carModel.PrimaryPart
	if not chassis then
		return 0
	end
	return CargoLoad.Capacity(VehiclePhysics.GetConfig(chassis))
end

local function makeContract(capacity)
	local destinationName = destinationOrder[math.random(#destinationOrder)]
	local destination = destinations[destinationName]
	local typeId = CargoTypes.Order[math.random(#CargoTypes.Order)]

	local contracts = DeliveryConfig.Contracts
	local minUnits = math.max(1, math.floor(capacity * contracts.MinUnitsFraction))
	local units = if capacity > 0 then math.random(minUnits, capacity) else contracts.FallbackUnits

	nextContractId += 1

	-- The quoted figure assumes a pristine arrival and a plain nose-in park.
	-- Deliberately the FLOOR of what the job can pay rather than its ceiling:
	-- a player who drives well is rewarded with more than the board promised,
	-- which reads far better than being told a number and then docked for
	-- every scratch.
	local baseValue = CargoLoad.Value(units, typeId, 1)

	return {
		Id = nextContractId,
		-- One stop today; see the header for why it is a list.
		Stops = { destinationName },
		TypeId = typeId,
		Units = units,
		QuotedValue = math.floor(baseValue * (1 + destination.DistanceBonus)),
		Distance = destination.Distance,
	}
end

getContractsFunction.OnServerInvoke = function(player)
	if #destinationOrder == 0 then
		return { Offers = {}, Active = activeContracts[player] }
	end

	-- An active contract replaces the board entirely: there is no queue, and
	-- being able to take a second job while carrying the first would mean
	-- cargo from two contracts in one bed with no way to tell them apart at a
	-- drop-off.
	if activeContracts[player] then
		return { Offers = {}, Active = activeContracts[player] }
	end

	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	local capacity = capacityOf(carModel)

	local offers = {}
	for _ = 1, DeliveryConfig.Contracts.OfferCount do
		table.insert(offers, makeContract(capacity))
	end
	offeredContracts[player] = offers

	return { Offers = offers, Active = nil }
end

--=============================================================================
-- Accepting
--=============================================================================

local function isStopped(chassis)
	return chassis.AssemblyLinearVelocity.Magnitude <= DeliveryConfig.Parking.StoppedSpeed
end

-- Which of a container's spaces the truck is parked in, plus its grade.
local function findParkedSpace(carModel, spaces)
	for _, space in spaces do
		local grade = ParkGrade.Evaluate(carModel, space)
		if grade.Inside then
			return space, grade
		end
	end
	return nil, nil
end

acceptContractEvent.OnServerEvent:Connect(function(player, contractId)
	if type(contractId) ~= "number" then
		return
	end
	if activeContracts[player] then
		return -- already carrying one; the board should not have offered anything
	end

	-- Only from the board we actually handed this player, so a crafted id
	-- cannot invent a contract with whatever payout it likes.
	local offers = offeredContracts[player]
	local contract = nil
	for _, offer in offers or {} do
		if offer.Id == contractId then
			contract = offer
			break
		end
	end
	if not contract then
		warn("DeliveryManager: " .. player.Name .. " tried to accept a contract that was never offered to them")
		return
	end

	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	if not carModel or not carModel.PrimaryPart then
		return
	end
	-- Their own truck. Loading someone else's would change how it drives for
	-- whoever owns it.
	if not VehicleOwnership.CanEnter(player, carModel) then
		return
	end

	-- The geometric check the client's "you are at the dock" guess is only a
	-- hint about. Being at rest is required for the same reason it is at a
	-- destination: a moving, client-owned chassis is a lagging echo on the
	-- server, and a stationary one is not.
	local space = findParkedSpace(carModel, spacesIn(loadingBay))
	if not space or not isStopped(carModel.PrimaryPart) then
		return
	end

	local loaded = CargoManager.Load(carModel, contract.TypeId, contract.Units)
	if loaded <= 0 then
		return
	end

	-- Record what was ACTUALLY loaded, not what was offered. If the truck
	-- could only take four of a six-crate job, the contract is now a four
	-- crate job and pays like one - rather than promising a figure the bed was
	-- never going to earn.
	contract.Units = loaded
	contract.Vehicle = carModel
	activeContracts[player] = contract
	offeredContracts[player] = nil

	deliveryUpdateEvent:FireClient(player, { Active = contract })
end)

--=============================================================================
-- Arrival
--=============================================================================

local function completeDelivery(player, carModel, contract, space, grade)
	local load = CargoManager.GetLoad(carModel)
	local destination = destinations[contract.Stops[1]]

	local value = CargoLoad.Value(load.Units, load.TypeId, load.Condition)

	local spaceMultiplier = space:GetAttribute(world.SpacePayoutAttribute)
	if type(spaceMultiplier) ~= "number" or spaceMultiplier <= 0 then
		spaceMultiplier = 1
	end

	local multiplier = ParkGrade.Multiplier(grade)
		* spaceMultiplier
		* (1 + (destination and destination.DistanceBonus or 0))
	-- The ceiling from DeliveryConfig. Cargo condition is derived from
	-- client-reported impacts, so this is the backstop on how much a client
	-- that simply never reports a crash can be worth.
	multiplier = math.min(multiplier, DeliveryConfig.Payout.MaxMultiplier)

	local payout = math.floor(value * multiplier)

	activeContracts[player] = nil
	stoppedFor[player] = nil
	CargoManager.Unload(carModel)

	local newBalance = awardMoneyFunction:Invoke(player, payout)

	deliveryUpdateEvent:FireClient(player, {
		Active = nil,
		Completed = {
			Destination = contract.Stops[1],
			TypeId = load.TypeId,
			Units = load.Units,
			Condition = load.Condition,
			ParkLabel = grade.Label,
			Multiplier = multiplier,
			Payout = payout,
			-- nil if the player left between parking and being paid; the HUD
			-- shows the payout either way, and the money simply did not land.
			Balance = newBalance,
		},
	})
end

-- Polled rather than event-driven. A Touched event on the space would fire
-- constantly while a truck crosses it and tell us nothing about whether it has
-- STOPPED, which is the actual condition - so the check would end up polling
-- anyway, just with more moving parts.
--
-- The loop only ever walks players who are carrying a contract, so an idle
-- server does no work here at all.
local accumulator = 0
local POLL_INTERVAL = 0.25

RunService.Heartbeat:Connect(function(delta)
	accumulator += delta
	if accumulator < POLL_INTERVAL then
		return
	end
	local elapsed = accumulator
	accumulator = 0

	for player, contract in activeContracts do
		local carModel = contract.Vehicle
		-- Their truck was destroyed or despawned mid-run (they went back to
		-- their plot and swapped vehicles, say). The contract goes with it -
		-- the cargo no longer exists to deliver.
		if not carModel or not carModel.Parent or not carModel.PrimaryPart then
			activeContracts[player] = nil
			stoppedFor[player] = nil
			deliveryUpdateEvent:FireClient(player, { Active = nil })
			continue
		end

		-- Must be the one driving it on arrival. Otherwise a player could load
		-- up, get out, and have a friend deliver it for them while they are
		-- somewhere else entirely.
		if VehicleSeats.GetDriverPlayer(carModel) ~= player then
			stoppedFor[player] = 0
			continue
		end

		local destination = destinations[contract.Stops[1]]
		if not destination then
			continue
		end

		local space, grade = findParkedSpace(carModel, destination.Spaces)
		if not space or not isStopped(carModel.PrimaryPart) then
			stoppedFor[player] = 0
			continue
		end

		-- Held for a moment before it counts. This is what makes the park a
		-- deliberate act rather than something you can score by rolling
		-- through the bay, and it is also the window in which the server's
		-- copy of a client-owned chassis settles onto the truth.
		local held = (stoppedFor[player] or 0) + elapsed
		stoppedFor[player] = held
		if held >= DeliveryConfig.Parking.StoppedHoldSeconds then
			completeDelivery(player, carModel, contract, space, grade)
		end
	end
end)

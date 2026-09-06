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
-- WHERE CONTRACTS COME FROM: not from here. A player's board is a persisted
-- pool that refills on a real-time clock and can be refreshed for Robux (see
-- ContractPool.luau for why it works that way and PlotManager for who owns it).
-- This script asks for that board, takes jobs out of it, and reports completed
-- deliveries back - it does not generate, re-roll or store a single contract,
-- which is what makes "drive out of the bay and back in" no longer a free
-- re-roll of the offers.
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
local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local CargoManager = require(script.Parent.Modules.CargoManager)
local Destinations = require(script.Parent.Modules.Destinations)

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

-- The destination list, its parking spaces and its distance-from-depot pricing
-- all live in Destinations.luau now, because contract GENERATION moved out of
-- this script and into ContractPool - and both need the same answers without
-- either requiring the other. See that module's header.
--
-- The loading bay is still looked up here: it is not a destination, and this
-- is the only script that cares where it is.
Destinations.Build()

local loadingBay = Destinations.LoadingBay()

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
--
-- Note what is NOT here any more: the board. Offers used to be cached per
-- player in this script so that accepting quoted the same numbers that were
-- displayed. They are persisted per player now, which gives that property for
-- free and gives it across servers as well.
local activeContracts = {}
-- [Player] = seconds the truck has been continuously stopped in a bay.
local stoppedFor = {}

Players.PlayerRemoving:Connect(function(player)
	activeContracts[player] = nil
	stoppedFor[player] = nil
end)

-- PlotManager owns the contract pool, because the pool is part of the save and
-- PlotManager owns saves. Same WaitForChild-on-a-BindableFunction arrangement
-- as AwardMoney above, and for the same two reasons: execution order between
-- two ServerScriptService scripts is undefined, and a Bindable is invisible to
-- clients so there is no hostile caller to guard against.
local getContractBoardFunction = script.Parent:WaitForChild("GetContractBoard")
local takeContractFunction = script.Parent:WaitForChild("TakeContract")
local recordDeliveryFunction = script.Parent:WaitForChild("RecordDelivery")

--=============================================================================
-- The board
--=============================================================================

-- Offers are sized to the truck the player is actually sitting in, which is
-- what makes CargoCapacity worth buying: a bigger bed does not merely let you
-- carry more of the same job, it changes what the board is willing to offer.
-- The truck's config, or an empty table if the player is not in one. Returned
-- rather than just the capacity because the board also quotes each offer's
-- weight, and weight is CargoMassFractionPerUnit - another config key. One
-- lookup, two answers, and no chance of the two being read off different
-- vehicles if the player swaps trucks mid-call.
local function configOf(carModel)
	local chassis = carModel and carModel.PrimaryPart
	if not chassis then
		return {}
	end
	return VehiclePhysics.GetConfig(chassis)
end

-- The board for whatever truck this player is in right now. One place, because
-- both the "show me the board" remote and the accept handler need the same
-- answer built against the same vehicle snapshot.
local function boardFor(player)
	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	local config = configOf(carModel)
	return getContractBoardFunction:Invoke(player, config, CargoLoad.Capacity(config)), carModel
end

-- Client asks for the board when it decides the player is at the dock. The
-- server does not trust that judgement - AcceptContract re-checks the truck is
-- actually in the bay - so this can be answered freely.
--
-- Answering it has NO side effect on what is offered. That is the whole point
-- of the persisted pool: calling this twenty times in a row returns the same
-- twenty boards, so reversing out of the bay and driving back in is no longer
-- a way to re-roll jobs the player did not like.
getContractsFunction.OnServerInvoke = function(player)
	-- An active contract replaces the board entirely: there is no queue, and
	-- being able to take a second job while carrying the first would mean cargo
	-- from two contracts in one bed with no way to tell them apart at a
	-- drop-off. The pool is still reported, so the HUD can show what is waiting.
	local board = boardFor(player)
	if type(board) ~= "table" then
		return { Offers = {}, Active = activeContracts[player] }
	end

	board.Active = activeContracts[player]
	if board.Active then
		board.Offers = {}
	end
	return board
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

	-- Drawn against the truck the player is in RIGHT NOW rather than against
	-- whatever they were in when the board was last displayed. A saved contract
	-- is a capacity fraction, not a crate count (see ContractPool's header), so
	-- this is the only quote that can honestly be loaded onto this bed.
	local board, carModel = boardFor(player)
	if type(board) ~= "table" then
		return -- their data has not finished loading; nothing to take from
	end

	local contract = nil
	for _, offer in board.Offers do
		if offer.Id == contractId then
			contract = offer
			break
		end
	end
	if not contract then
		warn("DeliveryManager: " .. player.Name .. " tried to accept a contract that is not on their board")
		return
	end

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
	local space = findParkedSpace(carModel, Destinations.SpacesIn(loadingBay))
	if not space or not isStopped(carModel.PrimaryPart) then
		return
	end

	local loaded = CargoManager.Load(carModel, contract.TypeId, contract.Units)
	if loaded <= 0 then
		return
	end

	-- Loaded first, THEN taken off the board. The other order would consume a
	-- job the truck turned out to have no room for, and there is no way to put
	-- one back - a slot is real time (or Robux) and must never be spent on a
	-- load that did not happen. Neither call yields, so nothing can slip in
	-- between them; the unload below is for the case where the pool disagreed
	-- with the board this handler was reading, which should be impossible and
	-- is cheap to be certain about.
	if not takeContractFunction:Invoke(player, contractId) then
		CargoManager.Unload(carModel)
		return
	end

	-- Record what was ACTUALLY loaded, not what was offered. If the truck
	-- could only take four of a six-crate job, the contract is now a four
	-- crate job and pays like one - rather than promising a figure the bed was
	-- never going to earn.
	contract.Units = loaded
	contract.Vehicle = carModel
	activeContracts[player] = contract

	deliveryUpdateEvent:FireClient(player, { Active = contract })
end)

--=============================================================================
-- Arrival
--=============================================================================

local function completeDelivery(player, carModel, contract, space, grade)
	local load = CargoManager.GetLoad(carModel)
	local destination = Destinations.Get(contract.Stops[1])

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
	-- The lifetime counter every level in the game is derived from. Bumped
	-- here, at the same moment the money lands, so the two can never disagree
	-- about whether a delivery happened - and nil for a player who left between
	-- parking and being paid, exactly like the balance above.
	local progress = recordDeliveryFunction:Invoke(player)

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
			-- Lifetime deliveries, the level that follows from it, and whether
			-- this delivery was the one that moved it. The HUD turns the last
			-- into the level-up banner on the payout card.
			Progress = progress,
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

		local destination = Destinations.Get(contract.Stops[1])
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

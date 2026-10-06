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
local Haulage = require(ReplicatedStorage.Modules.Delivery.Haulage)
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
-- Where a job is TAKEN is not a destination and is not looked up here either:
-- it is the loading bay for a truck and the freight building for a rig, and
-- Haulage.DepotSpaces answers for both at the moment a job is accepted.
Destinations.Build()

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

-- Server -> one PASSENGER. The same shape as DeliveryUpdate, describing the job
-- of the truck they are riding in rather than a job of their own.
--
-- A second remote rather than a flag on the first, because DeliveryUpdate has
-- listeners that must never mistake a friend's job for the player's own: the
-- tutorial advances its steps on it, and the contract board closes on it.
-- Anything that wants to mirror the driver's HUD opts in by listening here.
local rideAlongUpdateEvent = Instance.new("RemoteEvent")
rideAlongUpdateEvent.Name = "RideAlongUpdate"
rideAlongUpdateEvent.Parent = ReplicatedStorage

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
-- [Player] = { Contract, Owner, WholeTrip } for a PASSENGER riding in a truck
-- that is carrying somebody else's job. See the ride-along section below.
local rideAlongs = {}

-- The destination of the job this player is carrying, mirrored onto the Player
-- as an Attribute so OTHER scripts can see it without this one having to know
-- they exist. PlotTerminal.client.luau reads it to warn that respawning a truck
-- bins the contract in its bed.
--
-- An Attribute rather than a remote: the terminal is a different script from
-- the HUD, all it needs is whether a job exists, and an attribute is simply
-- already there when the terminal opens instead of needing a round trip that
-- would land after the panel had drawn. It replicates to every client, which is
-- fine - a job's destination is not a secret, and the HUD already shows it.
local ACTIVE_CONTRACT_ATTRIBUTE = "ActiveContractStop"

-- The ONE writer of activeContracts, so the attribute can never be left saying
-- a player is carrying something they are not. Every path that starts, finishes
-- or cancels a job goes through here.
local function setActiveContract(player, contract)
	activeContracts[player] = contract
	player:SetAttribute(ACTIVE_CONTRACT_ATTRIBUTE, contract and contract.Stops[1] or nil)
end

Players.PlayerRemoving:Connect(function(player)
	-- Straight to the tables rather than through setActiveContract: the Player
	-- is on its way out, so there is nothing left to mirror the attribute to,
	-- and what matters here is that this script stops holding a reference to
	-- them and to their truck.
	activeContracts[player] = nil
	stoppedFor[player] = nil
	rideAlongs[player] = nil
end)

--=============================================================================
-- Ride-alongs
--=============================================================================

-- A passenger in a truck that is carrying a job sees that job - destination,
-- cargo, waypoint - so they can navigate for the driver, and earns a small cut
-- of the payout if they were aboard for the whole run.
--
-- "The whole run" is tracked by WholeTrip, and it can only ever be set at the
-- moment the contract is accepted: a passenger seated in the bay when the
-- crates go on starts with it true, and the record is dropped the first poll
-- they are found out of their seat. Getting back in makes a fresh record with
-- it false. So hopping in for the last corner pays nothing, and so does
-- hopping between trucks to collect from each.

local function startRideAlong(passenger, owner, contract, wholeTrip)
	rideAlongs[passenger] = { Contract = contract, Owner = owner, WholeTrip = wholeTrip }
	rideAlongUpdateEvent:FireClient(passenger, {
		Active = contract,
		Driver = owner.DisplayName,
		EarnsCut = wholeTrip,
	})
end

-- Ends every ride-along on `contract`, sending each passenger whatever
-- `describe(passenger, ride)` returns (or a bare "no job" if it is omitted).
-- The passengers are collected first so `describe` is free to do anything it
-- likes without the table changing under the loop.
local function endRideAlongs(contract, describe)
	local ending = {}
	for passenger, ride in rideAlongs do
		if ride.Contract == contract then
			table.insert(ending, passenger)
		end
	end
	for _, passenger in ending do
		local ride = rideAlongs[passenger]
		rideAlongs[passenger] = nil
		rideAlongUpdateEvent:FireClient(passenger, describe and describe(passenger, ride) or { Active = nil })
	end
end

-- Brings rideAlongs back in line with who is actually sitting where. Run on
-- the arrival poll rather than off seat events: it has to notice a truck being
-- destroyed and a driver leaving the game as well as a passenger standing up,
-- and "who is seated in a truck with a job, right now" answers all of them.
local function syncRideAlongs()
	local seated = {}
	for owner, contract in activeContracts do
		local carModel = contract.Vehicle
		if carModel and carModel.Parent then
			for _, passenger in VehicleSeats.GetPassengerPlayers(carModel) do
				-- The owner riding shotgun in their own truck is not their own
				-- co-driver.
				if passenger ~= owner then
					seated[passenger] = owner
				end
			end
		end
	end

	for passenger, ride in rideAlongs do
		local owner = seated[passenger]
		if not owner or activeContracts[owner] ~= ride.Contract then
			rideAlongs[passenger] = nil
			rideAlongUpdateEvent:FireClient(passenger, { Active = nil })
		end
	end

	for passenger, owner in seated do
		if not rideAlongs[passenger] then
			-- Joined a job already under way: they see it, but earn nothing.
			startRideAlong(passenger, owner, activeContracts[owner], false)
		end
	end
end

-- PlotManager owns the contract pool, because the pool is part of the save and
-- PlotManager owns saves. Same WaitForChild-on-a-BindableFunction arrangement
-- as AwardMoney above, and for the same two reasons: execution order between
-- two ServerScriptService scripts is undefined, and a Bindable is invisible to
-- clients so there is no hostile caller to guard against.
local getContractBoardFunction = script.Parent:WaitForChild("GetContractBoard")
local takeContractFunction = script.Parent:WaitForChild("TakeContract")
local recordDeliveryFunction = script.Parent:WaitForChild("RecordDelivery")
local freeRefreshContractsFunction = script.Parent:WaitForChild("FreeRefreshContracts")

-- The client's free-refresh button. A straight passthrough to PlotManager's
-- bindable rather than another AcceptContract-style handler: the cooldown
-- itself IS the security here (see ContractPool.FreeRefresh), so there is
-- nothing else for this handler to check before asking it.
local freeRefreshFunction = Instance.new("RemoteFunction")
freeRefreshFunction.Name = "FreeRefreshContracts"
freeRefreshFunction.Parent = ReplicatedStorage

freeRefreshFunction.OnServerInvoke = function(player)
	return freeRefreshContractsFunction:Invoke(player)
end

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
--
-- A TRACTOR IS QUOTED AGAINST ITS TRAILER. The load goes on the trailer (see
-- Haulage.luau), so it is the trailer's capacity that sizes the jobs, and the
-- board is drawn for a rig - every job pointed at a destination with a bay
-- long enough to take one. A tractor with nothing hitched has no carrier at
-- all and is offered nothing: there is nowhere to put a crate.
--
-- Returns the board, the driven vehicle, and the model the load goes on.
local function boardFor(player)
	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	local rig = Haulage.IsTractor(carModel)
	local carrier = Haulage.Carrier(carModel)
	local config = configOf(carrier)
	local board = getContractBoardFunction:Invoke(player, config, CargoLoad.Capacity(config), rig)
	if type(board) == "table" then
		board.Rig = rig
		if rig and not carrier then
			board.Offers = {}
		end
	end
	return board, carModel, carrier
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

-- "Which of these spaces is it parked in" is Haulage.FindParkedSpace: for a
-- rig the thing that has to be in the bay is the trailer, not the tractor.

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
	local board, carModel, carrier = boardFor(player)
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
	--
	-- A rig loads at the freight building, with its TRAILER in a rig bay; every
	-- other vehicle at the loading bay, as it always has.
	local rig = Haulage.IsTractor(carModel)
	if not carrier then
		return -- a tractor with nothing hitched: the board offered it nothing
	end
	local space = Haulage.FindParkedSpace(carModel, Haulage.DepotSpaces(rig))
	if not space or not ParkGrade.IsStopped(carModel.PrimaryPart) then
		return
	end

	local loaded = CargoManager.Load(carrier, contract.TypeId, contract.Units)
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
		CargoManager.Unload(carrier)
		return
	end

	-- Record what was ACTUALLY loaded, not what was offered. If the truck
	-- could only take four of a six-crate job, the contract is now a four
	-- crate job and pays like one - rather than promising a figure the bed was
	-- never going to earn.
	contract.Units = loaded
	contract.Vehicle = carModel
	-- The model the goods are on - the trailer for a rig, and the vehicle
	-- itself otherwise. Everything from here on that asks about the LOAD
	-- (its condition, whether it is in the bay, emptying it) asks this model;
	-- everything about the DRIVER still asks Vehicle.
	contract.Carrier = carrier
	contract.Rig = rig
	setActiveContract(player, contract)

	deliveryUpdateEvent:FireClient(player, { Active = contract })

	-- Whoever is already in a passenger seat was here for the loading, which is
	-- the only way to be in line for the co-driver cut.
	for _, passenger in VehicleSeats.GetPassengerPlayers(carModel) do
		if passenger ~= player then
			startRideAlong(passenger, player, contract, true)
		end
	end
end)

--=============================================================================
-- Arrival
--=============================================================================

local function completeDelivery(player, carrier, contract, space, grade)
	local load = CargoManager.GetLoad(carrier)
	local destination = Destinations.Get(contract.Stops[1])

	local value = CargoLoad.Value(load.Units, load.TypeId, load.Condition)

	local spaceMultiplier = space:GetAttribute(world.SpacePayoutAttribute)
	if type(spaceMultiplier) ~= "number" or spaceMultiplier <= 0 then
		spaceMultiplier = 1
	end

	local multiplier = ParkGrade.Multiplier(grade)
		* spaceMultiplier
		* (1 + (destination and destination.DistanceBonus or 0))
		* (destination and destination.ZoneMultiplier or 1)
	-- The ceiling from DeliveryConfig. Cargo condition is derived from
	-- client-reported impacts, so this is the backstop on how much a client
	-- that simply never reports a crash can be worth.
	multiplier = math.min(multiplier, DeliveryConfig.Payout.MaxMultiplier)

	local payout = math.floor(value * multiplier)

	setActiveContract(player, nil)
	stoppedFor[player] = nil
	CargoManager.Unload(carrier)

	local newBalance = awardMoneyFunction:Invoke(player, payout)
	-- The lifetime counter every level in the game is derived from. Bumped
	-- here, at the same moment the money lands, so the two can never disagree
	-- about whether a delivery happened - and nil for a player who left between
	-- parking and being paid, exactly like the balance above.
	local progress = recordDeliveryFunction:Invoke(player)

	local completed = {
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
	}
	deliveryUpdateEvent:FireClient(player, { Active = nil, Completed = completed })

	-- The co-driver cut: a share of the payout, on top of it, for a passenger
	-- who rode the whole trip. Money only - RecordDelivery is deliberately not
	-- called for them, so a ride-along never counts towards a passenger's own
	-- job slots or cargo unlocks. See DeliveryConfig.CoDriver.
	endRideAlongs(contract, function(passenger, ride)
		local receipt = table.clone(completed)
		receipt.CoDriver = true
		receipt.Progress = nil
		receipt.Payout = if ride.WholeTrip then math.floor(payout * DeliveryConfig.CoDriver.PayoutShare) else 0
		receipt.Balance = if receipt.Payout > 0 then awardMoneyFunction:Invoke(passenger, receipt.Payout) else nil
		return { Active = nil, Completed = receipt }
	end)
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

	-- Before the arrival checks, so a passenger who stood up this tick is
	-- already out of the running by the time anything is paid.
	syncRideAlongs()

	for player, contract in activeContracts do
		local carModel = contract.Vehicle
		-- Their truck was destroyed or despawned mid-run - almost always because
		-- they went back to their plot and pressed Spawn, which replaces
		-- whatever was parked there (see PlotManager's despawnVehicle).
		--
		-- The contract goes with it, and that is the intended rule, not an
		-- accident of cleanup: the crates were welded into THAT bed, the load's
		-- condition is an attribute on THAT model, and there is no honest way to
		-- pay out for goods that no longer exist. It costs the player a real
		-- contract slot, which is why the terminal warns them before they press
		-- the button rather than after.
		--
		-- Everything the job owned dies with the model: CargoManager keeps its
		-- entire state (type, units, condition, ballast, crates) as Attributes
		-- and children ON the car, so there is no table anywhere holding a
		-- reference to a destroyed vehicle. The two lines below are the whole
		-- cleanup.
		--
		-- A rig's job dies the same way with its TRAILER, which is where its
		-- goods are: recalling the trailer to the yard replaces it with a new,
		-- empty one. If only the tractor went, the trailer is still standing
		-- somewhere with the load's attributes on it, so those are cleared -
		-- otherwise it would be hitched up again later already "carrying" a job
		-- nobody holds.
		local carrier = contract.Carrier
		local carrierGone = not carrier or not carrier.Parent or not carrier.PrimaryPart
		if not carModel or not carModel.Parent or not carModel.PrimaryPart or carrierGone then
			if not carrierGone then
				CargoManager.Unload(carrier)
			end
			setActiveContract(player, nil)
			stoppedFor[player] = nil
			-- Cancelled, not merely cleared. Both used to arrive as the same
			-- bare { Active = nil }, so losing a job looked exactly like
			-- finishing one - the panel just vanished, with nothing said about
			-- a slot the player had spent ten minutes or 49 Robux on.
			deliveryUpdateEvent:FireClient(player, {
				Active = nil,
				Cancelled = { Destination = contract.Stops[1] },
			})
			continue
		end

		-- Goods reduced to nothing: the mission is over on the spot, wherever the
		-- truck is. Checked before the arrival logic so a wrecked load can never
		-- be paid out at the destination.
		local wrecked = CargoManager.GetLoad(carrier)
		if wrecked.Units > 0 and wrecked.Condition <= 0 then
			setActiveContract(player, nil)
			stoppedFor[player] = nil
			CargoManager.Unload(carrier)
			local failed = { Destination = contract.Stops[1], TypeId = wrecked.TypeId, Units = wrecked.Units }
			deliveryUpdateEvent:FireClient(player, { Active = nil, Failed = failed })
			endRideAlongs(contract, function()
				return { Active = nil, Failed = failed }
			end)
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

		-- A rig delivers with the trailer still on the truck, in a rig bay.
		-- Dropping the trailer short and driving the tractor in does not count -
		-- FindParkedSpace measures the hitched trailer and finds none - and
		-- neither does somebody else's trailer picked up on the way.
		if contract.Rig and Haulage.Trailer(carModel) ~= carrier then
			stoppedFor[player] = 0
			continue
		end

		local space, grade =
			Haulage.FindParkedSpace(carModel, if contract.Rig then destination.RigSpaces else destination.Spaces)
		if not space or not ParkGrade.IsStopped(carModel.PrimaryPart) then
			-- DRAINED, not reset to zero. The difference matters because this
			-- is the one place in the game with no grace period anywhere else
			-- to hide behind: a single failing poll used to throw away the
			-- whole accumulated hold, so a vehicle that was parked for 95% of
			-- frames and jittering for the other 5% could sit in the bay
			-- forever and never be paid - which is exactly what a loaded car
			-- bouncing on its suspension does. ParkGrade.IsStopped now ignores
			-- that bob, but a heavy enough load, a kerb, or another car nudging
			-- the bumper can still produce the odd bad poll, and losing a
			-- delivery to one frame is not a rule anybody would guess.
			--
			-- Draining at the same rate it fills keeps the rule honest: what is
			-- required is a NET second of being stopped, so a vehicle rolling
			-- through the bay fails continuously, drains to zero and is never
			-- paid, which is the behaviour the hold exists for.
			stoppedFor[player] = math.max((stoppedFor[player] or 0) - elapsed, 0)
			continue
		end

		-- Held for a moment before it counts. This is what makes the park a
		-- deliberate act rather than something you can score by rolling
		-- through the bay, and it is also the window in which the server's
		-- copy of a client-owned chassis settles onto the truth.
		local held = (stoppedFor[player] or 0) + elapsed
		stoppedFor[player] = held
		if held >= DeliveryConfig.Parking.StoppedHoldSeconds then
			completeDelivery(player, carrier, contract, space, grade)
		end
	end
end)

-- A player's standing pool of delivery contracts: what is in it, how it
-- refills over real time, and how it turns into the board the depot draws.
--
-- WHY THE POOL IS PERSISTED AND NOT ROLLED PER VISIT. The board used to
-- generate three fresh offers every time a truck rolled into the loading bay,
-- which made "back out and drive in again" a free re-roll - and, once the
-- re-roll is something players can also BUY, a free re-roll is the product
-- being given away. Server-hopping would have been the same hole one step
-- further out, which is why the pool lives in the DataStore rather than in a
-- server's memory: a player who leaves for another server finds the same jobs
-- waiting, minus whatever the clock has legitimately given them since.
--
-- WHAT IS PERSISTED IS A SEED, NOT A CARD. A saved contract is four fields -
-- id, destination, cargo type, and how full a load it is as a FRACTION of the
-- truck's capacity. Everything the player actually reads (crate count, quoted
-- pay, weight band) is derived at display time from the truck they are
-- currently sitting in. That is deliberate:
--
--   * Offers are sized to the truck, which is what makes CargoCapacity worth
--     buying (see DeliveryManager's header). A pool of absolute crate counts
--     frozen at whatever van the player drove last week would quietly undo
--     that - upgrade your bed and the board keeps offering small jobs.
--   * Nothing derived can drift out of sync with the config that derives it.
--     Re-tune payouts, cargo values or the distance bonus and every saved
--     contract re-prices itself on its next draw, with no save migration.
--
-- The one thing this module does NOT do is decide anything about money or
-- security. It is called only by PlotManager (which owns player data) and,
-- through PlotManager's bindables, by DeliveryManager.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
local CargoTypes = require(ReplicatedStorage.Modules.Delivery.CargoTypes)
local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)

local Destinations = require(script.Parent.Destinations)

local ContractPool = {}

local POOL = ProgressionConfig.Contracts

--=============================================================================
-- Generating one contract
--=============================================================================

-- Ids only have to be unique WITHIN one player's pool - they are how the
-- client names the card it clicked, and every accept is checked against that
-- player's own pool. Persisted alongside the pool so a rejoin cannot hand out
-- an id the player is still holding a card for.
local function nextId(data)
	local id = (type(data.NextContractId) == "number" and data.NextContractId or 0) + 1
	data.NextContractId = id
	return id
end

-- Sized as a fraction rather than a crate count - see the header. The range
-- starts at MinUnitsFraction so some jobs are deliberately part loads: a half
-- load of Glassware is a real choice against a full load of Parcels.
local function randomUnitsFraction()
	local minFraction = DeliveryConfig.Contracts.MinUnitsFraction
	return minFraction + math.random() * (1 - minFraction)
end

-- nil when the map has no destinations built yet, which every caller treats as
-- "the board stays as it is" rather than as an error.
local function generate(data)
	local stop = Destinations.RandomName()
	if not stop then
		return nil
	end
	return {
		Id = nextId(data),
		Stop = stop,
		TypeId = CargoTypes.Order[math.random(#CargoTypes.Order)],
		UnitsFraction = randomUnitsFraction(),
	}
end

--=============================================================================
-- Reconciling a save
--=============================================================================

local function isUsableContract(contract)
	return type(contract) == "table"
		and type(contract.Id) == "number"
		and type(contract.Stop) == "string"
		and type(contract.UnitsFraction) == "number"
		and contract.UnitsFraction == contract.UnitsFraction -- NaN
		-- A destination that has since been renamed or deleted in Studio, or a
		-- cargo type retired from CargoTypes, leaves a saved contract naming
		-- something that no longer exists. Dropping it here is what keeps that
		-- from surfacing much later as a nil index at accept time.
		and Destinations.Get(contract.Stop) ~= nil
		and CargoTypes.Get(contract.TypeId) ~= nil
end

-- Called from PlayerDataStore's reconcile, so every field below is guaranteed
-- present and sane by the time anything else touches it. A player with no
-- saved pool at all - which includes every player who existed before contracts
-- were persisted - starts with a FULL board rather than an empty one and a
-- timer: their first sight of the new system should be jobs to do, not a wait.
function ContractPool.Reconcile(data, now)
	now = now or os.time()

	if type(data.NextContractId) ~= "number" or data.NextContractId ~= data.NextContractId then
		data.NextContractId = 0
	end
	if type(data.Deliveries) ~= "number" or data.Deliveries ~= data.Deliveries or data.Deliveries < 0 then
		data.Deliveries = 0
	end
	data.Deliveries = math.floor(data.Deliveries)

	local fresh = type(data.Contracts) ~= "table"
	local kept = {}
	for _, contract in (fresh and {} or data.Contracts) do
		if isUsableContract(contract) then
			table.insert(kept, {
				Id = contract.Id,
				Stop = contract.Stop,
				TypeId = contract.TypeId,
				UnitsFraction = math.clamp(contract.UnitsFraction, 0, 1),
			})
		end
	end
	data.Contracts = kept

	local cap = ContractPool.CapFor(data)
	-- A cap that SHRANK (a milestone re-tuned upward, or the top one lowered)
	-- must not leave a player holding more jobs than the board can draw.
	-- Trimming from the end keeps the oldest, which are the ones they have
	-- already been looking at.
	while #data.Contracts > cap do
		table.remove(data.Contracts)
	end

	if fresh then
		while #data.Contracts < cap do
			local contract = generate(data)
			if not contract then
				break
			end
			table.insert(data.Contracts, contract)
		end
	end

	-- A timestamp from the future is either a clock skew or a tampered save;
	-- either way, treating it as "now" costs the player nothing they had.
	if type(data.ContractsRegenAt) ~= "number" or data.ContractsRegenAt ~= data.ContractsRegenAt then
		data.ContractsRegenAt = 0
	elseif data.ContractsRegenAt > now + POOL.RegenSeconds then
		data.ContractsRegenAt = now + POOL.RegenSeconds
	end

	ContractPool.Regenerate(data, now)
	return data
end

--=============================================================================
-- Cap and the clock
--=============================================================================

function ContractPool.CapFor(data)
	return ProgressionConfig.ContractCapFor(data.Deliveries or 0)
end

-- Hands back however many contract slots real time has earned since the last
-- call, up to the cap. This is the whole refill mechanism, and it runs off
-- os.time() on the SERVER - the client never sends a time and never could,
-- which is what makes "wait it out" and "pay for it" the only two ways to get
-- a fresh board.
--
-- Accrual is capped at the board's size and nothing banks beyond it: a player
-- who has been away for a week comes back to a full board, not to a week's
-- worth of jobs. That is the deliberate trade - the timer is there to shape a
-- session, not to punish anyone for having one.
function ContractPool.Regenerate(data, now)
	now = now or os.time()
	local cap = ContractPool.CapFor(data)
	local contracts = data.Contracts

	if #contracts >= cap then
		-- Full: no timer runs at all, so the next slot's clock starts from the
		-- moment a job is actually taken rather than from some tick the player
		-- was never told about.
		data.ContractsRegenAt = 0
		return data
	end

	local regenAt = data.ContractsRegenAt
	if type(regenAt) ~= "number" or regenAt <= 0 then
		data.ContractsRegenAt = now + POOL.RegenSeconds
		return data
	end

	local steps = 0
	while #contracts < cap and now >= regenAt and steps < POOL.MaxRegenStepsPerCall do
		local contract = generate(data)
		if not contract then
			break -- no destinations built; leave the timer where it is
		end
		table.insert(contracts, contract)
		regenAt += POOL.RegenSeconds
		steps += 1
	end

	if #contracts >= cap then
		data.ContractsRegenAt = 0
	else
		-- After a long absence regenAt can still be in the past even though the
		-- board is not full (the map has no destinations, say). Never leave it
		-- there: a past timestamp would grant a slot on every single call.
		data.ContractsRegenAt = math.max(regenAt, now + 1)
	end

	return data
end

-- Starts the clock if it is not already running. Called after a job leaves the
-- pool, so the wait for a replacement is measured from the moment the board
-- stopped being full.
local function startRegenClock(data, now)
	if data.ContractsRegenAt == nil or data.ContractsRegenAt <= 0 then
		data.ContractsRegenAt = (now or os.time()) + POOL.RegenSeconds
	end
end

--=============================================================================
-- Taking and refreshing
--=============================================================================

-- Removes the named contract and returns its seed, or nil if this player was
-- never holding it. Taking, not completing, is what consumes a slot: the
-- crates are on the truck and the job is off the board the moment it is
-- accepted, which is also what stops a player parking a job on their bed
-- indefinitely while a replacement regenerates behind it.
function ContractPool.Take(data, contractId, now)
	if type(contractId) ~= "number" then
		return nil
	end
	for index, contract in data.Contracts do
		if contract.Id == contractId then
			table.remove(data.Contracts, index)
			startRegenClock(data, now)
			return contract
		end
	end
	return nil
end

-- What the developer product buys: every job on the board thrown away and the
-- board refilled to the player's cap with new ones. Both halves matter - a
-- refill alone would do nothing for the player whose complaint is that the
-- three jobs they already have are bad.
--
-- The regen clock is cleared with it, so a player who buys at four-fifths of a
-- slot does not lose that progress in any meaningful sense: they are full, and
-- the clock restarts the moment they take a job.
function ContractPool.Refresh(data, now)
	now = now or os.time()
	if Destinations.Count() == 0 then
		return false -- nothing to generate; the caller must NOT consume a receipt
	end

	local cap = ContractPool.CapFor(data)
	data.Contracts = {}
	for _ = 1, cap do
		local contract = generate(data)
		if not contract then
			break
		end
		table.insert(data.Contracts, contract)
	end
	data.ContractsRegenAt = 0

	return #data.Contracts > 0
end

-- One lifetime delivery. The only writer of the game's single progression
-- number - the one every gate in the game is stated in - which is why it lives
-- here next to the pool rather than being incremented wherever a payout happens
-- to land.
function ContractPool.RecordDelivery(data)
	data.Deliveries = (data.Deliveries or 0) + 1
	return data.Deliveries
end

--=============================================================================
-- Drawing the board
--=============================================================================

-- Turns a saved seed into the card the client draws, against the truck the
-- player is in RIGHT NOW. `config` is that truck's VehiclePhysics config (or an
-- empty table when they are not in one); `capacity` is CargoLoad.Capacity of
-- it, passed in rather than re-derived so the whole board is quoted off one
-- snapshot of one vehicle.
local function draw(contract, config, capacity)
	local destination = Destinations.Get(contract.Stop)
	if not destination then
		return nil
	end

	local units
	if capacity > 0 then
		local minUnits = math.max(1, math.floor(capacity * DeliveryConfig.Contracts.MinUnitsFraction))
		units = math.clamp(math.floor(contract.UnitsFraction * capacity + 0.5), minUnits, capacity)
	else
		units = DeliveryConfig.Contracts.FallbackUnits
	end

	-- The quoted figure assumes a pristine arrival and a plain nose-in park.
	-- Deliberately the FLOOR of what the job can pay rather than its ceiling: a
	-- player who drives well is rewarded with more than the board promised,
	-- which reads far better than being told a number and then docked for every
	-- scratch.
	local baseValue = CargoLoad.Value(units, contract.TypeId, 1)

	return {
		Id = contract.Id,
		-- One stop today; see DeliveryManager's header for why it is a list.
		Stops = { contract.Stop },
		TypeId = contract.TypeId,
		Units = units,
		QuotedValue = math.floor(baseValue * (1 + destination.DistanceBonus)),
		Distance = destination.Distance,
		-- How much this load adds to the truck, as a fraction of its empty
		-- mass. Computed here rather than on the client because the client has
		-- no business deciding what a vehicle's config says.
		MassFraction = CargoLoad.MassFraction(config, units, contract.TypeId),
	}
end

-- The whole board, plus everything the client needs to explain it: how big the
-- board can get, how long until the next job turns up, and where the player is
-- on the ladder.
--
-- SecondsUntilNext is a DURATION, not a timestamp. A timestamp would be
-- meaningless to a client whose os.time() need not agree with the server's,
-- and the difference would show up as a countdown that starts wrong.
function ContractPool.Board(data, config, capacity, now)
	now = now or os.time()
	ContractPool.Regenerate(data, now)

	local offers = {}
	for _, contract in data.Contracts do
		local card = draw(contract, config, capacity)
		if card then
			table.insert(offers, card)
		end
	end

	local deliveries = data.Deliveries or 0
	local cap = ProgressionConfig.ContractCapFor(deliveries)
	local regenAt = data.ContractsRegenAt

	return {
		Offers = offers,
		Cap = cap,
		Deliveries = deliveries,
		-- { Deliveries, Cap } for the next board-size increase, or nil at the
		-- top. Sent whole rather than as a pre-formatted sentence so the client
		-- can phrase it for whichever panel it is drawing.
		NextCapMilestone = ProgressionConfig.NextCapMilestone(deliveries),
		SecondsUntilNext = if #offers < cap and type(regenAt) == "number" and regenAt > 0
			then math.max(0, regenAt - now)
			else nil,
	}
end

return ContractPool

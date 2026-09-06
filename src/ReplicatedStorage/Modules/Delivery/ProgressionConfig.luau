-- Player progression and the economics of the contract board, in one place so
-- the server that enforces them and the client that draws them can never quote
-- two different numbers - the same reason DeliveryConfig is shared.
--
-- THERE IS ONE PROGRESSION NUMBER IN THIS GAME: how many deliveries the player
-- has finished, ever. No EXP, and no level either. Both were considered and
-- both were the same fact wearing a second name - EXP would have moved in
-- lockstep with the delivery count, and a level was only ever that count looked
-- up in a table. Anything derived is a thing that can disagree with its source
-- and a thing the player has to be taught to convert, so nothing here derives:
-- every gate in the game is stated in deliveries, and every gate is SHOWN to
-- the player in deliveries, in the same unit they are already counting.
--
-- What deliveries gate:
--   * How many contracts the depot board holds at once (ContractCapFor).
--   * Which vehicles the shop will sell (VehicleCatalog's RequiredDeliveries).

local ProgressionConfig = {}

--=============================================================================
-- Contract capacity
--=============================================================================

ProgressionConfig.Contracts = {
	-- The board's size, as milestones in lifetime deliveries. Ordered, lowest
	-- first, and the first entry MUST be 0 - it is what a brand new player
	-- gets.
	--
	-- Three to start is the same number the board offered before it became a
	-- persistent pool, so a new player's first visit to the dock looks exactly
	-- as it always did. It tops out at seven: a board past about that stops
	-- being a choice and starts being a spreadsheet, and every extra slot also
	-- weakens the refresh product by making the pool harder to run dry.
	--
	-- The figures are deliberately round. They are not internal tuning any
	-- more - they are printed on the shop's locked cards and on the board
	-- footer, so "200 deliveries" has to read like a target somebody chose
	-- rather than like the output of a formula.
	CapMilestones = {
		{ Deliveries = 0, Cap = 3 },
		{ Deliveries = 20, Cap = 4 },
		{ Deliveries = 75, Cap = 5 },
		{ Deliveries = 200, Cap = 6 },
		{ Deliveries = 450, Cap = 7 },
	},

	-- HOW THE POOL REFILLS: one contract at a time, on a timer, rather than
	-- the whole board at once every hour.
	--
	-- The all-at-once version is the obvious first design and it is worse in
	-- both directions. A player who empties the board five minutes into the
	-- hour has fifty-five minutes of nothing to do, which is fifty-five
	-- minutes to go and play something else - and a player who happens to log
	-- in just before the tick is handed the refill for free. Trickling makes
	-- the wait proportional to what was actually used: finish one job, one job
	-- comes back.
	--
	-- Ten minutes is set against how long a delivery takes here. A run across
	-- this map is roughly two to four minutes, so a full starting board is
	-- about ten to fifteen minutes of driving - long enough to be a session,
	-- short enough that the board emptying lands while the player is still
	-- engaged, which is exactly when the refresh product is worth buying. A
	-- player at the top milestone with seven slots gets closer to half an hour.
	RegenSeconds = 600,

	-- Accrual is capped at the board's size, full stop (see
	-- ContractPool.Regenerate), so a player who has been away for a week comes
	-- back to a full board and not a hundred banked jobs. This constant only
	-- bounds the catch-up LOOP itself, so a stale timestamp can never spin.
	MaxRegenStepsPerCall = 64,
}

local function sanitizeDeliveries(deliveries)
	if type(deliveries) ~= "number" or deliveries ~= deliveries or deliveries < 0 then
		return 0
	end
	return math.floor(deliveries)
end

-- How many contracts this player's board holds. The one function that turns
-- lifetime deliveries into a board size; the shop, the HUD and the pool all
-- read it, so re-tuning CapMilestones above moves every one of them together.
function ProgressionConfig.ContractCapFor(deliveries)
	deliveries = sanitizeDeliveries(deliveries)
	local cap = ProgressionConfig.Contracts.CapMilestones[1].Cap
	for _, milestone in ProgressionConfig.Contracts.CapMilestones do
		if deliveries >= milestone.Deliveries then
			cap = milestone.Cap
		else
			break -- ordered, so the first one out of reach ends it
		end
	end
	return cap
end

-- The next milestone as { Deliveries, Cap }, or nil once the board cannot grow
-- any further. The board footer turns it into "18 more deliveries for a 4th
-- job" - a target the player cannot see is not one they are working toward.
function ProgressionConfig.NextCapMilestone(deliveries)
	deliveries = sanitizeDeliveries(deliveries)
	for _, milestone in ProgressionConfig.Contracts.CapMilestones do
		if deliveries < milestone.Deliveries then
			return milestone
		end
	end
	return nil
end

-- The board size a brand new player gets. Read off the milestone table rather
-- than written down a second time, so the two can never drift.
function ProgressionConfig.BaseContractCap()
	return ProgressionConfig.Contracts.CapMilestones[1].Cap
end

-- "20 deliveries" / "1 delivery". Every place that prints a delivery count to a
-- player goes through here, because a gate the player reads as "Requires 1
-- deliveries" looks like a bug in the game rather than a target.
function ProgressionConfig.DeliveryCountText(count)
	count = sanitizeDeliveries(count)
	return string.format("%d %s", count, if count == 1 then "delivery" else "deliveries")
end

--=============================================================================
-- Monetization
--=============================================================================

ProgressionConfig.Monetization = {
	-- Developer product: refills the board to the player's cap AND re-rolls
	-- every job already in it. Both halves matter - a refill alone is worth
	-- nothing to a player whose actual complaint is that the three jobs on
	-- offer are bad ones.
	RefreshContractsProductId = 3711621894,
	-- Shown on the button before Roblox answers with the real figure. The
	-- client asks MarketplaceService for the true price on open and corrects
	-- itself, so a stale number here is wrong for one round trip and never
	-- wrong at the moment of purchase - but a button with no number on it is
	-- one the player has to gamble a click on to price, which is worse.
	RefreshContractsPrice = 49,

	-- Developer product: grants temporary third-person camera while driving
	-- (see VehicleViewMode.luau and Monetization.server.luau). A consumable
	-- rather than a one-time gamepass on purpose - it's a comfort/cosmetic
	-- perk with no gameplay advantage, so repeat purchases are the point.
	ThirdPersonProductId = 3711634863,
	-- How long one purchase grants, in seconds. Buying again while already
	-- active adds this on top of whatever time is left rather than
	-- overwriting it - see the grant handler in Monetization.server.luau.
	ThirdPersonDurationSeconds = 20 * 60,
}

return ProgressionConfig

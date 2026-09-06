-- Developer products. Today there is exactly one: refresh the contract board.
--
-- This is the ONLY ProcessReceipt callback in the game, and it has to stay that
-- way - Roblox allows one per server, and a second assignment silently replaces
-- the first, which fails as "players are charged and never get their item" and
-- as nothing else. Every future product routes through the handlers table
-- below rather than through a callback of its own.
--
-- Nothing here touches player data directly. Granting goes through PlotManager's
-- RefreshContracts bindable for the same reason DeliveryManager's payouts go
-- through AwardMoney: PlotManager owns the save, so PlotManager is the only
-- script that writes to one.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)

local refreshContractsFunction = script.Parent:WaitForChild("RefreshContracts")

-- Server -> the buying client, once the board has actually been rebuilt. The
-- client also learns the purchase went through from
-- PromptProductPurchaseFinished, but that fires when ROBLOX is done, not when
-- this server is - so a client that redrew on it alone would sometimes redraw
-- the old board a moment before the new one existed. This event is the "it is
-- done here" signal, and the board is only redrawn on it.
local contractsRefreshedEvent = Instance.new("RemoteEvent")
contractsRefreshedEvent.Name = "ContractsRefreshed"
contractsRefreshedEvent.Parent = ReplicatedStorage

--=============================================================================
-- Grants
--=============================================================================

-- [productId] = function(player) -> boolean granted
local ThirdPersonExpiresAttribute = "ThirdPersonExpiresAt"

local handlers = {
	[ProgressionConfig.Monetization.RefreshContractsProductId] = function(player)
		if not refreshContractsFunction:Invoke(player) then
			return false
		end
		contractsRefreshedEvent:FireClient(player)
		return true
	end,

	-- Third-person-while-driving, read by VehicleViewMode.luau on the
	-- client. Stacks on top of whatever time is left rather than resetting
	-- from now, so buying again while it's still active is never wasted -
	-- the perk is time, not a light switch. Set as a plain Attribute:
	-- replicates to the owning client for free and needs no save (it's
	-- meant to run out), so unlike the contract refresh above there is no
	-- PlotManager/DataStore involved.
	[ProgressionConfig.Monetization.ThirdPersonProductId] = function(player)
		local now = os.time()
		local current = player:GetAttribute(ThirdPersonExpiresAttribute)
		local base = if type(current) == "number" and current > now then current else now
		player:SetAttribute(ThirdPersonExpiresAttribute, base + ProgressionConfig.Monetization.ThirdPersonDurationSeconds)
		return true
	end,
}

--=============================================================================
-- ProcessReceipt
--=============================================================================

-- [purchaseId] = true for receipts this SERVER has already honoured. Roblox
-- re-presents a receipt until it is told the purchase was granted, and a retry
-- that arrives while the first grant is still in flight would otherwise re-roll
-- the board a second time - the player paid once and would watch the jobs they
-- just bought get replaced.
--
-- Deliberately in memory and not a DataStore. It closes the only window that
-- actually exists in practice (a retry seconds later, in this server), and the
-- alternative - a persisted purchase history - is a DataStore read on the
-- critical path of every purchase, for a product whose worst case if it ever
-- DID double-grant is one extra board refresh in the player's favour. That
-- trade is only acceptable because this product grants no currency and nothing
-- tradeable; a product that did would need the real history store.
local granted = {}

local function processReceipt(receiptInfo)
	if granted[receiptInfo.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- They left mid-purchase. NOT granted: Roblox re-presents the receipt
		-- the next time they join a server, and this is what makes them get
		-- what they paid for then instead of losing it now.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local handler = handlers[receiptInfo.ProductId]
	if not handler then
		warn(
			"Monetization: no handler for product "
				.. tostring(receiptInfo.ProductId)
				.. " - leaving the receipt unprocessed so it is not silently eaten. Add it to `handlers`."
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- pcall so an error inside a grant cannot bubble out of ProcessReceipt.
	-- Roblox treats a callback that throws as "not processed", which is the
	-- right outcome here anyway - but it also means an unhandled error would be
	-- retried forever with nothing said about why.
	local ok, result = pcall(handler, player)
	if not ok then
		warn("Monetization: granting product " .. tostring(receiptInfo.ProductId) .. " failed: " .. tostring(result))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not result then
		-- The grant declined rather than errored - the player's data has not
		-- finished loading, or the place file has no destinations built, so
		-- there is no board to hand them. Never consume a receipt for something
		-- that did not happen: a consumed receipt is gone for good.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	granted[receiptInfo.PurchaseId] = true
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

MarketplaceService.ProcessReceipt = processReceipt

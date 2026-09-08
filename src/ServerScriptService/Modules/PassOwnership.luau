-- "Does this player own this game pass?", cached, so the rest of the server
-- can ask the question wherever it needs to without thinking about it.
--
-- WHY A CACHE AND NOT JUST UserOwnsGamePassAsync. That call is a web request:
-- it yields for as long as Roblox takes, and it throws on a failed request
-- rather than returning false. The garage terminal asks this question up to
-- ten times per open (once per gated stat, per car), and PlotManager asks it
-- again on every upgrade purchase and every tuning change - which on a dragged
-- value is several a second. Unwrapped, that is a web call per frame on the
-- critical path of a button press.
--
-- WHY IT NEVER EXPIRES. A cached true stays true - a pass cannot be revoked -
-- and a cached false is corrected the moment it stops being true, because the
-- only way to go from not-owning to owning inside a session is to buy it, and
-- buying it fires PromptGamePassPurchaseFinished, which this listens to. A
-- player who buys the pass on the Roblox website in another tab is the one
-- case this misses, and they get it on their next join.
--
-- A FAILED LOOKUP IS NOT CACHED. If the web call throws, this returns false
-- for that one ask and leaves the entry unset, so the next ask retries. The
-- alternative - remembering the failure - would lock a paying player out of
-- what they bought for the rest of the session because of one bad request.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local PassOwnership = {}

-- [userId] = { [passId] = boolean }
local cache = {}

Players.PlayerRemoving:Connect(function(player)
	cache[player.UserId] = nil
end)

-- Yields on a cache miss. Every caller is either a RemoteFunction handler or a
-- task.spawn, both of which may yield; making this non-yielding would mean
-- answering "no" to a player who does own the pass, which is the one wrong
-- answer that costs someone something they paid for.
function PassOwnership.Owns(player, passId)
	if type(passId) ~= "number" then
		return false
	end
	local forPlayer = cache[player.UserId]
	if forPlayer and forPlayer[passId] ~= nil then
		return forPlayer[passId]
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	if not ok then
		warn("PassOwnership: ownership check failed for pass " .. tostring(passId) .. " - treating as not owned for this call only")
		return false
	end

	-- Re-read rather than reusing `forPlayer`: this yielded, and the player
	-- may have left and (in a long-lived server) rejoined in the meantime, in
	-- which case the table this captured before the yield is one nobody reads
	-- any more.
	if not player.Parent then
		return owns
	end
	forPlayer = cache[player.UserId]
	if not forPlayer then
		forPlayer = {}
		cache[player.UserId] = forPlayer
	end
	forPlayer[passId] = owns
	return owns
end

-- Warms the cache so the first real ask - which happens inside a terminal
-- open, where a yield is a visible stall - is already answered. Fire-and-
-- forget on purpose: nothing waits on this, and a failure just means the
-- first real ask pays the web call itself.
function PassOwnership.Prefetch(player, passIds)
	task.spawn(function()
		for _, passId in passIds do
			if not player.Parent then
				return
			end
			PassOwnership.Owns(player, passId)
		end
	end)
end

-- The purchase this server just watched go through. Written straight into the
-- cache rather than invalidated-and-refetched: the event IS the answer, and a
-- refetch would race the purchase's own propagation and can come back false
-- for a second or two afterwards.
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	if not wasPurchased then
		return
	end
	local forPlayer = cache[player.UserId]
	if not forPlayer then
		forPlayer = {}
		cache[player.UserId] = forPlayer
	end
	forPlayer[passId] = true
end)

return PassOwnership

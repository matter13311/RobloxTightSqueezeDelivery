-- Who may use the express toll road, answered the same way on both sides.
--
-- Access lives in two replicated attributes on the Player, written only by
-- the server (ExpressToll.server.luau and Monetization.server.luau):
--
--   ExpressAccessUntil  number - unix time a ticket runs out at
--   ExpressPassOwned    boolean - owns the permanent game pass
--
-- The gates themselves are enforced on each CLIENT, the same way plot walls
-- are (see Modules/Plots/PlotBarrier.luau for the full reasoning): a wall
-- that exists only for the players who have NOT paid stops exactly those
-- players, at the surface, with nothing for the server to fight.

local ProgressionConfig = require(script.Parent.Parent.Delivery.ProgressionConfig)

local ExpressAccess = {}

ExpressAccess.UNTIL_ATTRIBUTE = "ExpressAccessUntil"
ExpressAccess.PASS_ATTRIBUTE = "ExpressPassOwned"

-- Where the map keeps the gate descriptions. Each is an invisible,
-- non-colliding part with a GateKind ("Toll"/"Exit") and an Outward vector
-- attribute pointing to the side the gate keeps people OUT of.
ExpressAccess.GATES_PATH = { "Map", "Express", "ExpressGates" }
ExpressAccess.PAY_ZONE_NAME = "TollPayZone"

local function now()
	-- GetServerTimeNow is the server's clock as seen from here, so a client
	-- whose own clock is wrong still agrees with the server about expiry.
	return workspace:GetServerTimeNow()
end

function ExpressAccess.SecondsLeft(player)
	local untilTime = player:GetAttribute(ExpressAccess.UNTIL_ATTRIBUTE)
	if type(untilTime) ~= "number" then
		return 0
	end
	return math.max(0, untilTime - now())
end

function ExpressAccess.HasAccess(player)
	return player:GetAttribute(ExpressAccess.PASS_ATTRIBUTE) == true or ExpressAccess.SecondsLeft(player) > 0
end

function ExpressAccess.TicketConfigured()
	return ProgressionConfig.Monetization.ExpressTicketProductId ~= 0
end

function ExpressAccess.PassConfigured()
	return ProgressionConfig.Monetization.ExpressPassGamePassId ~= 0
end

function ExpressAccess.FindGates()
	local node = workspace
	for _, name in ExpressAccess.GATES_PATH do
		node = node and node:FindFirstChild(name)
	end
	return node
end

return ExpressAccess

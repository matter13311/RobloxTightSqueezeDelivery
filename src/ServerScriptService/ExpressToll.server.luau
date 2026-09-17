-- Server half of the express toll road: keeps each player's access
-- attributes true. The walls are on the clients (ExpressGates.client.luau);
-- the ticket's receipt is granted in Monetization.server.luau, because that
-- script must stay the only ProcessReceipt in the game.
--
-- What this script owns:
--   * ExpressPassOwned, from the game pass, at join and on purchase.
--   * The Studio-only free test ticket, so the route can be driven before
--     the real product exists (see ProgressionConfig.Monetization).

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ProgressionConfig = require(ReplicatedStorage.Modules.Delivery.ProgressionConfig)
local ExpressAccess = require(ReplicatedStorage.Modules.Express.ExpressAccess)
local PassOwnership = require(script.Parent.Modules.PassOwnership)

local monetization = ProgressionConfig.Monetization

-- Client -> server: "give me a test ticket". Created unconditionally so the
-- client's WaitForChild never hangs, but it only ever grants anything inside
-- Studio AND while the real product is still unset.
local testTicketEvent = Instance.new("RemoteEvent")
testTicketEvent.Name = "RequestExpressTestTicket"
testTicketEvent.Parent = ReplicatedStorage

local function refreshPass(player)
	if not ExpressAccess.PassConfigured() then
		return
	end
	if PassOwnership.Owns(player, monetization.ExpressPassGamePassId) and player.Parent then
		player:SetAttribute(ExpressAccess.PASS_ATTRIBUTE, true)
	end
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(refreshPass, player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(refreshPass, player)
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, wasPurchased)
	if wasPurchased and passId == monetization.ExpressPassGamePassId and ExpressAccess.PassConfigured() then
		player:SetAttribute(ExpressAccess.PASS_ATTRIBUTE, true)
	end
end)

testTicketEvent.OnServerEvent:Connect(function(player)
	if not RunService:IsStudio() or ExpressAccess.TicketConfigured() then
		return
	end
	local current = player:GetAttribute(ExpressAccess.UNTIL_ATTRIBUTE)
	local base = if type(current) == "number" and current > os.time() then current else os.time()
	player:SetAttribute(ExpressAccess.UNTIL_ATTRIBUTE, base + monetization.ExpressTicketDurationSeconds)
end)

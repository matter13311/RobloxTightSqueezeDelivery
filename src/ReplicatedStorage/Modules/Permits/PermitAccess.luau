-- Who may drive into which zone, answered the same way on both sides.
--
-- Ownership lives in the save (PlayerDataStore's Permits) and is mirrored onto
-- the Player as one replicated boolean attribute per permit, written only by
-- the server (PlotManager.server.luau): "Permit_CanalBridge" and so on. The
-- crossing barriers are per-client walls, the same pattern as the express
-- gates (see ExpressAccess.luau / PlotBarrier.luau for the reasoning).

local ProgressionConfig = require(script.Parent.Parent.Delivery.ProgressionConfig)

local PermitAccess = {}

PermitAccess.ATTRIBUTE_PREFIX = "Permit_"
PermitAccess.GATES_PATH = { "Map", "Permits", "PermitGates" }
PermitAccess.PAY_ZONE_NAME = "PermitPayZone"
PermitAccess.BOOM_NAME = "PermitBoomPivot"

function PermitAccess.AttributeName(permitId)
	return PermitAccess.ATTRIBUTE_PREFIX .. permitId
end

function PermitAccess.Has(player, permitId)
	return player:GetAttribute(PermitAccess.AttributeName(permitId)) == true
end

-- { [permitId] = true } for everything this player holds.
function PermitAccess.Owned(player)
	local owned = {}
	for _, id in ProgressionConfig.Permits.Order do
		if PermitAccess.Has(player, id) then
			owned[id] = true
		end
	end
	return owned
end

function PermitAccess.UnlockedZone(player)
	return ProgressionConfig.UnlockedZone(PermitAccess.Owned(player))
end

-- Why this player can't buy a permit right now, or nil if they can.
-- `money`/`deliveries` passed in so the server can answer from the save and
-- the client from its leaderstats with the same rules.
function PermitAccess.BlockReason(permitId, owned, money, deliveries)
	local def = ProgressionConfig.Permits[permitId]
	if not def then
		return "Unknown permit"
	end
	if owned[permitId] then
		return "Already owned"
	end
	if def.Requires and not owned[def.Requires] then
		return "Needs the " .. ProgressionConfig.Permits[def.Requires].DisplayName .. " first"
	end
	if (deliveries or 0) < def.RequiredDeliveries then
		return "Needs " .. ProgressionConfig.DeliveryCountText(def.RequiredDeliveries)
	end
	if (money or 0) < def.Price then
		return "Not enough money"
	end
	return nil
end

function PermitAccess.FindGates()
	local node = workspace
	for _, name in PermitAccess.GATES_PATH do
		node = node and node:FindFirstChild(name)
	end
	return node
end

return PermitAccess

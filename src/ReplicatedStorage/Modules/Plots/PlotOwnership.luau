-- Who owns a given vehicle plot (game.Workspace.Spawn.VehiclePlots.*). Shared
-- the same way VehicleOwnership.luau is: attributes on the plot MODEL, so
-- ownership replicates on its own and every script (server claim logic,
-- PlotCollisionGuard, the client's terminal prompt/GUI) reads the same
-- answer without needing to share a Lua table.
--
-- Ownership is session-only and lives entirely in these attributes - nothing
-- here is persisted, and every plot is force-cleared back to unowned at
-- server start (see PlotManager.server.luau). That's the whole mechanism
-- behind "a plot resets if you leave and rejoin".

local PlotOwnership = {}

PlotOwnership.OWNER_USERID_ATTRIBUTE = "OwnerUserId"
PlotOwnership.OWNER_NAME_ATTRIBUTE = "OwnerName"

-- nil = unclaimed.
function PlotOwnership.GetOwnerUserId(plotModel)
	local ownerUserId = plotModel:GetAttribute(PlotOwnership.OWNER_USERID_ATTRIBUTE)
	return if type(ownerUserId) == "number" then ownerUserId else nil
end

function PlotOwnership.GetOwnerName(plotModel)
	local ownerName = plotModel:GetAttribute(PlotOwnership.OWNER_NAME_ATTRIBUTE)
	return if type(ownerName) == "string" then ownerName else nil
end

function PlotOwnership.IsClaimed(plotModel)
	return PlotOwnership.GetOwnerUserId(plotModel) ~= nil
end

function PlotOwnership.IsOwner(player, plotModel)
	return PlotOwnership.GetOwnerUserId(plotModel) == player.UserId
end

function PlotOwnership.SetOwner(plotModel, player)
	plotModel:SetAttribute(PlotOwnership.OWNER_USERID_ATTRIBUTE, player.UserId)
	plotModel:SetAttribute(PlotOwnership.OWNER_NAME_ATTRIBUTE, player.Name)
end

function PlotOwnership.ClearOwner(plotModel)
	plotModel:SetAttribute(PlotOwnership.OWNER_USERID_ATTRIBUTE, nil)
	plotModel:SetAttribute(PlotOwnership.OWNER_NAME_ATTRIBUTE, nil)
end

return PlotOwnership

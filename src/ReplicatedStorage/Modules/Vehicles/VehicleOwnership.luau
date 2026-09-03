-- Who is allowed to get into a given car. Shared deliberately: the server
-- enforces it (VehicleDoors.server.luau) and the client uses the SAME answer
-- to decide whether to even show an "Enter" prompt, so a player is never
-- offered a car they'd be refused. Enforcement still lives on the server -
-- this module is the rule, not the guard.
--
-- Ownership is a plain attribute on the car MODEL:
--   OwnerUserId (number) - the player who owns this car.
--
-- An attribute is used rather than a table in here so ownership replicates on
-- its own and survives this module being required separately on each side.
--
-- A car with no OwnerUserId is unowned and open to everyone. That's what
-- keeps cars placed by hand in Studio drivable without any spawning system
-- existing yet - once cars are spawned per player, set the attribute at spawn
-- time and they become private with no further changes here.

local VehicleOwnership = {}

VehicleOwnership.OWNER_ATTRIBUTE = "OwnerUserId"

-- nil = unowned.
function VehicleOwnership.GetOwnerUserId(carModel)
	local ownerUserId = carModel:GetAttribute(VehicleOwnership.OWNER_ATTRIBUTE)
	return if type(ownerUserId) == "number" then ownerUserId else nil
end

function VehicleOwnership.SetOwner(carModel, player)
	carModel:SetAttribute(VehicleOwnership.OWNER_ATTRIBUTE, player and player.UserId or nil)
end

-- The one question both sides ask. When the planned "let my friend drive it"
-- feature arrives, it goes HERE - a permitted-users list checked alongside
-- the owner - and both the prompt and the server gate pick it up together.
function VehicleOwnership.CanEnter(player, carModel)
	local ownerUserId = VehicleOwnership.GetOwnerUserId(carModel)
	if not ownerUserId then
		return true
	end
	return player.UserId == ownerUserId
end

return VehicleOwnership

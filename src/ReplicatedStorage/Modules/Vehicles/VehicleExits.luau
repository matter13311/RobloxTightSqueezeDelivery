-- Picks which ground-level exit spot a seat's occupant should be teleported
-- to when they get out. A car's Chassis carries one Attachment per exit,
-- named Exit1, Exit2, ... (ground level, just outside a door - see
-- RayCastSuspension.client.luau's exitCFrame for how the stand height on top
-- of that is worked out). Each seat (DriverSeat, and any passenger seats
-- added later) carries a PreferredExit attribute naming which one it wants
-- first, e.g. PreferredExit = "Exit1".
--
-- The preferred exit is used whenever it's clear. If something's in the way
-- - the car parked with that door against a wall, another player standing
-- right where you'd land - the next-nearest exit that IS clear is used
-- instead, so players don't get wedged into geometry on the way out.
--
-- Server-authoritative: VehicleDoors.server.luau calls this to decide which
-- exit to send the client to, and plays the door cue at that same attachment
-- so what you hear and where you land always agree.
--
-- These attachments are also what "the door is over there" MEANS now that
-- doors don't swing: the enter prompt's range and the server's enter check are
-- both measured to them. They live on the Chassis, so unlike a door panel they
-- cannot be knocked off in a crash and take the way in with them.

local VehicleExits = {}

-- Bounding box used to test whether a standing character actually fits at a
-- candidate exit - wide/deep enough to cover a character's footprint with
-- some margin, tall enough to cover a standing rig.
local CLEARANCE_SIZE = Vector3.new(3, 5, 3)

local function exitPosition(exit)
	if exit:IsA("Attachment") then
		return exit.WorldPosition
	end
	return exit.Position
end

-- All Exit# attachments parented directly to the car's Chassis (PrimaryPart),
-- in name order (Exit1, Exit2, ...) purely so fallback selection is stable
-- rather than depending on GetChildren() order.
function VehicleExits.GetExits(carModel)
	local chassis = carModel.PrimaryPart
	if not chassis then
		return {}
	end

	local exits = {}
	for _, child in chassis:GetChildren() do
		if child:IsA("Attachment") and child.Name:match("^Exit%d+$") then
			table.insert(exits, child)
		end
	end
	table.sort(exits, function(a, b)
		return a.Name < b.Name
	end)
	return exits
end

-- Whether a character could actually stand at this exit right now - nothing
-- solid (a wall, the car's own body, another character) occupying the space
-- immediately above it. The car and the exiting character themselves are
-- excluded so they can't block their own exit check.
function VehicleExits.IsExitClear(carModel, exit, character)
	local exclude = { carModel }
	if character then
		table.insert(exclude, character)
	end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = exclude

	local checkCFrame = CFrame.new(exitPosition(exit) + Vector3.new(0, CLEARANCE_SIZE.Y / 2, 0))
	local parts = workspace:GetPartBoundsInBox(checkCFrame, CLEARANCE_SIZE, overlapParams)
	for _, part in parts do
		if part.CanCollide then
			return false
		end
	end
	return true
end

-- Chooses which exit `character` should step out of, given the seat they're
-- leaving. Preferred exit (from the seat's PreferredExit attribute) wins
-- whenever it's clear; otherwise the nearest OTHER clear exit is used.
-- Falls back to the preferred exit (or just the first exit found) if nothing
-- is clear, so a player is never simply refused - worst case they land
-- somewhere a little cramped rather than not moving at all.
function VehicleExits.ChooseExit(carModel, seat, character)
	local exits = VehicleExits.GetExits(carModel)
	if #exits == 0 then
		return nil
	end

	local preferredName = seat and seat:GetAttribute("PreferredExit")
	local preferred = preferredName and carModel.PrimaryPart:FindFirstChild(preferredName)

	if preferred and VehicleExits.IsExitClear(carModel, preferred, character) then
		return preferred
	end

	local referencePosition = preferred and exitPosition(preferred) or seat.Position
	local fallbacks = {}
	for _, exit in exits do
		if exit ~= preferred then
			table.insert(fallbacks, exit)
		end
	end
	table.sort(fallbacks, function(a, b)
		return (exitPosition(a) - referencePosition).Magnitude < (exitPosition(b) - referencePosition).Magnitude
	end)

	for _, exit in fallbacks do
		if VehicleExits.IsExitClear(carModel, exit, character) then
			return exit
		end
	end

	return preferred or exits[1]
end

return VehicleExits

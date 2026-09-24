-- Headlight and turn-signal switches. Server-authoritative for the same
-- reason VehicleNetworkState is: an Attribute set here replicates to every
-- client identically (including one that wasn't even looking at the car yet
-- when it was toggled), so there's exactly one source of truth for whether
-- the lights are on.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local DayNight = require(ReplicatedStorage.Modules.World.DayNight)

local toggleHeadlights = Instance.new("RemoteEvent")
toggleHeadlights.Name = "ToggleHeadlights"
toggleHeadlights.Parent = ReplicatedStorage

local toggleTurnSignal = Instance.new("RemoteEvent")
toggleTurnSignal.Name = "ToggleTurnSignal"
toggleTurnSignal.Parent = ReplicatedStorage

-- Only the player actually sitting in THIS car may speak for it - without
-- this check any client could flip any other car's lights.
local function driverOf(vehicle)
	if typeof(vehicle) ~= "Instance" or not vehicle:IsA("Model") or vehicle.Parent ~= workspace.Vehicles then
		return nil
	end
	local seat = VehicleSeats.GetDriverSeat(vehicle)
	local occupant = seat and seat.Occupant
	return occupant and Players:GetPlayerFromCharacter(occupant.Parent)
end

toggleHeadlights.OnServerEvent:Connect(function(player, vehicle)
	if driverOf(vehicle) ~= player then
		return
	end
	vehicle:SetAttribute("HeadlightsOn", not vehicle:GetAttribute("HeadlightsOn"))
end)

toggleTurnSignal.OnServerEvent:Connect(function(player, vehicle, side)
	if driverOf(vehicle) ~= player then
		return
	end
	if side ~= "Left" and side ~= "Right" then
		return
	end

	-- Pressing the side that's already active turns it off; pressing the
	-- other side switches straight to it - never both signals at once.
	local current = vehicle:GetAttribute("TurnSignal")
	local newSignal = if current == side then "None" else side
	vehicle:SetAttribute("TurnSignal", newSignal)

	-- Same reasoning as VehicleNetworkState's brake/reverse mirroring: a
	-- towed trailer has no signal stalk of its own, so it just repeats
	-- whichever side the tractor towing it is indicating.
	local trailer = TrailerHitch.GetHitchedTrailer(vehicle)
	if trailer then
		trailer:SetAttribute("TurnSignal", newSignal)
	end
end)


-- ===== Automatic headlights =====
--
-- The lights come on at dusk and go off at dawn, for every car at once.
--
-- ONLY ON THE TRANSITIONS, WHICH IS THE WHOLE DESIGN. A driver who flicks
-- their own lights off at midnight keeps them off: nothing here touches the
-- attribute again until dawn actually breaks. Re-asserting it on a timer would
-- mean the switch silently undoing the player a second after they pressed it,
-- which reads as a broken switch rather than a convenience. The cost of that
-- choice is that manual state is forgotten at the next transition, which is
-- also what a real automatic headlight does.
--
-- A car that spawns between transitions gets the right starting position from
-- Raycast.server.luau instead, which reads the same clock.
local wasDark = DayNight.IsDark(Lighting.ClockTime)

Lighting:GetPropertyChangedSignal("ClockTime"):Connect(function()
	local isDark = DayNight.IsDark(Lighting.ClockTime)
	if isDark == wasDark then
		return
	end
	wasDark = isDark

	for _, vehicle in workspace.Vehicles:GetChildren() do
		vehicle:SetAttribute("HeadlightsOn", isDark)
	end
end)

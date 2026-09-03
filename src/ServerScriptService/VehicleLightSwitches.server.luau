-- Headlight and turn-signal switches. Server-authoritative for the same
-- reason VehicleNetworkState is: an Attribute set here replicates to every
-- client identically (including one that wasn't even looking at the car yet
-- when it was toggled), so there's exactly one source of truth for whether
-- the lights are on.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

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
	vehicle:SetAttribute("TurnSignal", if current == side then "None" else side)
end)

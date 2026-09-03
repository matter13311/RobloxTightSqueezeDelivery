-- Relays the driving client's pedal/handbrake state onto the vehicle as
-- Attributes, so bystanders can see it too. Nothing about *why* these values
-- are what they are lives here - that's the Gearbox's job on the driving
-- client - this script only ever repeats what it's told, after checking the
-- sender is actually allowed to speak for that car.
--
-- Attributes are used (rather than a second RemoteEvent broadcast to every
-- other client) because a value set on the server replicates to everyone,
-- including a player who joins or walks into view later and just reads the
-- vehicle's current state directly - no "catch up" message needed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local remote = Instance.new("RemoteEvent")
remote.Name = "VehicleNetworkState"
remote.Parent = ReplicatedStorage

-- Client input is never trusted at face value - coerced to the exact types
-- the attributes are meant to hold, so a malformed or hostile payload can, at
-- worst, set the sender's own car's lights on, never anything stranger.
local function toBoolean(value)
	return value == true
end

local function toThrottle(value)
	if typeof(value) ~= "number" then
		return 0
	end
	return math.clamp(value, -1, 1)
end

-- Rpm is Gearbox's 0-1 normalized value (see Gearbox.new's IdleRpm floor),
-- never signed like throttle.
local function toRpm(value)
	if typeof(value) ~= "number" then
		return 0
	end
	return math.clamp(value, 0, 1)
end

remote.OnServerEvent:Connect(function(player, vehicle, isBraking, isReversing, isBurnout, isHandbrake, throttle, rpm)
	if typeof(vehicle) ~= "Instance" or not vehicle:IsA("Model") or vehicle.Parent ~= workspace.Vehicles then
		return
	end

	-- Only the DRIVER of this car may speak for it - a passenger sitting in a
	-- PassengerSeat has no throttle/brake/handbrake of their own to report.
	local seat = VehicleSeats.GetDriverSeat(vehicle)
	local occupant = seat and seat.Occupant
	local occupantPlayer = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
	if occupantPlayer ~= player then
		return
	end

	vehicle:SetAttribute("NetBraking", toBoolean(isBraking))
	vehicle:SetAttribute("NetReversing", toBoolean(isReversing))
	vehicle:SetAttribute("NetBurnout", toBoolean(isBurnout))
	vehicle:SetAttribute("NetHandbrake", toBoolean(isHandbrake))
	vehicle:SetAttribute("NetThrottle", toThrottle(throttle))
	vehicle:SetAttribute("NetRpm", toRpm(rpm))
end)

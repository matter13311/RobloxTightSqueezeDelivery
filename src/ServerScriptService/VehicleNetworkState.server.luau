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

local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)
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

-- Steer is the driving client's SMOOTHED steer (-1..1 of full lock), not the
-- raw key axis - it's the exact number that client feeds its own wheel
-- visuals, so a bystander reproducing it lands on the same wheel frame the
-- driver does. That frame is what the tire-slip measurement is taken in, so
-- without this a bystander measures a steered front wheel's "sideways"
-- velocity in the chassis frame and reads an ordinary turn as a slide.
local function toSteer(value)
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

-- A counter the driving client bumps on every gearshift, relayed so bystanders
-- can hear another car's anti-lag crack between gears (see InductionEffects).
-- A COUNTER rather than a boolean because a shift is a one-frame event and a
-- boolean set and cleared inside one network tick simply never arrives - what
-- replicates is the value at the moment it is sampled, and that is almost
-- always false. A number that only ever goes up cannot be missed: a receiver
-- compares it with the last one it saw.
--
-- Wrapped well below 2^53 rather than trusted to stay small, since the value
-- comes from a client and nothing else here bounds how long a drive lasts.
local function toShiftCount(value)
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end
	return math.floor(math.clamp(value, 0, 1e9))
end

remote.OnServerEvent:Connect(function(player, vehicle, isBraking, isReversing, isBurnout, isHandbrake, throttle, rpm, steer, shiftCount, isTwoStep, isAntiLag)
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

	local netBraking = toBoolean(isBraking)
	local netReversing = toBoolean(isReversing)
	vehicle:SetAttribute("NetBraking", netBraking)
	vehicle:SetAttribute("NetReversing", netReversing)
	vehicle:SetAttribute("NetBurnout", toBoolean(isBurnout))

	-- A towed trailer has no pedals of its own - its brake/reverse lights
	-- just repeat whatever the tractor towing it is doing, the same way a
	-- real trailer's lights are wired through to the tow vehicle's.
	local trailer = TrailerHitch.GetHitchedTrailer(vehicle)
	if trailer then
		trailer:SetAttribute("NetBraking", netBraking)
		trailer:SetAttribute("NetReversing", netReversing)
	end
	vehicle:SetAttribute("NetHandbrake", toBoolean(isHandbrake))
	vehicle:SetAttribute("NetThrottle", toThrottle(throttle))
	vehicle:SetAttribute("NetRpm", toRpm(rpm))
	vehicle:SetAttribute("NetSteer", toSteer(steer))
	vehicle:SetAttribute("NetShiftCount", toShiftCount(shiftCount))
	-- Brake and gas held together at a standstill: a two-step launch being
	-- held. Sustained rather than momentary, so unlike the shift above a plain
	-- boolean is exactly right.
	vehicle:SetAttribute("NetTwoStep", toBoolean(isTwoStep))
	-- W+S held together: anti-lag. Sustained, so a plain boolean.
	vehicle:SetAttribute("NetAntiLag", toBoolean(isAntiLag))
end)

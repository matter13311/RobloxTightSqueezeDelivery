-- Shared seat lookup. A car has exactly one DriverSeat (drives the car,
-- controls lights/turn signals, owns network ownership) and zero or more
-- PassengerSeat1, PassengerSeat2, ... (ride along only). Centralised here so
-- every script agrees on those names instead of each re-deriving "the seat"
-- its own way - which is what broke when VehicleSeat got renamed to
-- DriverSeat: several scripts were indexing carModel.VehicleSeat directly.

local Players = game:GetService("Players")

local VehicleSeats = {}

function VehicleSeats.GetDriverSeat(carModel)
	return carModel:FindFirstChild("DriverSeat")
end

-- The Player currently DRIVING this car, or nil. A passenger is not a driver
-- and neither is somebody standing beside it - several systems (crash reports,
-- cargo loading, delivery payouts) all need exactly this question answered the
-- same way, so it is answered once here.
function VehicleSeats.GetDriverPlayer(carModel)
	local seat = VehicleSeats.GetDriverSeat(carModel)
	local occupant = seat and seat.Occupant
	return occupant and Players:GetPlayerFromCharacter(occupant.Parent) or nil
end

-- The inverse: which car in `vehicleFolder` this player is driving, if any.
-- A linear scan, which is fine at the handful of vehicles a server holds and
-- avoids keeping a lookup table that could drift from the actual seats.
function VehicleSeats.FindCarDrivenBy(player, vehicleFolder)
	for _, carModel in vehicleFolder:GetChildren() do
		if carModel:IsA("Model") and VehicleSeats.GetDriverPlayer(carModel) == player then
			return carModel
		end
	end
	return nil
end

function VehicleSeats.GetPassengerSeats(carModel)
	local seats = {}
	for _, child in carModel:GetChildren() do
		if child:IsA("VehicleSeat") and child.Name:match("^PassengerSeat%d+$") then
			table.insert(seats, child)
		end
	end
	table.sort(seats, function(a, b)
		return a.Name < b.Name
	end)
	return seats
end

-- Driver seat first (if present), then passenger seats in name order.
function VehicleSeats.GetAllSeats(carModel)
	local seats = {}
	local driverSeat = VehicleSeats.GetDriverSeat(carModel)
	if driverSeat then
		table.insert(seats, driverSeat)
	end
	for _, seat in VehicleSeats.GetPassengerSeats(carModel) do
		table.insert(seats, seat)
	end
	return seats
end

return VehicleSeats

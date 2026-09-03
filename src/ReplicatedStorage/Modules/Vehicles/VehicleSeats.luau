-- Shared seat lookup. A car has exactly one DriverSeat (drives the car,
-- controls lights/turn signals, owns network ownership) and zero or more
-- PassengerSeat1, PassengerSeat2, ... (ride along only). Centralised here so
-- every script agrees on those names instead of each re-deriving "the seat"
-- its own way - which is what broke when VehicleSeat got renamed to
-- DriverSeat: several scripts were indexing carModel.VehicleSeat directly.

local VehicleSeats = {}

function VehicleSeats.GetDriverSeat(carModel)
	return carModel:FindFirstChild("DriverSeat")
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

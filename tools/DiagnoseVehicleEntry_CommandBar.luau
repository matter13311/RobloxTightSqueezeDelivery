-- Not synced by Rojo. Run DURING A PLAY TEST with the command bar set to
-- CLIENT context, standing where you would normally press F.
--
-- Pressing F does nothing is a silent failure by design: every gate on the way
-- in returns rather than warns, because each of them is also the guard against
-- a forged request. That makes it invisible from the outside. This walks the
-- same gates in the same order and says which one stops you.
--
-- The gates, client first then server:
--   1. VehicleDoorPrompts built a prompt for this car at all
--   2. ShouldShow  - seat unoccupied, and VehicleOwnership.CanEnter
--   3. CustomPrompt range - within MAX_PROMPT_DISTANCE (6) of a DOOR ATTACHMENT,
--      which lives on the INTERIOR frame, not on the outer skin. This is the
--      one that collision hulls can break: if the hulls hold you further off
--      the truck than the body meshes used to, you can no longer physically
--      get close enough for the prompt to appear.
--   4. server: carsData[carModel] exists (VehicleDoors set the car up)
--   5. server: within MAX_ENTER_DISTANCE (12) of the nearest door
--   6. server: not Busy, seat unoccupied, not already seated somewhere

local Players = game:GetService("Players")

local VehicleDoorRig = require(game.ReplicatedStorage.Modules.Vehicles.VehicleDoorRig)
local VehicleOwnership = require(game.ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehicleSeats = require(game.ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local MAX_PROMPT_DISTANCE = 6 -- must match VehicleDoorPrompts.client.luau
local MAX_ENTER_DISTANCE = 12 -- must match VehicleDoors.server.luau

local player = Players.LocalPlayer
local character = player.Character
local humanoid = character and character:FindFirstChildOfClass("Humanoid")
local rootPart = character and character:FindFirstChild("HumanoidRootPart")

if not rootPart or not humanoid then
	warn("[Entry] no character - respawn and run again")
	return
end

if humanoid.SeatPart then
	warn(("[Entry] you are ALREADY SEATED in %s. That alone blocks entry."):format(humanoid.SeatPart:GetFullName()))
end

for _, carModel in workspace.Vehicles:GetChildren() do
	if not carModel:IsA("Model") then
		continue
	end

	print(("=== %s ==="):format(carModel.Name))

	local seat = VehicleSeats.GetDriverSeat(carModel)
	local doors = VehicleDoorRig.GetDoors(carModel)

	if not seat then
		print("  FAIL  no DriverSeat - no prompt is ever built")
		continue
	end
	if not (doors and doors.Left and doors.Right) then
		print("  FAIL  door rig incomplete (need Frame.InteriorFrame.<Side>DoorAttachment.HingeConstraint on BOTH sides)")
		continue
	end

	print(("  seat.Occupant     : %s"):format(tostring(seat.Occupant)))
	print(("  CanEnter          : %s"):format(tostring(VehicleOwnership.CanEnter(player, carModel))))
	print(("  seat.Disabled     : %s  (expected true - scripted seating only)"):format(tostring(seat.Disabled)))

	local nearest = math.huge
	for side, door in doors do
		local distance = (door.FrameAttachment.WorldPosition - rootPart.Position).Magnitude
		nearest = math.min(nearest, distance)
		print(("  %-5s door        : %.1f studs away"):format(side, distance))
	end

	if nearest > MAX_PROMPT_DISTANCE then
		print(("  FAIL  nearest door is %.1f studs, prompt needs <= %d."):format(nearest, MAX_PROMPT_DISTANCE))
		print("        Walk right up to the door and run this again. If you CANNOT get closer,")
		print("        a collision hull is holding you off the truck - shrink Hull_Left/Hull_Right,")
		print("        or move the DoorAttachment outward toward the skin.")
	elseif nearest > MAX_ENTER_DISTANCE then
		print(("  FAIL  server would reject: %.1f studs, needs <= %d"):format(nearest, MAX_ENTER_DISTANCE))
	else
		print(("  OK    in range (%.1f studs) - prompt should be visible and F should work"):format(nearest))
	end
end

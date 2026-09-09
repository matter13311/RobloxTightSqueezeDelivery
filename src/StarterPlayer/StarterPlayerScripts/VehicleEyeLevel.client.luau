-- Attaches and detaches the pinned driving eye (VehicleEyePoint.luau, which
-- has the whole rationale in its header) around getting into and out of a car.
--
-- Deliberately its own script rather than part of the driving session in
-- RayCastSuspension.client.luau: a PASSENGER needs to see out of the
-- windshield exactly as much as the driver does, and never starts a driving
-- session. Sitting down is the trigger, not taking the wheel.
--
-- Only seats belonging to a car count. A player sitting on a bench somewhere
-- in the world keeps Roblox's ordinary head camera - there is no cab to see
-- out of, so there is nothing to pin the eye to.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local VehicleEyePoint = require(script.Parent.VehicleEyePoint)

local player = Players.LocalPlayer
local VehicleFolder = workspace:WaitForChild("Vehicles")

-- Torn down alongside the eye, so a seat that is destroyed under a seated
-- player (its car despawning from the plot) can't leave a stale connection
-- behind for the next one.
local seatAncestryConnection = nil

local function detach()
	if seatAncestryConnection then
		seatAncestryConnection:Disconnect()
		seatAncestryConnection = nil
	end
	VehicleEyePoint.Detach()
end

local function isVehicleSeat(seatPart)
	local carModel = seatPart.Parent
	if not carModel or carModel.Parent ~= VehicleFolder then
		return false
	end
	for _, seat in VehicleSeats.GetAllSeats(carModel) do
		if seat == seatPart then
			return true
		end
	end
	return false
end

local function onSeated(isSeated, seatPart)
	detach()
	if not isSeated or not seatPart or not isVehicleSeat(seatPart) then
		return
	end

	VehicleEyePoint.Attach(seatPart)

	-- The eye is measured off the SEAT every frame, so a seat that leaves the
	-- world leaves the correction reading a stale CFrame and the player stuck
	-- with whatever camera offset was last applied. Watched rather than polled:
	-- this is the only way the attachment can go bad while somebody is still
	-- sitting in it, and it is rare enough (a car despawned out from under its
	-- occupant) that a per-frame check would be paying for nothing.
	seatAncestryConnection = seatPart.AncestryChanged:Connect(function()
		if not seatPart:IsDescendantOf(workspace) then
			detach()
		end
	end)
end

local function bindCharacter(character)
	local humanoid = character:WaitForChild("Humanoid")
	humanoid.Seated:Connect(onSeated)
	-- Dying in a seat does not always come with a Seated(false), and the
	-- respawn that follows needs the camera back on the new character's
	-- Humanoid rather than on a part welded to a car the old body was in.
	humanoid.Died:Connect(detach)

	-- Already sitting when this runs - a respawn straight into a seat, or a
	-- Studio hot-reload mid-drive.
	if humanoid.SeatPart then
		onSeated(true, humanoid.SeatPart)
	end
end

if player.Character then
	bindCharacter(player.Character)
end
player.CharacterAdded:Connect(function(character)
	-- The old character's eye part is welded to a car and would otherwise
	-- outlive the body it belonged to.
	detach()
	bindCharacter(character)
end)

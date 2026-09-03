-- Shared door discovery. Both the server (VehicleDoors.server.luau, which
-- owns opening/closing) and the client (VehicleDoorPrompts.client.luau,
-- which only needs door positions to know when to show its "Enter" prompt)
-- need to find the same Left/Right hinge + door part pair, so the lookup
-- lives here once rather than being duplicated on both sides.
--
-- Expects each car to have, per side:
--   Frame.InteriorFrame.<Side>DoorAttachment.HingeConstraint  (chassis side)
--   Doors.<Side>Door                                          (the door itself)
-- with the HingeConstraint's other Attachment parented somewhere under the door.

local VehicleDoorRig = {}

VehicleDoorRig.Sides = { "Left", "Right" }

-- The HingeConstraint is parented under the chassis-side Attachment, but
-- Attachment0/1 could be assigned either way round depending on which
-- Attachment was clicked first when it was created in Studio - so find the
-- door side by elimination rather than assuming a slot.
local function getDoorPart(hinge, frameAttachment)
	local other
	if hinge.Attachment0 == frameAttachment then
		other = hinge.Attachment1
	elseif hinge.Attachment1 == frameAttachment then
		other = hinge.Attachment0
	end
	return other and other.Parent
end

-- Returns { Left = { Hinge, Part, FrameAttachment, Model }, Right = {...} },
-- or nil if this car isn't (yet) fully set up for doors.
function VehicleDoorRig.GetDoors(carModel)
	local interiorFrame = carModel:FindFirstChild("Frame") and carModel.Frame:FindFirstChild("InteriorFrame")
	local doorsFolder = carModel:FindFirstChild("Doors")
	if not interiorFrame then
		return nil
	end

	local doors = {}
	for _, side in VehicleDoorRig.Sides do
		local frameAttachment = interiorFrame:FindFirstChild(side .. "DoorAttachment")
		local hinge = frameAttachment and frameAttachment:FindFirstChildOfClass("HingeConstraint")
		local doorPart = hinge and getDoorPart(hinge, frameAttachment)
		local doorModel = doorsFolder and doorsFolder:FindFirstChild(side .. "Door")
		if hinge and doorPart then
			doors[side] = { Hinge = hinge, Part = doorPart, FrameAttachment = frameAttachment, Model = doorModel or doorPart }
		end
	end
	return doors
end

return VehicleDoorRig

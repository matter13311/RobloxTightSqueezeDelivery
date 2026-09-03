-- Optional door-mounted mirrors. A car that has a Mirror folder with
-- Left/RightMirror parts gets those welded to the matching door part so they
-- swing with the door - not every vehicle has mirrors on the doors (some may
-- have them on the chassis, or none at all yet), so this is a no-op when the
-- Mirror folder or a given side's mirror part isn't present.
--
-- Must be called AFTER VehicleDoors has stripped external joints from the
-- door (see removeExternalJoints in VehicleDoors.server.luau) - otherwise the
-- WeldConstraint created here, which leads from inside the door model to a
-- part outside it (the mirror), would get destroyed the same way a Studio
-- auto-weld between the door and chassis does.

local VehicleMirrors = {}

-- doors is the table returned by VehicleDoorRig.GetDoors: { Left = { Part =
-- ..., ... }, Right = {...} }.
function VehicleMirrors.AttachToDoors(carModel, doors)
	local mirrorFolder = carModel:FindFirstChild("Mirror")
	if not mirrorFolder then
		return
	end

	for side, door in doors do
		local mirrorPart = mirrorFolder:FindFirstChild(side .. "Mirror")
		if mirrorPart and mirrorPart:IsA("BasePart") then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = door.Part
			weld.Part1 = mirrorPart
			weld.Parent = mirrorPart
		end
	end
end

return VehicleMirrors

-- Shared raycast suspension physics for all vehicles. Used by both the
-- server (simulates parked cars, holding them at ride height when nobody's
-- driving) and the driving player's own client (simulates the one car they
-- currently have network ownership of). This is the single source of truth
-- for the suspension/grip/drive math - previously the server and client
-- each had their own hand-copied version of this loop, which is exactly the
-- kind of thing that quietly drifts out of sync (see WheelSuspensionLengthMemory).

local VehiclePhysics = {}

local WHEEL_NAMES = { "FL", "FR", "RL", "RR" }
VehiclePhysics.WheelNames = WHEEL_NAMES

-- Per-car tuning. A car only needs to set the attributes it wants to differ
-- from these - anything unset falls back to the default here. This is how
-- you make a "drift car" (low LateralGripStrength, high Torque) vs a
-- "speed car" (high MaxSpeed/Torque, high LateralGripStrength) etc, entirely
-- from the Properties > Attributes panel on a car's Chassis, no scripting.
local DEFAULTS = {
	SuspensionMaxLength = 1.3,
	WheelRadius = 1.5,
	Stiffness = 100,
	Damper = 5,
	LateralGripStrength = 1, -- 0-1, 1 = never slides sideways
	Torque = 10,
	MaxSpeed = 50,
	SteerAngle = 30,
	BrakeStrength = 10, -- how hard it brakes once nearly stopped
	CoastDrag = 0.5, -- light drag while coasting above CoastSpeedThreshold
	CoastSpeedThreshold = 3, -- studs/s
}
VehiclePhysics.Defaults = DEFAULTS

function VehiclePhysics.GetConfig(chassis)
	local config = {}
	for key, default in DEFAULTS do
		local value = chassis:GetAttribute(key)
		config[key] = if value ~= nil then value else default
	end
	return config
end

-- Each wheel's mount point is an Attachment named "Wheel" .. name (e.g.
-- "WheelFL"), parented directly to the Chassis and positioned visually in
-- Studio - its Position IS the wheel/raycast offset, nothing to type by hand.
function VehiclePhysics.GetWheelAttachments(chassis)
	local attachments = {}
	for _, name in WHEEL_NAMES do
		local attachment = chassis:FindFirstChild("Wheel" .. name)
		assert(attachment ~= nil, "Chassis " .. chassis:GetFullName() .. " is missing a 'Wheel" .. name .. "' Attachment")
		attachments[name] = attachment
	end
	return attachments
end

-- One of these per car (server, for a parked car) or per drive session
-- (client, while a player is seated). Holds the previous frame's suspension
-- length per wheel, which the damper needs, plus the smoothed steer value.
function VehiclePhysics.NewState()
	local state = { SpringLengthMemory = {}, SmoothSteer = 0 }
	for _, name in WHEEL_NAMES do
		state.SpringLengthMemory[name] = 0.5
	end
	return state
end

-- Runs one physics step for one car.
-- `input` is { Throttle = seat.ThrottleFloat, Steer = seat.SteerFloat } while
-- a player is actively driving. Pass input = nil for a parked/server-owned
-- car - no throttle, no steering, and it always fully brakes to a stop
-- (never coasts) since nobody's there to have let off the gas.
function VehiclePhysics.Step(carModel, attachments, config, state, delta, input)
	local carPrim = carModel.PrimaryPart

	if input then
		local target = input.Steer or 0
		state.SmoothSteer = math.abs(target - state.SmoothSteer) <= delta * 5
			and target
			or state.SmoothSteer + math.sign(target - state.SmoothSteer) * delta * 5
	else
		state.SmoothSteer = 0
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { carModel }

	for _, wheelName in WHEEL_NAMES do
		local attachment = attachments[wheelName]
		local carCFrame = carPrim.CFrame
		local rayOrigin = attachment.WorldPosition
		local rayDirection = -carCFrame.UpVector * (config.SuspensionMaxLength + config.WheelRadius)
		local raycast = workspace:Raycast(rayOrigin, rayDirection, rayParams)

		if raycast then
			local raycastDistance = (rayOrigin - raycast.Position).Magnitude
			local springLength = math.clamp(raycastDistance - config.WheelRadius, 0, config.SuspensionMaxLength)
			local stiffnessForce = config.Stiffness * (config.SuspensionMaxLength - springLength)
			local damperForce = config.Damper * ((state.SpringLengthMemory[wheelName] - springLength) / delta)
			local suspensionForce = carCFrame.UpVector * (stiffnessForce + damperForce)

			local wheelDirCFrame = CFrame.lookAt(Vector3.zero, carCFrame.LookVector, carCFrame.UpVector)
			if wheelName:sub(1, 1) == "F" then
				wheelDirCFrame = wheelDirCFrame * CFrame.Angles(0, math.rad(-state.SmoothSteer * config.SteerAngle), 0)
			end
			local localVelocity = wheelDirCFrame:ToObjectSpace(CFrame.new(carPrim:GetVelocityAtPosition(raycast.Position)))

			-- Mass-scaled (a true impulse) so this only ever cancels sideways
			-- velocity exactly - never overshoots past zero. Divided across the
			-- 4 wheels since each one reads roughly the same velocity and would
			-- otherwise each try to cancel the WHOLE car's sideways speed on its
			-- own, applying up to 4x the needed correction.
			local lateralForce = wheelDirCFrame.RightVector * -localVelocity.X * (carPrim.AssemblyMass / 4) * config.LateralGripStrength

			local longitudinalForce
			if input and input.Throttle and input.Throttle ~= 0 then
				longitudinalForce = wheelDirCFrame.LookVector * input.Throttle * config.Torque * (1 - math.min(1, math.abs(localVelocity.Z) / config.MaxSpeed))
			elseif input and math.abs(localVelocity.Z) > config.CoastSpeedThreshold then
				-- Still going fast enough to be "coasting" - light drag only, so
				-- momentum carries through instead of slamming to a stop.
				longitudinalForce = wheelDirCFrame.LookVector * localVelocity.Z * config.CoastDrag
			else
				-- No driver (always brake), or slow enough that continuing to
				-- creep would just look stuck rolling - fully brake to a stop.
				longitudinalForce = wheelDirCFrame.LookVector * localVelocity.Z * config.BrakeStrength
			end

			state.SpringLengthMemory[wheelName] = springLength
			carPrim:ApplyImpulseAtPosition(suspensionForce + lateralForce + longitudinalForce, rayOrigin)
		else
			state.SpringLengthMemory[wheelName] = config.SuspensionMaxLength
		end
	end

	local sound = carPrim:FindFirstChild("Sound")
	if sound then
		sound.PlaybackSpeed = 0.8 + carPrim.AssemblyLinearVelocity.Magnitude / config.MaxSpeed
	end
end

-- Purely cosmetic: positions/rotates a car's wheel meshes to follow the
-- ground and spin/steer, independent of the physics raycast above. Called
-- from the client for every vehicle it can see (not just the one driven),
-- since every viewer computes this locally from replicated position data.
function VehiclePhysics.UpdateWheelVisuals(vehicle, attachments, config, smoothSteer, rotationState)
	local carPrim = vehicle.PrimaryPart
	local carCFrame = carPrim.CFrame
	local wheelsFolder = vehicle:FindFirstChild("Wheels")
	if not wheelsFolder then
		return
	end

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { vehicle }

	for _, wheelName in WHEEL_NAMES do
		local attachment = attachments[wheelName]
		local wheelPart = wheelsFolder:FindFirstChild(wheelName)
		if attachment and wheelPart then
			local localOffset = attachment.Position
			local rayOrigin = attachment.WorldPosition
			local rayDirection = -carCFrame.UpVector * (config.SuspensionMaxLength + config.WheelRadius)
			local raycast = workspace:Raycast(rayOrigin, rayDirection, rayParams)

			if raycast then
				local weld = wheelPart:FindFirstChild("Weld")
				if weld then
					-- Place the wheel's CENTER (its pivot) WheelRadius above the actual
					-- ground contact point, not AT it - otherwise the wheel mesh's own
					-- radius sinks its bottom half straight into the ground, since a
					-- mesh extends both above and below its pivot by its own radius.
					local raycastDistance = (rayOrigin - raycast.Position).Magnitude
					local springLength = math.clamp(raycastDistance - config.WheelRadius, 0, config.SuspensionMaxLength)
					weld.C0 = CFrame.new(localOffset - Vector3.new(0, springLength, 0))
					if localOffset.X > 0 then
						weld.C0 = weld.C0 * CFrame.Angles(0, math.rad(180), 0)
					end
					if wheelName:sub(1, 1) == "F" then
						weld.C0 = weld.C0 * CFrame.Angles(0, -math.rad(smoothSteer * config.SteerAngle), 0)
					end

					local localVelocity = CFrame.lookAt(Vector3.zero, carCFrame.LookVector, carCFrame.UpVector)
						:ToObjectSpace(CFrame.new(carPrim:GetVelocityAtPosition(raycast.Position)))

					rotationState[wheelName] = (rotationState[wheelName] or 0.5) + localVelocity.Z / 56 --56 should be same as math.rad(number)
					weld.C0 = weld.C0 * CFrame.Angles(rotationState[wheelName], 0, 0)
				end
			end
		end
	end
end

return VehiclePhysics

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

-- Base defaults every car falls back to if nothing else overrides a value.
local DEFAULTS = {
	SuspensionMaxLength = 1.3,
	WheelRadius = 1.5,
	Stiffness = 100,
	Damper = 5,
	LateralGripStrength = 1, -- friction coefficient (like a real tire, roughly 0.7-1.5 is a normal grippy range) - the max sideways g-force this wheel's grip can generate. Applies to whichever axle doesn't have its own Front/RearLateralGripStrength override
	DriveWheels = "All", -- "All", "Front", or "Rear" - which axle receives drive/brake force from the throttle
	WheelSpinBoost = 0, -- 0 = off. Extra visual wheel-spin speed under throttle at low speed, for a burnout/wheelspin look on drive wheels
	Torque = 10,
	MaxSpeed = 50,
	SteerAngle = 30,
	BrakeStrength = 1, -- 0-1: fraction of a full stop applied per frame once braking. 1 = stops dead instantly, lower = a more gradual stop
	CoastDrag = 0.5, -- light drag while coasting above CoastSpeedThreshold
	CoastSpeedThreshold = 3, -- studs/s
}
VehiclePhysics.Defaults = DEFAULTS

-- Per-car-TYPE tuning lives in ModuleScripts under Configs/, one file per car
-- type (e.g. Configs/DriftCar.luau), each returning a table of only the
-- values that differ from DEFAULTS. A car picks up its config automatically
-- by matching its Model's Name to a file of the same name - so a car named
-- "DriftCar" in workspace.Vehicles automatically uses Configs/DriftCar.luau,
-- no attribute-setting required. Set a "ConfigName" attribute on the Chassis
-- to use a different config file than the model's own name (e.g. several
-- car instances sharing one "MonsterTruckCar" config).
local configsFolder = script.Parent:FindFirstChild("Configs")

local configCache = {} -- [configName] = table or false (false = looked up, none found)

local function loadNamedConfig(name)
	if configCache[name] ~= nil then
		return configCache[name] or nil
	end

	local module = configsFolder and configsFolder:FindFirstChild(name)
	local result = nil
	if module and module:IsA("ModuleScript") then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" then
			result = loaded
		else
			warn("VehiclePhysics: Configs/" .. name .. " didn't return a table (" .. tostring(loaded) .. ")")
		end
	end

	configCache[name] = result or false
	return result
end

-- Optional - no default, since these should normally just fall back to
-- LateralGripStrength. Set either to give the front and rear axles
-- different grip - e.g. a drift car wants the front to hold on for
-- steering control while the rear breaks loose (RearLateralGripStrength
-- much lower than FrontLateralGripStrength).
local OPTIONAL_KEYS = { "FrontLateralGripStrength", "RearLateralGripStrength" }

-- Precedence, highest first: an Attribute set directly on this Chassis
-- instance > the car-type's Configs/<name>.luau file > DEFAULTS. This lets
-- you define a car type once in a file, and still nudge one specific
-- instance of it via Attributes without touching the shared file.
function VehiclePhysics.GetConfig(chassis)
	local carModel = chassis.Parent
	local configName = chassis:GetAttribute("ConfigName") or (carModel and carModel.Name)
	local fileConfig = configName and loadNamedConfig(configName)

	local config = {}
	for key, default in DEFAULTS do
		local value = default
		if fileConfig and fileConfig[key] ~= nil then
			value = fileConfig[key]
		end
		local attributeValue = chassis:GetAttribute(key)
		if attributeValue ~= nil then
			value = attributeValue
		end
		config[key] = value
	end
	for _, key in OPTIONAL_KEYS do
		local value = nil
		if fileConfig and fileConfig[key] ~= nil then
			value = fileConfig[key]
		end
		local attributeValue = chassis:GetAttribute(key)
		if attributeValue ~= nil then
			value = attributeValue
		end
		config[key] = value
	end
	return config
end

-- A wheel can be a single Part (like UAZWheel) or a multi-part Model (rim,
-- tire, hubcap, etc. welded together internally with WeldConstraints, with
-- Model.PrimaryPart set to whichever part is the external attachment point).
-- Everywhere else in this module treats "the wheel" as this one part - the
-- only external connection to the chassis - so a multi-part wheel needs no
-- special-casing anywhere but here.
function VehiclePhysics.GetWheelPrimaryPart(wheelInstance)
	if wheelInstance:IsA("Model") then
		assert(wheelInstance.PrimaryPart ~= nil, "Wheel model " .. wheelInstance:GetFullName() .. " needs a PrimaryPart set")
		return wheelInstance.PrimaryPart
	end
	return wheelInstance
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

			local isFrontWheel = wheelName:sub(1, 1) == "F"

			local wheelDirCFrame = CFrame.lookAt(Vector3.zero, carCFrame.LookVector, carCFrame.UpVector)
			if isFrontWheel then
				wheelDirCFrame = wheelDirCFrame * CFrame.Angles(0, math.rad(-state.SmoothSteer * config.SteerAngle), 0)
			end
			local localVelocity = wheelDirCFrame:ToObjectSpace(CFrame.new(carPrim:GetVelocityAtPosition(raycast.Position)))

			-- LateralGripStrength is a friction coefficient, like a real tire's:
			-- the max sideways force this wheel can generate is coefficient *
			-- its share of the car's weight. Below that limit, sideways slip is
			-- fully cancelled (full grip, mass-scaled so it can't overshoot).
			-- Above it, the tire can only partially resist - it breaks traction
			-- and the car actually slides, instead of snapping straight back
			-- within a fraction of a second regardless of how low the
			-- coefficient is (which is what a flat "cancel X% of velocity every
			-- frame" model does - even a "weak" 10%/frame at 60fps converges
			-- back to zero in a fraction of a second, never a real slide).
			local axleGrip = if isFrontWheel
				then (config.FrontLateralGripStrength or config.LateralGripStrength)
				else (config.RearLateralGripStrength or config.LateralGripStrength)
			local wheelWeight = (carPrim.AssemblyMass / 4) * workspace.Gravity
			local maxLateralImpulse = axleGrip * wheelWeight * delta
			local neededLateralImpulse = -localVelocity.X * (carPrim.AssemblyMass / 4)
			local lateralImpulseMagnitude = math.clamp(neededLateralImpulse, -maxLateralImpulse, maxLateralImpulse)
			local lateralForce = wheelDirCFrame.RightVector * lateralImpulseMagnitude

			-- Only wheels on the driven axle (DriveWheels: "All"/"Front"/"Rear")
			-- push the car forward - the other axle just rolls (falls through to
			-- coast/brake below), same as a real FWD/RWD car.
			local isDriveWheel = config.DriveWheels == "All"
				or (config.DriveWheels == "Front" and isFrontWheel)
				or (config.DriveWheels == "Rear" and not isFrontWheel)

			local longitudinalForce
			if input and input.Throttle and input.Throttle ~= 0 and isDriveWheel then
				longitudinalForce = wheelDirCFrame.LookVector * input.Throttle * config.Torque * (1 - math.min(1, math.abs(localVelocity.Z) / config.MaxSpeed))
			elseif input and math.abs(localVelocity.Z) > config.CoastSpeedThreshold then
				-- Still going fast enough to be "coasting" - light drag only, so
				-- momentum carries through instead of slamming to a stop.
				longitudinalForce = wheelDirCFrame.LookVector * localVelocity.Z * config.CoastDrag
			else
				-- No driver (always brake), or slow enough that continuing to
				-- creep would just look stuck rolling - fully brake to a stop.
				-- Mass-scaled and clamped to the exact impulse a full stop
				-- needs (BrakeStrength is 0-1, the fraction of that applied
				-- per frame) - same fix as lateral grip: an unscaled raw
				-- coefficient here only cancels BrakeStrength/mass of the
				-- velocity each frame, which for a real car's mass is a weak
				-- handful of percent - nowhere near enough to hold still
				-- against a slope or any other small continuous push, so a
				-- "parked, always braking" car would still slowly creep.
				local neededLongitudinalImpulse = localVelocity.Z * (carPrim.AssemblyMass / 4)
				local longitudinalImpulseMagnitude = math.clamp(
					neededLongitudinalImpulse * config.BrakeStrength,
					-math.abs(neededLongitudinalImpulse),
					math.abs(neededLongitudinalImpulse)
				)
				longitudinalForce = wheelDirCFrame.LookVector * longitudinalImpulseMagnitude
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
function VehiclePhysics.UpdateWheelVisuals(vehicle, attachments, config, smoothSteer, rotationState, throttle)
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
				local weld = VehiclePhysics.GetWheelPrimaryPart(wheelPart):FindFirstChild("Weld")
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

					local wheelSurfaceSpeed = localVelocity.Z
					if throttle and throttle ~= 0 and config.WheelSpinBoost ~= 0 then
						local isFrontWheel = wheelName:sub(1, 1) == "F"
						local isDriveWheel = config.DriveWheels == "All"
							or (config.DriveWheels == "Front" and isFrontWheel)
							or (config.DriveWheels == "Rear" and not isFrontWheel)
						if isDriveWheel then
							-- Wheelspin: under throttle, the tire's surface can move
							-- faster than the car actually is - it's spinning "in
							-- place" rather than purely rolling with the ground. Fades
							-- out as the car catches up to MaxSpeed, so it reads as a
							-- burnout/wheelspin rather than the wheel spinning forever.
							local slipRoom = math.max(0, 1 - math.abs(localVelocity.Z) / config.MaxSpeed)
							wheelSurfaceSpeed += throttle * config.WheelSpinBoost * slipRoom
						end
					end

					rotationState[wheelName] = (rotationState[wheelName] or 0.5) + wheelSurfaceSpeed / 56 --56 should be same as math.rad(number)

					-- Right-side wheels are mirrored outward-facing via the 180deg Y
					-- flip above. Spinning around a mirrored local X axis is the
					-- visual opposite of spinning around the unmirrored one - so
					-- without this, the right side rolls backwards relative to the
					-- left even though both are being told to roll the same amount.
					-- (This bug existed for the old single-part wheel too - it just
					-- didn't show, since a plain symmetric cylinder looks identical
					-- spinning either direction.)
					local spinSign = if localOffset.X > 0 then -1 else 1
					weld.C0 = weld.C0 * CFrame.Angles(spinSign * rotationState[wheelName], 0, 0)
				end
			end
		end
	end
end

return VehiclePhysics

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local player = Players.LocalPlayer

-- Per-vehicle state for the wheel VISUALS only (every client tracks this for
-- every car it can see, not just the one it's driving - see UpdateWheelVisuals).
local wheelAttachmentsCache = {} -- [vehicle] = attachments
local wheelRotationState = {} -- [vehicle] = { FL = angle, ... }
local drivingStates = {} -- [vehicle] = physics State, only set while THIS client is driving it

-- Returns nil (instead of erroring) if this car hasn't finished loading yet -
-- e.g. PrimaryPart or a WheelXX attachment not set up yet during the first
-- few frames after it's added to workspace.Vehicles. Callers should just
-- skip the vehicle for this frame and it'll pick up again once it's ready.
local function getWheelAttachments(vehicle)
	local cached = wheelAttachmentsCache[vehicle]
	if cached then
		return cached
	end

	local chassis = vehicle.PrimaryPart
	if not chassis then
		return nil
	end

	local ok, attachments = pcall(VehiclePhysics.GetWheelAttachments, chassis)
	if not ok then
		return nil
	end

	wheelAttachmentsCache[vehicle] = attachments
	return attachments
end

local function onCharacterAdded(character)
	local humanoid = character:WaitForChild("Humanoid")

	humanoid.Seated:Connect(function(seated, seatPart)
		if not (seated and seatPart) then
			return
		end
		if not (seatPart:FindFirstAncestor("Vehicles") and seatPart:IsA("VehicleSeat")) then
			return
		end

		local carModel = seatPart.Parent
		local chassis = carModel.PrimaryPart
		local attachments = getWheelAttachments(carModel)
		if not attachments then
			warn("RayCastSuspension: " .. carModel:GetFullName() .. " isn't fully set up (missing PrimaryPart or a WheelXX attachment) - can't drive it")
			return
		end
		local config = VehiclePhysics.GetConfig(chassis)
		local state = VehiclePhysics.NewState()
		drivingStates[carModel] = state

		-- No grace period needed here anymore - that was to give the server
		-- time to safely reclaim network ownership before resuming its own
		-- force application, a race that no longer exists now that a parked
		-- car is just Anchored (a plain replicated property, not something
		-- subject to network-ownership timing) instead of server-simulated.
		while seatPart.Occupant == humanoid do
			local delta = RunService.Heartbeat:Wait()

			VehiclePhysics.Step(carModel, attachments, config, state, delta, {
				Throttle = seatPart.ThrottleFloat,
				Steer = seatPart.SteerFloat,
			})
		end

		if drivingStates[carModel] == state then
			drivingStates[carModel] = nil
		end
	end)

	game.ContextActionService:BindAction("lightButton", function(_, inputState)
		if humanoid.SeatPart and inputState == Enum.UserInputState.Begin then
			-- game.ReplicatedStorage.SwitchLight:FireServer()
		end
	end, false, Enum.KeyCode.L)

	RunService:BindToRenderStep("MoveWheels", 5, function()
		for _, vehicle in workspace.Vehicles:GetChildren() do
			local attachments = getWheelAttachments(vehicle)
			local chassis = attachments and vehicle.PrimaryPart
			-- Parked cars are Anchored and don't need their wheels touched at
			-- all - skip them outright rather than relying on velocity happening
			-- to read exactly zero every frame, which is a guarantee, not a hope.
			if attachments and not chassis.Anchored then
				local config = VehiclePhysics.GetConfig(chassis)

				wheelRotationState[vehicle] = wheelRotationState[vehicle] or {}

				-- Only the car THIS client is currently driving has a real smoothed
				-- steer value (from the physics loop above) - other cars' front
				-- wheels stay centered visually, since we don't get their driver's
				-- steer input replicated to us. Same story for throttle (used for
				-- the wheelspin visual): only known for the car we're driving.
				local drivingState = drivingStates[vehicle]
				local smoothSteer = drivingState and drivingState.SmoothSteer or 0
				local throttle = 0
				if drivingState then
					local seat = vehicle:FindFirstChildWhichIsA("VehicleSeat")
					throttle = seat and seat.ThrottleFloat or 0
				end

				VehiclePhysics.UpdateWheelVisuals(vehicle, attachments, config, smoothSteer, wheelRotationState[vehicle], throttle)
			end
		end
	end)
end

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

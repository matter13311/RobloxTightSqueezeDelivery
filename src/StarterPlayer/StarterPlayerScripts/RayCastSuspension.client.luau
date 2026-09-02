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

local function getWheelAttachments(vehicle)
	local cached = wheelAttachmentsCache[vehicle]
	if not cached then
		cached = VehiclePhysics.GetWheelAttachments(vehicle.PrimaryPart)
		wheelAttachmentsCache[vehicle] = cached
	end
	return cached
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
		local config = VehiclePhysics.GetConfig(chassis)
		local state = VehiclePhysics.NewState()
		drivingStates[carModel] = state

		local serverTakeOverWait = 0
		while true do
			local delta = RunService.Heartbeat:Wait()

			VehiclePhysics.Step(carModel, attachments, config, state, delta, {
				Throttle = seatPart.ThrottleFloat,
				Steer = seatPart.SteerFloat,
			})

			if seatPart.Occupant ~= humanoid then
				serverTakeOverWait += delta
				if serverTakeOverWait >= 1 then
					break
				end
			else
				serverTakeOverWait = 0
			end
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
			local chassis = vehicle.PrimaryPart
			local attachments = getWheelAttachments(vehicle)
			local config = VehiclePhysics.GetConfig(chassis)

			wheelRotationState[vehicle] = wheelRotationState[vehicle] or {}

			-- Only the car THIS client is currently driving has a real smoothed
			-- steer value (from the physics loop above) - other cars' front
			-- wheels stay centered visually, since we don't get their driver's
			-- steer input replicated to us.
			local drivingState = drivingStates[vehicle]
			local smoothSteer = drivingState and drivingState.SmoothSteer or 0

			VehiclePhysics.UpdateWheelVisuals(vehicle, attachments, config, smoothSteer, wheelRotationState[vehicle])
		end
	end)
end

if player.Character then
	onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

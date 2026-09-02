local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local defaultWheelModel = ReplicatedStorage.UAZWheel
local VehicleFolder = workspace.Vehicles

local ExistingCars = {} -- [carModel] = { Attachments = ..., State = ... }

local function AddCar(carModel)
	local chassis = carModel.PrimaryPart
	local attachments = VehiclePhysics.GetWheelAttachments(chassis)

	ExistingCars[carModel] = {
		Attachments = attachments,
		State = VehiclePhysics.NewState(),
	}

	chassis:SetNetworkOwner(nil) -- server controls physics for parked cars

	carModel.VehicleSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = carModel.VehicleSeat.Occupant
		if occupant then
			local player = Players:GetPlayerFromCharacter(occupant.Parent)
			if player then
				chassis:SetNetworkOwner(player)
			end
		else
			chassis:SetNetworkOwner(nil)
		end
	end)

	-- wheels (purely cosmetic - a car can override its wheel mesh with a
	-- "WheelModelName" attribute naming a different model in ReplicatedStorage)
	local wheelModelName = chassis:GetAttribute("WheelModelName")
	local wheelModel = (wheelModelName and ReplicatedStorage:FindFirstChild(wheelModelName)) or defaultWheelModel

	local wheelFolder = Instance.new("Folder", carModel)
	wheelFolder.Name = "Wheels"
	for _, wheelName in VehiclePhysics.WheelNames do
		local attachment = attachments[wheelName]
		local clonedWheel = wheelModel:Clone()
		clonedWheel.Parent = wheelFolder
		clonedWheel.Name = wheelName
		clonedWheel.CanCollide = false
		local weld = Instance.new("Weld", clonedWheel)
		weld.Part0 = chassis
		weld.Part1 = clonedWheel
		weld.C0 = CFrame.new(attachment.Position)

		if attachment.Position.X > 0 then
			weld.C0 = weld.C0 * CFrame.Angles(0, math.rad(180), 0)
		end
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	AddCar(carModel)
end
VehicleFolder.ChildAdded:Connect(AddCar)

while true do
	local delta = RunService.Heartbeat:Wait()
	for carModel, car in ExistingCars do
		local chassis = carModel.PrimaryPart

		-- Only simulate suspension while the server actually owns this car's
		-- physics. SetNetworkOwner(nil) is a request that has to replicate,
		-- not an instant switch - right after a player exits, the server can
		-- briefly still be working from stale/inconsistent state before
		-- ownership has genuinely settled back to it. Applying a corrective
		-- impulse against that stale state is what launches the car in a
		-- random direction at exit; skipping until ownership is confirmed
		-- avoids fighting over data nobody agrees on yet.
		if chassis:GetNetworkOwner() == nil then
			local config = VehiclePhysics.GetConfig(chassis)
			VehiclePhysics.Step(carModel, car.Attachments, config, car.State, delta, nil)
		end
	end
end

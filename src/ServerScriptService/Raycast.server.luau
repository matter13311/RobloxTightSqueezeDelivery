local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local defaultWheelModel = ReplicatedStorage.UAZWheelDetailed
local VehicleFolder = workspace.Vehicles

local ExistingCars = {} -- [carModel] = { Attachments = ..., State = ... }

local function AddCar(carModel)
	local chassis = carModel.PrimaryPart
	if not chassis then
		warn("VehicleManager: " .. carModel:GetFullName() .. " has no PrimaryPart set - skipping this car")
		return
	end
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

		-- Works for both a single Part wheel and a multi-part Model wheel
		-- (rim/tire/hubcap etc, rigidly welded together internally with the
		-- model's PrimaryPart as the one part we connect to the chassis).
		local parts = clonedWheel:IsA("Model") and clonedWheel:GetDescendants() or { clonedWheel }
		for _, part in parts do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.Anchored = false
			end
		end

		local wheelPrimary = VehiclePhysics.GetWheelPrimaryPart(clonedWheel)
		local weld = Instance.new("Weld", wheelPrimary)
		weld.Part0 = chassis
		weld.Part1 = wheelPrimary
		weld.C0 = CFrame.new(attachment.Position)

		if attachment.Position.X > 0 then
			weld.C0 = weld.C0 * CFrame.Angles(0, math.rad(180), 0)
		end
	end
end

local function TryAddCar(carModel)
	-- One misconfigured car (missing PrimaryPart, missing a WheelXX
	-- attachment, etc) shouldn't be able to take down every other car's
	-- suspension by erroring out of this script entirely.
	local ok, err = pcall(AddCar, carModel)
	if not ok then
		warn("VehicleManager: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	TryAddCar(carModel)
end
VehicleFolder.ChildAdded:Connect(TryAddCar)

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

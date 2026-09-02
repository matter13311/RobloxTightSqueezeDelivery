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

	local car = {
		Attachments = attachments,
		State = VehiclePhysics.NewState(),
		Occupied = false,
		-- os.clock() timestamp the server is allowed to resume simulating
		-- this car after someone gets out (see the Occupant handler below).
		ResumeAfter = 0,
	}
	ExistingCars[carModel] = car

	chassis:SetNetworkOwner(nil) -- server controls physics for parked cars

	carModel.VehicleSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = carModel.VehicleSeat.Occupant
		if occupant then
			car.Occupied = true
			local player = Players:GetPlayerFromCharacter(occupant.Parent)
			if player then
				chassis:SetNetworkOwner(player)
			end
		else
			car.Occupied = false
			-- Give network ownership a moment to actually settle back to the
			-- server before we resume applying forces - SetNetworkOwner(nil)
			-- is a request that has to replicate, not an instant switch, and
			-- acting on stale state during that window is what launches the
			-- car in a random direction right after someone gets out. This
			-- matches the client's own ~1s grace period on the way out.
			car.ResumeAfter = os.clock() + 1
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
	local now = os.clock()
	for carModel, car in ExistingCars do
		-- Gate on whether anyone's actually seated (which we control directly
		-- and know is accurate), not on chassis:GetNetworkOwner() - that can
		-- intermittently report non-nil for a parked car with nobody in it at
		-- all (physics contact with a nearby player, engine-internal ownership
		-- quirks), which made parked cars randomly drop their suspension for
		-- a few frames and then "spring back" once it cleared up.
		if not car.Occupied and now >= car.ResumeAfter then
			local chassis = carModel.PrimaryPart
			local config = VehiclePhysics.GetConfig(chassis)
			VehiclePhysics.Step(carModel, car.Attachments, config, car.State, delta, nil)
		end
	end
end

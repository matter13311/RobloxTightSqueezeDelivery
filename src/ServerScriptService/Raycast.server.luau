local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local wheelsFolder = ReplicatedStorage.Wheels
local defaultWheelModel = wheelsFolder.UAZWheelDetailed
local VehicleFolder = workspace.Vehicles

local INITIAL_SETTLE_TIME = 5 -- seconds - how long the server runs real suspension physics on a freshly-placed car before freezing it, so it settles onto the ground correctly instead of anchoring wherever it happened to be placed in Studio (often floating or embedded)

-- Runs real suspension physics briefly so a freshly-placed car (which may be
-- floating or embedded, wherever it was left in Studio) settles onto the
-- ground properly, then Anchors it there. Only ever runs once, at setup -
-- this is not the old always-on parked-car loop, it's a one-time calibration.
local function SettleThenAnchor(carModel, chassis, attachments)
	local config = VehiclePhysics.GetConfig(chassis)
	local state = VehiclePhysics.NewState()

	chassis.Anchored = false
	chassis:SetNetworkOwner(nil) -- server simulates this settle-in period

	local elapsed = 0
	while elapsed < INITIAL_SETTLE_TIME do
		local delta = RunService.Heartbeat:Wait()
		-- Someone may have already gotten in while this was still settling -
		-- back off immediately rather than fighting the driving client.
		if carModel.VehicleSeat.Occupant then
			return
		end
		elapsed += delta
		VehiclePhysics.Step(carModel, attachments, config, state, delta, { Throttle = 0, Steer = 0 })
	end

	if not carModel.VehicleSeat.Occupant then
		chassis.Anchored = true
	end
end

local function AddCar(carModel)
	local chassis = carModel.PrimaryPart
	if not chassis then
		warn("VehicleManager: " .. carModel:GetFullName() .. " has no PrimaryPart set - skipping this car")
		return
	end
	local attachments = VehiclePhysics.GetWheelAttachments(chassis)

	-- Parked by default: fully Anchored, so there is no physics running at
	-- all (and nothing that can jitter) until someone actually drives it.
	-- Suspension only runs while unanchored, in the driving client's own
	-- Step() loop - parking just freezes whatever pose the car was last
	-- settled into (e.g. wheels raised correctly onto a curb), it doesn't
	-- keep re-simulating to hold that pose. Starts Anchored immediately so
	-- there's no gap where it's an unowned, unsimulated physics body -
	-- SettleThenAnchor (below) briefly takes over right after to calibrate
	-- its actual resting pose before freezing it there for real.
	chassis.Anchored = true

	carModel.VehicleSeat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = carModel.VehicleSeat.Occupant
		if occupant then
			local player = Players:GetPlayerFromCharacter(occupant.Parent)
			if player then
				chassis.Anchored = false
				chassis:SetNetworkOwner(player)
			end
		else
			chassis.Anchored = true
		end
	end)

	-- wheels (purely cosmetic - a car can override its wheel mesh via a
	-- "WheelModelName" attribute on the Chassis, or a WheelModelName entry in
	-- its Configs/<name>.luau file, naming a different model in
	-- ReplicatedStorage.Wheels)
	local wheelModelName = VehiclePhysics.GetConfig(chassis).WheelModelName
	local wheelModel = (wheelModelName and wheelsFolder:FindFirstChild(wheelModelName)) or defaultWheelModel

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

	task.spawn(SettleThenAnchor, carModel, chassis, attachments)
end

local function TryAddCar(carModel)
	-- One misconfigured car (missing PrimaryPart, missing a WheelXX
	-- attachment, etc) shouldn't be able to take down every other car's
	-- setup by erroring out of this script entirely.
	local ok, err = pcall(AddCar, carModel)
	if not ok then
		warn("VehicleManager: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	TryAddCar(carModel)
end
VehicleFolder.ChildAdded:Connect(TryAddCar)

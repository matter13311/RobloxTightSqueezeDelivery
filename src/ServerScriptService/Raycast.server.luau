local WheelPositions = {
    FL = Vector3.new(-2.9, 0, -5),
    FR = Vector3.new(2.9, 0, -5),
    RL = Vector3.new(-2.9, 0, 5),
    RR = Vector3.new(2.9, 0, 5)
}

local wheelModel = game.ReplicatedStorage.UAZWheel
local VehicleFolder = workspace.Vehicles
local AllCarsMemory = {}
local ExistingCarsTable = {} --stores every car, make car folder to go without it

local function AddCar(obj)
    table.insert(ExistingCarsTable,obj)
    obj.PrimaryPart:SetNetworkOwner(nil)--now car physics are calculated only on server
    AllCarsMemory[obj] = {} --adds table for any memory you want, but i need it only for suspension right now
    AllCarsMemory[obj].SpringLengthMemory = {}
    for i, v in pairs(WheelPositions) do AllCarsMemory[obj].SpringLengthMemory[i] = 0.5 end --sets spring length
    obj.VehicleSeat:GetPropertyChangedSignal('Occupant'):Connect(function()
        local occ = obj.VehicleSeat.Occupant
        if occ then--if someone just sat
            local player = game.Players:GetPlayerFromCharacter(occ.Parent)
            if player then--if not npc
                obj.PrimaryPart:SetNetworkOwner(player)
            end
        else
            obj.PrimaryPart:SetNetworkOwner(nil)
        end
    end)

    --wheels
    local wheelFolder = Instance.new("Folder", obj)
    wheelFolder.Name = "Wheels"
    for i,v in pairs(WheelPositions) do
        local ClonedWheel = wheelModel:Clone()
        ClonedWheel.Parent = wheelFolder
        ClonedWheel.Name = i
        ClonedWheel.CanCollide = false
        local weld = Instance.new("Weld", ClonedWheel)
        weld.Part0 = obj.PrimaryPart
        weld.Part1 = ClonedWheel
        weld.C0 = CFrame.new(WheelPositions[i])

        if v.x >0 then
            weld.C0 = weld.C0 * CFrame.Angles(0, math.rad(180), 0)
        end
    end
end


for _,object in pairs(VehicleFolder:GetChildren())do
    AddCar(object)
end

local SuspensionMaxLength = 1.3
local wheelRadius = 1.5

local Stiffness = 70
local Damper = 2

local wheelFriction = 5


-- game.ReplicatedStorage.SwitchLight.OnServerEvent:Connect(function(player)
--     if player.Character and player.Character.Humanoid.SeatPart and player.Character.Humanoid.SeatPart:FindFirstAncestor('Vehicles') then
--         local partsModel = player.Character.SeatPart:FindFirstOfClass('Model').Model
--         partsModel.H1.Light.Enabled = not partsModel.H1.Light.Enabled
--         partsModel.T2.Light.Enabled = partsModel.H1.Light.Enabled
--     end
-- end)


while true do
    local delta = game["Run Service"].Heartbeat:Wait()
    for _, carModel in pairs(ExistingCarsTable) do
        local carPrim = carModel.PrimaryPart

        -- Only simulate suspension while the server actually owns this car's
        -- physics. SetNetworkOwner(nil) is a request that has to replicate,
        -- not an instant switch - right after a player exits, the server can
        -- briefly still be working from stale/inconsistent state before
        -- ownership has genuinely settled back to it. Applying a corrective
        -- impulse against that stale state is what launches the car in a
        -- random direction at exit; skipping until ownership is confirmed
        -- avoids fighting over data nobody agrees on yet.
        if carPrim:GetNetworkOwner() == nil then
            local DisCarSpringLength = AllCarsMemory[carModel].SpringLengthMemory

            for wheelName, originalPosition in pairs(WheelPositions) do
                local carCFrame = carPrim.CFrame
                local rayOrigin = carCFrame:ToWorldSpace(CFrame.new(originalPosition)).p
                local rayDirection = -carCFrame.UpVector * (SuspensionMaxLength + wheelRadius)
                local rayParams = RaycastParams.new()
                rayParams.FilterType = Enum.RaycastFilterType.Exclude
                rayParams.FilterDescendantsInstances = { carModel }
                local raycast = workspace:Raycast(rayOrigin,rayDirection,rayParams)

                if raycast then

                    local RaycastDistance = (rayOrigin - raycast.Position).magnitude

                    local SpringLength = math.clamp(RaycastDistance - wheelRadius, 0, SuspensionMaxLength)
                    local StiffnessForce = Stiffness * (SuspensionMaxLength - SpringLength)
                    local DamperForce = Damper * (( DisCarSpringLength[wheelName] - SpringLength) / delta)
                    local SuspensionForceVec3 = carCFrame.UpVector * (StiffnessForce + DamperForce)

                    local RotationsOnlyWhereDirCFrame = CFrame.lookAt(Vector3.zero, carCFrame.LookVector, carCFrame.UpVector)
                    local LocalVelocity = RotationsOnlyWhereDirCFrame:ToObjectSpace(CFrame.new(carPrim:GetVelocityAtPosition(raycast.Position)))

                    local XForce = carCFrame.RightVector * -LocalVelocity.x * wheelFriction
                    -- The server never drives a car (nobody's pressing anything while it's
                    -- parked), so unlike the client it always brakes forward/backward too -
                    -- otherwise a car handed back with leftover speed would coast forever.
                    -- NOTE: LookVector is the local -Z axis (not +Z like RightVector is +X),
                    -- so LocalVelocity.z is already the negative of forward speed - don't
                    -- negate it again, or this pushes further in the direction of travel
                    -- instead of opposing it.
                    local ZForce = carCFrame.LookVector * LocalVelocity.z * wheelFriction

                    DisCarSpringLength[wheelName] = SpringLength

                    carPrim:ApplyImpulseAtPosition(SuspensionForceVec3 + XForce + ZForce, rayOrigin)

                end



            end
        end
    end
    

    
end

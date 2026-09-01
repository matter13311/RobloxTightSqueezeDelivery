local WheelPositions = {
    FL = Vector3.new(-2.9, 0, -5),
    FR = Vector3.new(2.9, 0, -5),
    RL = Vector3.new(-2.9, 0, 5),
    RR = Vector3.new(2.9, 0, 5)
}

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
end
--better make folder for cars only, so wont have to check if its car
for _,object in pairs(workspace:GetChildren())do
    --any check that will tell if it is car
    if object.Name == 'CarModel'then
        AddCar(object)
    end
end

local SuspensionMaxLength = 1.3
local wheelRadius = 1.5

local Stiffness = 70
local Damper = 2

local wheelFriction = 5

while true do
    local delta = game["Run Service"].Heartbeat:Wait()
    for _, carModel in pairs(ExistingCarsTable) do
        local carPrim = carModel.PrimaryPart
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

                    DisCarSpringLength[wheelName] = SpringLength

                    carPrim:ApplyImpulseAtPosition(SuspensionForceVec3 + XForce, rayOrigin)

                end



        end
    end
    

    
end

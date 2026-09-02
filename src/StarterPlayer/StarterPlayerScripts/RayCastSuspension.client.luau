local WheelPositions = {
    FL = Vector3.new(-2.9, 0, -5),
    FR = Vector3.new(2.9, 0, -5),
    RL = Vector3.new(-2.9, 0, 5),
    RR = Vector3.new(2.9, 0, 5)
}

local SpringLengthMemory = {}
for i, v in pairs(WheelPositions) do SpringLengthMemory[i] = 0.5 end --sets spring length

local SuspensionMaxLength = 1.3
local wheelRadius = 1.5

local Stiffness = 100
local Damper = 5

local wheelFriction = 10
local torque = 10
local maxSpeed = 50
local steerAngle = 30
local brakeStrength = 10 -- how hard the car auto-brakes once it's nearly stopped
local coastDrag = 0.5 -- gentle rolling resistance while coasting above coastSpeedThreshold
local coastSpeedThreshold = 3 -- studs/s - below this, snap to a full stop instead of gently coasting

local smoothSteer = 0

local Players = game:GetService("Players")
local player = Players.LocalPlayer

local function onCharacterAdded(character)
    local humanoid = character:WaitForChild("Humanoid")



    humanoid.Seated:Connect(function(seated, seatPart)
        if seated and seatPart then
            if seatPart:FindFirstAncestor('Vehicles')  and seatPart:IsA('VehicleSeat') then
                local carModel = seatPart.Parent
                local carPrim = carModel.PrimaryPart
                

                local serverTakeOverWait = 0
                while true do
                    local delta = game["Run Service"].Heartbeat:Wait()


                    carPrim.Sound.PlaybackSpeed = 0.8 + carPrim.AssemblyLinearVelocity.Magnitude / maxSpeed
                    -- game.Players.LocalPlayer.PlayerGui.ScreenGui.TextLabel.Text = carPrim.AssemblyAngularVelocity.magnitude


                    smoothSteer = math.abs(seatPart.SteerFloat - smoothSteer) <= delta * 5 and seatPart.SteerFloat or smoothSteer + math.sign(seatPart.SteerFloat - smoothSteer) * delta * 5    

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
                            local DamperForce = Damper * (( SpringLengthMemory[wheelName] - SpringLength) / delta)
                            local SuspensionForceVec3 = carCFrame.UpVector * (StiffnessForce + DamperForce)

                            local RotationsOnlyWhereDirCFrame = CFrame.lookAt(Vector3.zero, carCFrame.LookVector, carCFrame.UpVector) 
                            if string.sub(wheelName, 1, 1) == "F" then
                                RotationsOnlyWhereDirCFrame = RotationsOnlyWhereDirCFrame * CFrame.Angles(0, math.rad(-smoothSteer * steerAngle), 0)
                            end
                            local LocalVelocity = RotationsOnlyWhereDirCFrame:ToObjectSpace(CFrame.new(carPrim:GetVelocityAtPosition(raycast.Position)))

                            local XForce = RotationsOnlyWhereDirCFrame.RightVector * -LocalVelocity.x * wheelFriction

                            local ZForce
                            if seatPart.ThrottleFloat ~= 0 then
                                ZForce = RotationsOnlyWhereDirCFrame.LookVector * seatPart.ThrottleFloat * torque * (1 - math.min(1, math.abs(LocalVelocity.z)/ maxSpeed)) -- Reduce forward force when steering
                            elseif math.abs(LocalVelocity.z) > coastSpeedThreshold then
                                -- Still going fast enough to be "coasting" - only apply a light
                                -- rolling drag so momentum carries through, instead of slamming
                                -- to a stop the instant you let go of the accelerator.
                                -- NOTE: LookVector is the local -Z axis, not +Z, so
                                -- LocalVelocity.z is already the negative of forward speed -
                                -- don't negate it again (that would push further in the
                                -- direction of travel instead of opposing it).
                                ZForce = RotationsOnlyWhereDirCFrame.LookVector * LocalVelocity.z * coastDrag
                            else
                                -- Slow enough that continuing to creep forward/backward would
                                -- just look like it's stuck rolling - fully brake to a stop.
                                ZForce = RotationsOnlyWhereDirCFrame.LookVector * LocalVelocity.z * brakeStrength
                            end
                            SpringLengthMemory[wheelName] = SpringLength

                            carPrim:ApplyImpulseAtPosition(SuspensionForceVec3 + XForce + ZForce, rayOrigin)
                        else
                            SpringLengthMemory[wheelName] = SuspensionMaxLength
                        end
                    end

                    if seatPart.Occupant ~= humanoid then
                        serverTakeOverWait += delta
                        if serverTakeOverWait >= 1 then
                            break
                        end
                    end
                end
            end
        end
    end)

    game.ContextActionService:BindAction("lightButton", function(n, istate, iobject)
        if humanoid.SeatPart and istate == Enum.UserInputState.Begin then
            -- game.ReplicatedStorage.SwitchLight:FireServer()
        end  
    end, false, Enum.KeyCode.L)


    local WheelRotations = {}

    game["Run Service"]:BindToRenderStep('MoveWheels', 5, function()
    
        for _, vehicle in pairs(workspace.Vehicles:GetChildren()) do
            local carPrim = vehicle.PrimaryPart

            for i, v in pairs(WheelPositions) do
                local carCFrame = carPrim.CFrame
                local rayOrigin = carCFrame:ToWorldSpace(CFrame.new(Vector3.new(v.x, v.y - wheelRadius, v.z))).p
                local rayDirection = -carCFrame.UpVector * (SuspensionMaxLength + wheelRadius)
                local rayParams = RaycastParams.new()
                rayParams.FilterType = Enum.RaycastFilterType.Exclude
                rayParams.FilterDescendantsInstances = { vehicle }
                local raycast = workspace:Raycast(rayOrigin,rayDirection,rayParams)

                if raycast then
                    local DatWeld = vehicle.Wheels[i].Weld
                    DatWeld.C0 = CFrame.new(v - Vector3.new(0, (rayOrigin - raycast.Position).magnitude, 0))
                    if v.x > 0 then
                        DatWeld.C0 = DatWeld.C0 * CFrame.Angles(0, math.rad(180), 0)
                    end

                    if string.sub(i, 1, 1) == "F" then
                        DatWeld.C0 = DatWeld.C0 * CFrame.Angles(0, -math.rad(smoothSteer * steerAngle), 0)
                    end

                    local LocalVelocity = CFrame.lookAt(Vector3.zero, carCFrame.LookVector, carCFrame.UpVector):ToObjectSpace(CFrame.new(carPrim:GetVelocityAtPosition(raycast.Position)))
                    
                    if not WheelRotations[vehicle] then
                        WheelRotations[vehicle] = {}
                        for i,v in pairs(WheelPositions) do
                            WheelRotations[vehicle][i] = 0.5
                        end

                    end

                    WheelRotations[vehicle][i] += LocalVelocity.z/56  --56 should be same as math.rad(number)

                    DatWeld.C0 = DatWeld.C0 * CFrame.Angles(WheelRotations[vehicle][i], 0, 0)
                end
            end
        end
    end)
end

if player.Character then
    onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

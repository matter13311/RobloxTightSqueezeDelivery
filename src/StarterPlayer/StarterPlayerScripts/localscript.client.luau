local Players = game:GetService("Players")
local player = Players.LocalPlayer

local connection = nil

local function onCharacterAdded(character)
    local humanoid = character:WaitForChild("Humanoid")

    humanoid.Seated:Connect(function(active, seatPart)
        if connection ~= nil then
            connection:Disconnect()
            connection = nil
        end

        if seatPart == nil then return end

        if seatPart.Name ~= "VehicleSeat" then return end

        seatPart.Torque = 5000
        local cylindricalBL = seatPart.Parent.Wheels.BL.CylindricalConstraint
        local cylindricalBR = seatPart.Parent.Wheels.BR.CylindricalConstraint

        connection = seatPart.Changed:Connect(function(property)
            if property == "SteerFloat" then

            elseif property == "ThrottleFloat" then
               local torque = math.abs(seatPart.ThrottleFloat) * seatPart.Torque

               if torque == 0 then --if player lets go of throttle, then set torque to cylindrical constaints torque to slowly slow down vehicle
                    torque = 2000
               end

               cylindricalBL.MotorMaxTorque = torque --MotorMaxTorque cannot be negative number.
               cylindricalBR.MotorMaxTorque = torque


               local angularVelocity = math.sign(seatPart.ThrottleFloat) * 10000  --if the value is less than 0, it'll return -1. If it's 0, then 0. If it's greater than 0, it'll return 1.
               cylindricalBL.AngularVelocity = angularVelocity
               cylindricalBR.AngularVelocity = angularVelocity

            end
        end)
    end)
end

if player.Character then
    onCharacterAdded(player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

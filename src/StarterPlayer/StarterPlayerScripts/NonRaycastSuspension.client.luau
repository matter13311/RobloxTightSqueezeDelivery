local tweenService = game:GetService("TweenService")
local tweenInfo = TweenInfo.new(
    1 -- Duration
)

local Players = game:GetService("Players")
local player = Players.LocalPlayer

local connection = nil

local function onCharacterAdded(character)
    local humanoid = character:WaitForChild("Humanoid")

    humanoid.Seated:Connect(function(active, seatPart)
        print("Seated event fired. Active:", active, "SeatPart:", seatPart)
        if connection ~= nil then
            connection:Disconnect()
            connection = nil
        end

        if seatPart == nil then return end

        if seatPart.Name ~= "VehicleSeat" then return end

        seatPart.Torque = 5000
        seatPart.TurnSpeed = 30 --TurnSpeed isn't actually speed, it's angle that wheels rotate when steering

        local attachmentFL = seatPart.Parent.PrimaryPart.AttachmentFL
        local attachmentFR = seatPart.Parent.PrimaryPart.AttachmentFR
        local cylindricalBL = seatPart.Parent.Wheels.BL.CylindricalConstraint
        local cylindricalBR = seatPart.Parent.Wheels.BR.CylindricalConstraint

        local wheelRadius = seatPart.Parent.Wheels.BR.Size.Y /2

        local maxAngularVelocity = seatPart.MaxSpeed / wheelRadius -- Adjust the multiplier as needed to achieve the desired speed
        connection = seatPart.Changed:Connect(function(property)
            if property == "SteerFloat" then
                local orientation = Vector3.new(0, -seatPart.SteerFloat * seatPart.TurnSpeed, 90)

                --tweenservice so the wheels don't rotate immediately when steering
                tweenService:Create(attachmentFL, tweenInfo, {Orientation = orientation}):Play()
                tweenService:Create(attachmentFR, tweenInfo, {Orientation = orientation}):Play()

            elseif property == "ThrottleFloat" then
               local torque = math.abs(seatPart.ThrottleFloat) * seatPart.Torque

               if torque == 0 then --if player lets go of throttle, then set torque to cylindrical constaints torque to slowly slow down vehicle
                    torque = 2000
               end
               local angularVelocity = math.sign(seatPart.ThrottleFloat) * maxAngularVelocity  --if the value is less than 0, it'll return -1. If it's 0, then 0. If it's greater than 0, it'll return 1.

               cylindricalBL.MotorMaxTorque = torque --MotorMaxTorque cannot be negative number.
               cylindricalBR.MotorMaxTorque = torque


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

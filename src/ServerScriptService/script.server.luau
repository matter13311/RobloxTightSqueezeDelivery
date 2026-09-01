game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		character.Humanoid.Seated:Connect(function(active, seatPart)
			if seatPart == nil then return end

			if seatPart.Name ~= "VehicleSeat" then return end

			seatPart:SetNetworkOwner(player) --gives player client control of the vehicle. However, still need to add script to prevent hackers
		end)
	end)
end)



--Everything done so far in workspace
--Created base vehicle model called VoltModel. Inside is following structure
--VoltMesh: like chassis part
	--AttachmentXX - 4 attachments, positioned on the corners of the chassis. the orientation is rotated 90: 0, 0, 90
	--the CustomPhysicalProperties is enabled to get the Mass to 80. Currently set Density to 2 to achieve mass of 80.
	--Orientation is 0,0,90
--Wheels named like BL, BR, FL, FR. 
		--wheel part has CustomPhysicalProperties. Density set to 2, Elasticity set to 0.2, friction set to 1.5
		--each wheel contains 
		--Attachment set in the middle of the wheel. it's rotated 180. Orientation: 0, 0, -180
		--CylindricalConstraint -attaches Attachment in wheel to AttachmentXX in Chassis. 
				--AngularActuatorType: Motor
				--InclinationAngle: 50
				--AngularVelocity: 0
				--MotorMaxTorque: 2000
				--limits lowerLimit: -2, upperlimit: -1  controls how max and min distance
				--inclinationAngle: 90
				--BR and BL wheels have AngularActuatorType set to Motor
		--SpringConstraint -- Attaches to Attachment in wheel to AttachmentXX in Chassis. 
				--Damping: 200
				--Stiffness: 3500
				--Freelength in back wheels is 3.2. Front wheels are 2.8
--VehicleSeat - welded to Chassis
--added collision group, chassis and car body parts cannot collide with wheels

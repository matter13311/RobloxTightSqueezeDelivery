-- Watches the road just ahead of the truck for people standing in it, reports
-- them to VehiclePlayerImpact.server.luau, and takes the small bite out of the
-- car's own speed that hitting somebody should cost.
--
-- This runs on the driving client, and only there, for the same two reasons
-- VehicleCrashDetector does. Measuring: this client owns the chassis, so its
-- position and velocity are the simulation and the server's are a replicated
-- echo a round trip behind. Correcting: writing AssemblyLinearVelocity
-- anywhere but on the owning machine gets overwritten by the next replication
-- tick.
--
-- But there is a third reason here that neither of those covers, and it is the
-- entire reason this script exists rather than a Touched handler on the
-- server. The knockdown has to happen BEFORE the metalwork arrives.
--
-- A standing Humanoid is not a physics object that can be pushed - Roblox's
-- Humanoid controller re-asserts an upright pose every frame, so a truck
-- hitting one hits a wall. A RAGDOLLED character is loose limbs the truck
-- drives straight through (RagdollUtility puts them in a group that doesn't
-- collide with vehicles at all). Those are two completely different physical
-- outcomes, and which one you get is decided by which of the two happens
-- first. Detect on contact and the answer is always "the wall", because the
-- solver has already resolved the frame by the time anything can react to it -
-- the truck stops dead, the report crosses the network, and the pedestrian
-- folds up half a second later underneath a truck that is already parked on
-- them. That is the bug this whole arrangement removes, and it is a
-- SEQUENCING bug, not a tuning one; no amount of adjusting the response can
-- fix a response that runs after the thing it was supposed to prevent.
--
-- So: look a fixed amount of TIME ahead (KnockdownLookahead), which at speed
-- is a good few studs and at a crawl is almost nothing, and report the moment
-- somebody is inside that box. The ragdoll is underway by the time the bumper
-- gets there, and the bumper finds nothing to hit.
--
-- Sessions follow the same shape as VehicleCrashDetector (one live session,
-- torn down on Seated(false)) and are deliberately independent of it: a
-- pedestrian detector that stops working because the crash loop errored is
-- worse than two loops.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local pedestrianHitRemote = ReplicatedStorage:WaitForChild("VehiclePedestrianHit")

local player = Players.LocalPlayer

local session = nil

--=============================================================================
-- Session
--=============================================================================

local function endSession()
	if not session then
		return
	end
	for _, connection in session.Connections do
		connection:Disconnect()
	end
	session = nil
end

-- The box swept ahead of the car: its own bounding box, stretched forward
-- along the direction it is actually travelling by however far it will get in
-- KnockdownLookahead seconds.
--
-- Stretched along the car's own local Z rather than along the world-space
-- velocity vector, because a box in Roblox is defined by a CFrame and a size
-- and there is no such thing as a box skewed off its own axes. In a slide the
-- two disagree; the sign below is what keeps the probe on the correct end of
-- the truck when reversing, and a sideways slide simply gets the car's own
-- footprint, which is the honest answer for a car that isn't going forwards.
local function probeBox(carModel, velocity)
	local cf, size = carModel:GetBoundingBox()
	local travel = velocity.Magnitude * VehicleCollision.KnockdownLookahead

	-- LookVector is -Z, so travelling forwards means growing the box towards
	-- -Z and moving its centre half that far the same way.
	local forwards = velocity:Dot(cf.LookVector) >= 0
	local offset = if forwards then -travel * 0.5 else travel * 0.5

	return cf * CFrame.new(0, 0, offset), size + Vector3.new(0, 0, travel)
end

local function step(mySession)
	if session ~= mySession then
		return
	end
	local chassis = mySession.Chassis
	if not chassis.Parent then
		endSession()
		return
	end

	local velocity = chassis.AssemblyLinearVelocity
	if velocity.Magnitude < VehicleCollision.KnockdownMinSpeed then
		-- Below the threshold nothing is reported and nothing is swept, which
		-- means a pedestrian keeps their ordinary collision and a truck
		-- creeping up to one is blocked by them exactly as it would be by a
		-- bollard. That is deliberate: nudging into somebody at walking pace
		-- is not running them over.
		return
	end

	local now = os.clock()
	for humanoid, reportedAt in mySession.Reported do
		if now - reportedAt > VehicleCollision.KnockdownCooldown or humanoid.Parent == nil then
			mySession.Reported[humanoid] = nil
		end
	end

	local probeCF, probeSize = probeBox(mySession.CarModel, velocity)
	local hits = workspace:GetPartBoundsInBox(probeCF, probeSize, mySession.ProbeParams)

	local hitAnyone = false
	for _, part in hits do
		local character = part.Parent
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or mySession.Reported[humanoid] then
			continue
		end
		-- Seated players are somebody's driver or passenger, including this
		-- car's own - they are inside the probe box every single frame and
		-- must never be reported. The server refuses them too; this just
		-- keeps the remote from firing 60 times a second on a full truck.
		if humanoid.SeatPart or humanoid.Health <= 0 then
			continue
		end

		mySession.Reported[humanoid] = now
		hitAnyone = true
		pedestrianHitRemote:FireServer(mySession.CarModel, humanoid)
	end

	if not hitAnyone then
		return
	end

	-- Scripted, because there is no longer a collision to produce it - the
	-- victim is about to become something this car drives through. Applied
	-- once for the frame however many people were in the box: mowing down a
	-- queue should not brake harder than a wall would.
	--
	-- Written straight to the velocity rather than through ApplyImpulse so it
	-- is an exact fraction of the current speed, independent of frame rate and
	-- of the car's mass. See VehicleCollision.KnockdownSpeedLoss for why the
	-- honest number here is small.
	chassis.AssemblyLinearVelocity = velocity * (1 - VehicleCollision.KnockdownSpeedLoss)
end

local function beginSession(carModel)
	local chassis = carModel.PrimaryPart
	if not chassis then
		return
	end

	endSession()

	local probeParams = OverlapParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Exclude
	probeParams.FilterDescendantsInstances = { carModel, player.Character }
	-- The probe box is large and sits in the middle of the road, so without
	-- this every invisible trigger volume the truck drives through comes back
	-- in the results - the vehicle plots' CollisionBoxes especially (CanCollide
	-- false by design, see PlotCollisionGuard.server.luau). None of them can
	-- ever be a pedestrian, and they are the bulk of what would be returned.
	--
	-- It also quietly drops the HumanoidRootPart of anyone it does find, which
	-- is non-collidable on every character - harmless, because the limbs and
	-- torso around it are not.
	probeParams.RespectCanCollide = true

	local mySession = {
		CarModel = carModel,
		Chassis = chassis,
		Reported = {}, -- [Humanoid] = os.clock() of the last report, so one pass doesn't report the same person every frame
		Connections = {},
		ProbeParams = probeParams,
	}
	session = mySession

	table.insert(
		mySession.Connections,
		RunService.PostSimulation:Connect(function()
			step(mySession)
		end)
	)
end

local function onSeated(isSeated, seatPart)
	if not isSeated or not seatPart then
		endSession()
		return
	end

	local carModel = seatPart.Parent
	-- Driver only. A passenger is along for the ride and has no ownership of
	-- the chassis, so nothing they measured would be right and nothing they
	-- wrote to AssemblyLinearVelocity would stick - and the server would
	-- refuse their reports anyway.
	if not carModel or VehicleSeats.GetDriverSeat(carModel) ~= seatPart then
		endSession()
		return
	end

	beginSession(carModel)
end

local function bindCharacter(character)
	local humanoid = character:WaitForChild("Humanoid")
	humanoid.Seated:Connect(onSeated)
	humanoid.Died:Connect(endSession)
end

if player.Character then
	bindCharacter(player.Character)
end
player.CharacterAdded:Connect(bindCharacter)

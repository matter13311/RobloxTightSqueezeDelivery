-- Knocks a standing player down - a real, floppy, physics ragdoll that
-- topples and lands flat rather than a stiff mannequin falling over - when a
-- moving vehicle drives into them, instead of letting them act like an
-- anchored wall a truck has to shove or grind past. A player just standing in
-- a doorway or a delivery lane shouldn't be able to block traffic - a
-- determined griefer could otherwise park their character in front of a plot
-- exit all day.
--
-- The reason a stationary player reads as "anchored and collidable" isn't the
-- collision setup - Vehicle/Attached already collide with "Default" the same
-- as any wall (see VehicleCollisionSetup.server.luau) - it's that Roblox's own
-- Humanoid controller actively fights being pushed, re-asserting the
-- character's upright, animated pose every single frame regardless of what
-- physics just did to it. See RagdollUtility for how that gets shut off and
-- turned into an actual ragdoll.
--
-- ORDER OF EVENTS, which is the whole design:
--
--   1. The DRIVING client sees a pedestrian a fraction of a second ahead of
--      its own bumper and reports it (VehiclePedestrianDetector.client.luau).
--   2. This script checks the report and ragdolls the victim - which also
--      moves them into the PlayerRagdoll group, and that group does not
--      collide with any part of a car (see RagdollUtility).
--   3. The hulls arrive a frame or two later and find nothing to hit. The
--      truck keeps its speed; the driving client bleeds off a small scripted
--      amount of it so the hit still registers as one.
--
-- Doing it in the other order - wait for contact, then ragdoll - is what
-- produced "the truck stops dead, and half a second later the pedestrian folds
-- up". Both halves of that came from the same place: the contact resolves
-- FIRST, against a Humanoid that is still a wall, and the knockdown can only
-- follow it across the network afterwards.
--
-- WHY THE CLIENT REPORTS, given this script used to do its own detection and
-- said so at some length: the driving client owns the chassis, so its position
-- and velocity ARE the simulation and the server's are a replicated echo a
-- round trip behind. Detection has to beat the collision by a frame or two; a
-- detector running an echo behind cannot, by construction. This is exactly the
-- argument VehicleDamage makes, and the trust model is copied from it
-- verbatim: the client is believed about WHO it is about to hit, and about
-- nothing else. How hard, how often, how far away, and whether they are even a
-- legal target are all re-derived here from the server's own copy of the
-- world. The knockdown velocity is built from the server's chassis velocity
-- and never from a number the client sent, so the worst a forged report can do
-- is knock over somebody the driver was genuinely about to reach anyway.
--
-- The old Touched detection is kept as a backstop (see setUpCar) for the cases
-- the client detector cannot cover: a car rolling with nobody driving it, or a
-- driver whose detector never started. It fires late and the truck snags on
-- the hit, but late is better than a pedestrian who is simply immune.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local RagdollUtility = require(ReplicatedStorage.Modules.RagdollUtility)

local VehicleFolder = workspace.Vehicles

-- Client -> server. Fired by the driving client the moment a pedestrian enters
-- the box it sweeps ahead of itself.
local pedestrianHitRemote = Instance.new("RemoteEvent")
pedestrianHitRemote.Name = "VehiclePedestrianHit"
pedestrianHitRemote.Parent = ReplicatedStorage

local lastKnockdown = {} -- [Humanoid] = os.clock() of the last knockdown kick
local recoveryGeneration = {} -- [Humanoid] = number, bumped by every hit so an earlier hit's recovery timer can't stand someone up early
local reportBuckets = {} -- [Player] = { Count, WindowStart }

-- Prefixed so this whole system can be filtered out of the Output window with
-- a single search, the same way VehicleDamage's log is.
local function log(format, ...)
	if VehicleCollision.DebugLogging then
		print("[Pedestrian] " .. string.format(format, ...))
	end
end

--=============================================================================
-- Standing back up
--=============================================================================

-- A ragdoll drives through cars; a standing player does not. So the one moment
-- that can go wrong is the handover between those two states - if the body
-- came to rest underneath the truck that hit it, or under one that has since
-- parked over it, restoring its ordinary collision spawns a player INSIDE
-- solid geometry, and Roblox resolves that by firing them out of it.
--
-- So the recovery timer is a first attempt, not a deadline: while the body is
-- still inside a car it stays a ragdoll and asks again shortly. It gets a
-- bounded number of tries and then stands up regardless, because a player who
-- can never get up again because somebody parked on them is a far worse
-- outcome than one brief shove.
local RECOVERY_RETRY_INTERVAL = 0.5
local RECOVERY_MAX_RETRIES = 12 -- ~6 seconds of being parked on before giving up and standing anyway

local function isInsideACar(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { VehicleFolder }
	-- Cosmetic panels and plot trigger volumes are non-collidable, so standing
	-- up "inside" one of those is not standing up inside anything.
	params.RespectCanCollide = true
	params.MaxParts = 1
	return #workspace:GetPartBoundsInBox(root.CFrame, root.Size + Vector3.one * 2, params) > 0
end

local function standUp(humanoid, character, myGeneration)
	for _ = 1, RECOVERY_MAX_RETRIES do
		if recoveryGeneration[humanoid] ~= myGeneration then
			return -- a later hit re-armed this; that hit's own timer owns the recovery now
		end
		if not humanoid.Parent or humanoid.Health <= 0 then
			return
		end
		if not isInsideACar(character) then
			break
		end
		task.wait(RECOVERY_RETRY_INTERVAL)
	end

	if recoveryGeneration[humanoid] ~= myGeneration then
		return
	end
	if humanoid.Parent and humanoid.Health > 0 then
		RagdollUtility.Stop(character)
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

--=============================================================================
-- Knocking down
--=============================================================================

local function knockDown(humanoid, character, vehicleVelocity)
	-- Seated players - driving or riding along in ANY car, including the one
	-- that just touched them - are left alone. Getting flung out of your own
	-- seat because the truck you're sitting in grazed a hull box would be a
	-- worse bug than the one this script exists to fix, and this is also what
	-- keeps a player from ever being ragdolled while driving.
	if humanoid.SeatPart then
		return
	end

	local now = os.clock()
	if now - (lastKnockdown[humanoid] or 0) < VehicleCollision.KnockdownCooldown then
		return
	end
	if lastKnockdown[humanoid] == nil then
		-- First time this Humanoid has ever been hit - clear its entries once
		-- it's gone, or a long session full of respawns would otherwise grow
		-- these tables forever (a new Humanoid instance every respawn).
		humanoid.Died:Once(function()
			lastKnockdown[humanoid] = nil
			recoveryGeneration[humanoid] = nil
		end)
	end
	lastKnockdown[humanoid] = now

	RagdollUtility.Start(character) -- no-op if a previous hit already ragdolled them
	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	local speed = vehicleVelocity.Magnitude
	local linearVelocity = vehicleVelocity.Unit * (speed * VehicleCollision.KnockdownSpeedFraction)
		+ Vector3.new(0, VehicleCollision.KnockdownUpSpeed, 0)
	local tumbleAxis = vehicleVelocity.Unit:Cross(Vector3.yAxis)
	local angularVelocity = if tumbleAxis.Magnitude > 0.01
		then tumbleAxis.Unit * VehicleCollision.KnockdownTumbleSpeed
		else Vector3.zero

	-- The ragdoll's joints are no longer rigid (see RagdollUtility.Start), so
	-- every limb is its own physics body now - setting velocity on just the
	-- HumanoidRootPart would leave the rest of the body hanging a beat behind,
	-- whipping into place through the new sockets instead of being launched as
	-- one. Setting it on every part sends the whole body flying together, and
	-- lets it spread out and tumble naturally from there.
	--
	-- This is also the ONLY thing that moves the body now that a ragdoll can't
	-- be touched by a car: what used to be "the solver's shove, plus this on
	-- top of it" is just this. That is the point - one authored number, the
	-- same every time, rather than whatever the solver made of a dozen loose
	-- limbs overlapping a hull box travelling at 60 studs/s.
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.AssemblyLinearVelocity = linearVelocity
			part.AssemblyAngularVelocity = angularVelocity
		end
	end

	-- A clip at walking-pace-plus is a stumble; a truck at full speed puts you
	-- down properly. A single fixed duration made every hit feel identical no
	-- matter how hard it was.
	local speedRange = VehicleCollision.KnockdownFullSpeed - VehicleCollision.KnockdownMinSpeed
	local severity = math.clamp((speed - VehicleCollision.KnockdownMinSpeed) / speedRange, 0, 1)
	local duration = VehicleCollision.KnockdownMinDuration
		+ (VehicleCollision.KnockdownMaxDuration - VehicleCollision.KnockdownMinDuration) * severity

	local myGeneration = (recoveryGeneration[humanoid] or 0) + 1
	recoveryGeneration[humanoid] = myGeneration
	task.delay(duration, function()
		standUp(humanoid, character, myGeneration)
	end)

	log("knocked down %s at %.0f studs/s, down for %.1fs", character.Name, speed, duration)
end

--=============================================================================
-- Validation
--=============================================================================

local function withinRateLimit(player)
	local bucket = reportBuckets[player]
	local now = os.clock()
	if not bucket or now - bucket.WindowStart >= 1 then
		reportBuckets[player] = { Count = 1, WindowStart = now }
		return true
	end
	bucket.Count += 1
	return bucket.Count <= VehicleCollision.MaxKnockdownReportsPerSecond
end

Players.PlayerRemoving:Connect(function(player)
	reportBuckets[player] = nil
end)

-- Returns (false, reason) so a silently-dropped report can be logged - a
-- pedestrian who doesn't fall over looks identical whether the car was too slow
-- or the report never got past this function, and those have opposite fixes.
-- On success it also returns the velocity the knockdown should use, which is
-- read here and never taken from the report.
local function validate(player, carModel, humanoid)
	if typeof(carModel) ~= "Instance" or not carModel:IsA("Model") or carModel.Parent ~= VehicleFolder then
		return false, "not a Model inside workspace.Vehicles"
	end
	if typeof(humanoid) ~= "Instance" or not humanoid:IsA("Humanoid") then
		return false, "target was not a Humanoid"
	end

	local character = humanoid.Parent
	if not character or not character:IsDescendantOf(workspace) then
		return false, "target Humanoid is not in a character in the workspace"
	end
	if humanoid.Health <= 0 then
		return false, "target is already dead"
	end
	if character == player.Character then
		return false, "a driver cannot report running themselves over"
	end
	if not withinRateLimit(player) then
		return false,
			string.format("rate limit of %d reports/sec exceeded", VehicleCollision.MaxKnockdownReportsPerSecond)
	end

	-- Same driver check VehicleDamage and VehicleNetworkState use, and for the
	-- same reason: a passenger has no crash of their own to report, and
	-- neither does somebody standing on the pavement deciding who gets run over.
	if VehicleSeats.GetDriverPlayer(carModel) ~= player then
		return false, "reporting player is not the driver of this car"
	end

	-- Everything from here is re-derived from the SERVER's copy of the world
	-- rather than taken from the report, which is what keeps a forged one
	-- harmless. Both numbers are a round trip stale and both are checked
	-- loosely for exactly that reason: they exist to rule out a report about
	-- somebody on the far side of the map from a car that is parked, not to
	-- second-guess a real hit by a stud or two.
	local chassis = carModel.PrimaryPart
	if not chassis then
		return false, "car has no PrimaryPart"
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false, "target has no HumanoidRootPart"
	end
	local distance = (root.Position - chassis.Position).Magnitude
	if distance > VehicleCollision.KnockdownMaxReportDistance then
		return false, string.format("target is %.0f studs from the chassis", distance)
	end

	local velocity = chassis.AssemblyLinearVelocity
	-- Halved against the client's own threshold: the client tested the live
	-- velocity it owns, this tests a replicated echo of it, and a car braking
	-- hard can genuinely have shed real speed in between. Rejecting a true hit
	-- because the echo said 9 studs/s instead of 10 would put the original bug
	-- straight back for anyone on a poor connection.
	if velocity.Magnitude < VehicleCollision.KnockdownMinSpeed * 0.5 then
		return false, string.format("car is only doing %.0f studs/s", velocity.Magnitude)
	end

	return true, nil, velocity
end

pedestrianHitRemote.OnServerEvent:Connect(function(player, carModel, humanoid)
	local ok, reason, velocity = validate(player, carModel, humanoid)
	if not ok then
		log("dropped report from %s: %s", player.Name, reason)
		return
	end
	knockDown(humanoid, humanoid.Parent, velocity)
end)

--=============================================================================
-- Backstop
--=============================================================================

-- Contact detection, kept for the cases the client detector cannot reach: a
-- car rolling downhill with nobody in it, or a driver whose detector never
-- started. It is everything the header says is wrong with detecting on contact
-- - late, and against a Humanoid that is still a wall - so it is a floor on
-- the behaviour and not the mechanism. When both fire, the client's report
-- always lands first and KnockdownCooldown swallows this one.
local function onHullTouched(carModel, other)
	local character = other.Parent
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local chassis = carModel.PrimaryPart
	local velocity = chassis and chassis.AssemblyLinearVelocity
	if not velocity or velocity.Magnitude < VehicleCollision.KnockdownMinSpeed then
		return
	end

	knockDown(humanoid, character, velocity)
end

-- Same contact folder VehicleCrashDetector uses: hull boxes if the car has
-- them (the real collision shape), body panels if it doesn't.
local function setUpCar(carModel)
	local contactFolder = VehicleCollision.GetHullFolder(carModel) or VehicleCollision.GetBodyFolder(carModel)
	if not contactFolder then
		return
	end
	for _, part in contactFolder:GetDescendants() do
		if part:IsA("BasePart") then
			part.Touched:Connect(function(other)
				onHullTouched(carModel, other)
			end)
		end
	end
end

local function trySetUpCar(carModel)
	if not carModel:IsA("Model") then
		return
	end
	local ok, err = pcall(setUpCar, carModel)
	if not ok then
		warn("VehiclePlayerImpact: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	trySetUpCar(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetUpCar)

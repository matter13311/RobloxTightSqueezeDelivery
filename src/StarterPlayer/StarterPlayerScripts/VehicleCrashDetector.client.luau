-- Measures crashes and scrapes on the driving client, kills the rebound, and
-- reports what happened to VehicleDamage.server.luau.
--
-- This runs here, and only here, for two reasons. Measuring: the driving
-- client owns the chassis, so its velocity is the simulation and the server's
-- is a replicated echo a round-trip behind - a crash measured on the server is
-- a crash measured late and wrong. Correcting: writing AssemblyLinearVelocity
-- anywhere but on the owning machine gets overwritten by the next replication
-- tick, which is the same reason Raycast.server.luau has to do its seat-settle
-- BEFORE handing ownership over.
--
-- Sessions follow the same shape as RayCastSuspension.client.luau (one live
-- session, torn down on Seated(false)) but are deliberately independent of it:
-- a crash detector that stops working because the suspension loop errored is
-- worse than two loops.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)
local VehicleCrashSounds = require(ReplicatedStorage.Modules.Vehicles.VehicleCrashSounds)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local impactRemote = ReplicatedStorage:WaitForChild("VehicleImpact")
local scrapeRemote = ReplicatedStorage:WaitForChild("VehicleScrape")

local player = Players.LocalPlayer


-- How long a Touched contact is believed for without being re-reported.
-- TouchEnded is not reliable at speed (a fast enough pass can fire Touched and
-- never fire its partner), so contacts are timed out as well as unregistered.
local CONTACT_TIMEOUT = 0.25

local session = nil

--=============================================================================
-- Effects
--=============================================================================

-- A throwaway anchored part to hang a sound or emitter on, so effects stay put
-- at the point of contact instead of riding along with the truck.
local function newEffectHolder(position)
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.Position = position
	holder.Parent = workspace
	return holder
end

local function playImpactSound(position, severity)
	local holder = newEffectHolder(position)
	local soundId = VehicleCrashSounds.PickImpact()
	if not soundId then
		Debris:AddItem(holder, 0)
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = 0.3 + severity * 0.7
	sound.PlaybackSpeed = 1.1 - severity * 0.3 -- a harder hit is a deeper, slower crunch
	sound.RollOffMaxDistance = 200
	sound.Parent = holder
	sound:Play()
	Debris:AddItem(holder, 4)
end

local function updateScrapeEffect(mySession, position, tangentSpeed)
	local effect = mySession.ScrapeEffect
	if not effect then
		local holder = newEffectHolder(position)

		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Rate = 0
		emitter.Lifetime = NumberRange.new(0.2, 0.5)
		emitter.Speed = NumberRange.new(8, 20)
		emitter.SpreadAngle = Vector2.new(35, 35)
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 190, 90))
		emitter.Size = NumberSequence.new(0.25)
		emitter.Parent = holder

		-- Rolled ONCE, here, when the scrape begins. This sound loops for as
		-- long as the grind lasts, so re-picking per frame would machine-gun
		-- the audio and re-picking per server report would cut it every
		-- quarter second.
		local sound = Instance.new("Sound")
		sound.SoundId = VehicleCrashSounds.PickScrape() or ""
		sound.Looped = true
		sound.RollOffMaxDistance = 120
		sound.Parent = holder
		sound:Play()

		effect = { Holder = holder, Emitter = emitter, Sound = sound }
		mySession.ScrapeEffect = effect
	end

	local intensity = math.clamp(tangentSpeed / 60, 0, 1)
	effect.Holder.Position = position
	effect.Emitter.Rate = 20 + intensity * 120
	effect.Sound.Volume = 0.15 + intensity * 0.55
	effect.Sound.PlaybackSpeed = 0.8 + intensity * 0.5
end

local function stopScrapeEffect(mySession)
	if mySession.ScrapeEffect then
		mySession.ScrapeEffect.Holder:Destroy()
		mySession.ScrapeEffect = nil
	end
end

--=============================================================================
-- Impacts
--=============================================================================

local function onImpact(mySession, deltaV, velocity)
	local chassis = mySession.Chassis
	local carModel = mySession.CarModel

	-- The truck was shoved along +deltaV, so whatever it hit lies along
	-- -deltaV and that surface's normal points back along +deltaV. That guess
	-- is good enough to aim a raycast with, and the raycast is what turns it
	-- into a real normal and a real part.
	local approximateNormal = deltaV.Unit
	local normal = approximateNormal
	local hitPart = nil
	local hitPosition = chassis.Position

	local result = workspace:Raycast(chassis.Position, -approximateNormal * 40, mySession.ImpactParams)
	if result then
		hitPart = result.Instance
		hitPosition = result.Position
		normal = result.Normal
	else
		-- The cast starts at the chassis centre, so a glancing hit or one well
		-- above or below the centre line can miss entirely. Fall back to
		-- whichever thing we're currently touching lies most nearly in the
		-- direction we were shoved from.
		local best, bestDot = nil, -math.huge
		for part in mySession.Contacts do
			local offset = part.Position - chassis.Position
			if offset.Magnitude > 0.05 then
				local dot = offset.Unit:Dot(-approximateNormal)
				if dot > bestDot then
					best, bestDot = part, dot
				end
			end
		end
		if best then
			hitPart = best
			hitPosition = best:GetClosestPointOnSurface(chassis.Position)
		end
	end

	-- Kill the rebound. A truck crashing into a wall folds; it does not spring
	-- back off it. Only the part of the velocity pointing AWAY from the surface
	-- is removed, so a glancing hit still slides along the wall rather than
	-- being stopped dead by this.
	local outwardSpeed = velocity:Dot(normal)
	if outwardSpeed > 0 then
		chassis.AssemblyLinearVelocity = velocity - normal * (outwardSpeed * (1 - VehicleCollision.RestitutionKeep))
	end
	chassis.AssemblyAngularVelocity = chassis.AssemblyAngularVelocity * VehicleCollision.AngularKeepOnImpact

	local impulse = chassis.AssemblyMass * deltaV.Magnitude
	local severityRange = VehicleCollision.ImpactSevereDeltaV - VehicleCollision.ImpactMinDeltaV
	local severity = math.clamp((deltaV.Magnitude - VehicleCollision.ImpactMinDeltaV) / severityRange, 0, 1)

	impactRemote:FireServer(carModel, hitPosition, impulse, hitPart)
	playImpactSound(hitPosition, severity)
end

--=============================================================================
-- Scrapes
--=============================================================================

local function checkScrape(mySession, velocity, delta, now)
	if velocity.Magnitude < VehicleCollision.ScrapeMinTangentSpeed then
		stopScrapeEffect(mySession)
		return
	end

	local chassis = mySession.Chassis
	local bestTangent, bestNormal, bestPosition = 0, nil, nil

	for part in mySession.Contacts do
		local offset = part.Position - chassis.Position
		if offset.Magnitude < 0.05 then
			continue
		end

		-- Cast at just this one part (Include, not Exclude) so the answer is
		-- that surface's normal and nothing else's - the truck's own hulls are
		-- in the way and would otherwise be what we measured.
		mySession.NormalParams.FilterDescendantsInstances = { part }
		local result = workspace:Raycast(chassis.Position, offset.Unit * (offset.Magnitude + 20), mySession.NormalParams)
		if not result then
			continue
		end

		local normal = result.Normal
		-- A scrape is speed ALONG the surface with almost none INTO it. If
		-- we're going into it hard, that's an impact and onImpact has it.
		if math.abs(velocity:Dot(normal)) > VehicleCollision.ScrapeMaxNormalSpeed then
			continue
		end

		local tangentSpeed = (velocity - normal * velocity:Dot(normal)).Magnitude
		if tangentSpeed > bestTangent then
			bestTangent, bestNormal, bestPosition = tangentSpeed, normal, result.Position
		end
	end

	if not bestNormal or bestTangent < VehicleCollision.ScrapeMinTangentSpeed then
		stopScrapeEffect(mySession)
		return
	end

	-- Dragging a flank down a wall should cost speed. Roblox's own friction
	-- would do some of this, but the hull boxes are smooth-sided and the
	-- amount it produces is nowhere near what scraping a truck feels like.
	local tangent = velocity - bestNormal * velocity:Dot(bestNormal)
	if tangent.Magnitude > 0.01 then
		chassis:ApplyImpulse(-tangent.Unit * chassis.AssemblyMass * VehicleCollision.ScrapeDrag * delta)
	end

	updateScrapeEffect(mySession, bestPosition, bestTangent)

	-- The effects above are per-frame and local; only the damage report is
	-- throttled, because that's the part that costs bandwidth and the part the
	-- server rate-limits.
	if now - mySession.LastScrapeReport >= VehicleCollision.ScrapeReportInterval then
		mySession.LastScrapeReport = now
		scrapeRemote:FireServer(mySession.CarModel, bestPosition, bestTangent)
	end
end

--=============================================================================
-- Session
--=============================================================================

local function endSession()
	if not session then
		return
	end
	stopScrapeEffect(session)
	for _, connection in session.Connections do
		connection:Disconnect()
	end
	session = nil
end

local function step(mySession, delta)
	if session ~= mySession then
		return
	end
	local chassis = mySession.Chassis
	if not chassis.Parent then
		endSession()
		return
	end

	local now = os.clock()
	local velocity = chassis.AssemblyLinearVelocity

	-- Gravity's own contribution is subtracted before anything is called a
	-- crash, or every landing after a kerb would read as one.
	local gravityDeltaV = Vector3.new(0, -workspace.Gravity * delta, 0)
	local deltaV = (velocity - mySession.LastVelocity) - gravityDeltaV
	mySession.LastVelocity = velocity

	for part, touchedAt in mySession.Contacts do
		if now - touchedAt > CONTACT_TIMEOUT or part.Parent == nil then
			mySession.Contacts[part] = nil
		end
	end

	if
		deltaV.Magnitude >= VehicleCollision.ImpactMinDeltaV
		and now - mySession.LastImpact >= VehicleCollision.ImpactCooldown
	then
		mySession.LastImpact = now
		onImpact(mySession, deltaV, velocity)
	else
		checkScrape(mySession, velocity, delta, now)
	end
end

local function beginSession(carModel)
	local chassis = carModel.PrimaryPart
	if not chassis then
		return
	end

	endSession()

	local impactParams = RaycastParams.new()
	impactParams.FilterType = Enum.RaycastFilterType.Exclude
	impactParams.FilterDescendantsInstances = { carModel, player.Character }

	local normalParams = RaycastParams.new()
	normalParams.FilterType = Enum.RaycastFilterType.Include

	local mySession = {
		CarModel = carModel,
		Chassis = chassis,
		LastVelocity = chassis.AssemblyLinearVelocity,
		LastImpact = 0,
		LastScrapeReport = 0,
		Contacts = {}, -- [BasePart] = os.clock() of the last Touched
		Connections = {},
		ImpactParams = impactParams,
		NormalParams = normalParams,
		ScrapeEffect = nil,
	}
	session = mySession

	-- Listen on the hull boxes if the car has them, and on the body panels if
	-- it doesn't - i.e. on whatever is actually colliding, which is the same
	-- choice VehicleCollisionSetup made.
	local contactFolder = VehicleCollision.GetHullFolder(carModel) or VehicleCollision.GetBodyFolder(carModel)
	if contactFolder then
		for _, part in contactFolder:GetDescendants() do
			if part:IsA("BasePart") and part.CanCollide and part.CanTouch then
				table.insert(
					mySession.Connections,
					part.Touched:Connect(function(other)
						if other:IsDescendantOf(carModel) then
							return
						end
						-- A panel that has already fallen off this or any other
						-- truck shouldn't be able to re-report itself as a crash.
						if other:GetAttribute(VehicleCollision.DEBRIS_ATTRIBUTE) then
							return
						end
						mySession.Contacts[other] = os.clock()
					end)
				)
				table.insert(
					mySession.Connections,
					part.TouchEnded:Connect(function(other)
						mySession.Contacts[other] = nil
					end)
				)
			end
		end
	end

	table.insert(
		mySession.Connections,
		RunService.PostSimulation:Connect(function(delta)
			step(mySession, delta)
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
	-- wrote to AssemblyLinearVelocity would stick.
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

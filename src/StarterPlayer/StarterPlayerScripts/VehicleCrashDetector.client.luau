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
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
-- Temporary; see the module header. Remove with the rest of the instrumentation.
local VehicleEntryDebug = require(ReplicatedStorage.Modules.Vehicles.VehicleEntryDebug)
local VehicleCrashSounds = require(ReplicatedStorage.Modules.Vehicles.VehicleCrashSounds)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local impactRemote = ReplicatedStorage:WaitForChild("VehicleImpact")
local scrapeRemote = ReplicatedStorage:WaitForChild("VehicleScrape")
local impactSoundRemote = ReplicatedStorage:WaitForChild("VehicleImpactSound")

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

-- Mirror of the server's entry-grace rule (see EntryDamageGrace in
-- VehicleCollision, and validate in VehicleDamage.server.luau). The SERVER is
-- the authority and rejects these reports regardless; this exists only so the
-- client doesn't spend a round trip and a rate-limit slot on a report it
-- already knows will be thrown away.
--
-- Timed off this session's own start rather than off the server's attribute:
-- the two clocks aren't comparable, and the moment this client cares about is
-- the moment IT started measuring - which is exactly when the session began.
local function withinEntryGrace(mySession)
	return (os.clock() - mySession.StartedAt) < VehicleCollision.EntryDamageGrace
end

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

	VehicleEntryDebug.Note(
		"IMPACT deltaV=%.2f impulse=%.0f hit=%s%s",
		deltaV.Magnitude,
		impulse,
		if hitPart then hitPart:GetFullName() else "<nothing>",
		if withinEntryGrace(mySession) then "  [SUPPRESSED - entry grace]" else ""
	)

	-- The rebound kill above still runs during the grace window: that is
	-- honest physics correction, not damage. Only the DAMAGE report and its
	-- crunch are held back.
	if withinEntryGrace(mySession) then
		return
	end

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
		VehicleEntryDebug.Note("SCRAPE tangent=%.1f%s", bestTangent, if withinEntryGrace(mySession) then "  [SUPPRESSED - entry grace]" else "")
		if not withinEntryGrace(mySession) then
			scrapeRemote:FireServer(mySession.CarModel, bestPosition, bestTangent)
		end
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
	-- Nothing is draining this any more, so don't leave a stale reading (or a
	-- reference to the car) behind for the next session to subtract.
	VehiclePhysics.ClearSuspensionDeltaV(session.CarModel)
	VehicleEntryDebug.Finish()
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

	-- Same gate the suspension loop uses (see Raycast.server.luau): until the
	-- server has handed this client network ownership, the velocity being
	-- sampled here is a replicated echo the server is actively overwriting -
	-- it jumps to whatever the server last sent, and the jump has nothing to
	-- do with hitting anything. Keep the sample fresh so the first real frame
	-- differences against the right value, but never judge these frames.
	if mySession.CarModel:GetAttribute("DriveReady") == false then
		VehicleEntryDebug.Frame(mySession.CarModel, {
			Dt = delta,
			DriveReady = false,
			Mass = chassis.AssemblyMass,
			RawDeltaV = velocity - mySession.LastVelocity,
			GravityDeltaV = workspace.Gravity * delta,
		})
		mySession.LastVelocity = velocity
		VehiclePhysics.TrackSuspensionDeltaV(mySession.CarModel)
		return
	end

	-- Gravity's own contribution is subtracted before anything is called a
	-- crash, or every landing after a kerb would read as one.
	local gravityDeltaV = Vector3.new(0, -workspace.Gravity * delta, 0)
	-- ...and so is the suspension's, for exactly the same reason. Gravity and
	-- the ground holding the car up are a matched pair, and subtracting only
	-- one of them left the other in the signal: a car sitting perfectly still
	-- on flat road read a phantom deltaV of `gravity * delta` EVERY frame,
	-- because that is precisely the impulse its springs were applying to
	-- cancel the gravity above. Frame time is the whole problem - the phantom
	-- is 3.3 studs/s at 60fps, 6.5 at 30 and 9.8 at 20, against an
	-- ImpactMinDeltaV of 12 - so on a slow machine ordinary suspension
	-- movement, and in particular the settle when a driver's mass first joins
	-- the assembly, read as a crash and detached bodywork. That is the "the
	-- car exploded the moment I got in" half of the low-frame-rate bug; the
	-- other half is the integration itself, in VehiclePhysics.
	--
	-- Exact, not an allowance: this client is the one that applied those
	-- impulses, so it knows what they were rather than having to guess a
	-- bound. A real collision comes from the contact solver and is untouched
	-- by this.
	local suspensionDeltaV = VehiclePhysics.ConsumeSuspensionDeltaV(mySession.CarModel)
	local rawDeltaV = velocity - mySession.LastVelocity
	local deltaV = rawDeltaV - gravityDeltaV - suspensionDeltaV
	mySession.LastVelocity = velocity

	VehicleEntryDebug.Frame(mySession.CarModel, {
		Dt = delta,
		DriveReady = mySession.CarModel:GetAttribute("DriveReady"),
		Mass = chassis.AssemblyMass,
		RawDeltaV = rawDeltaV,
		GravityDeltaV = gravityDeltaV.Magnitude,
		SuspensionDeltaV = suspensionDeltaV,
		JudgedDeltaV = deltaV.Magnitude,
	})

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
	-- Opts this car in to suspension accounting, and zeroes it: anything left
	-- unread belongs to a different frame and a different drive, and
	-- subtracting it would remove movement that isn't in this session's first
	-- velocity sample either.
	VehiclePhysics.TrackSuspensionDeltaV(carModel)
	VehicleEntryDebug.Begin(carModel)

	local impactParams = RaycastParams.new()
	impactParams.FilterType = Enum.RaycastFilterType.Exclude
	impactParams.FilterDescendantsInstances = { carModel, player.Character }
	-- Defaults to false; see the Touched guard below for why a non-collidable
	-- part must never be treated as something the truck hit.
	impactParams.RespectCanCollide = true

	local normalParams = RaycastParams.new()
	normalParams.FilterType = Enum.RaycastFilterType.Include
	-- Also covers a part that turns non-collidable AFTER its contact opened -
	-- a panel becoming debris, say. The cast simply misses, and checkScrape
	-- skips that contact rather than scraping against a ghost.
	normalParams.RespectCanCollide = true

	local mySession = {
		CarModel = carModel,
		Chassis = chassis,
		StartedAt = os.clock(),
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
						-- Touched fires for non-collidable parts too - it
						-- reports geometric overlap, not physical contact. So
						-- every invisible trigger volume the truck drives
						-- through registers here as something it crashed into;
						-- the vehicle plots' CollisionBoxes (CanCollide =
						-- false by design, see PlotCollisionGuard.server.luau)
						-- are the ones you actually meet while driving. You
						-- cannot crash into something you pass straight
						-- through, so don't let it open a contact.
						if not other.CanCollide then
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

-- Not part of a drive session - this fires for EVERY client, driving or not,
-- so a bystander (or the other car, in a car-vs-car hit) hears the crash too.
-- The reporting player already played this exact sound locally in onImpact
-- above, at zero latency, so it's skipped here rather than played twice.
impactSoundRemote.OnClientEvent:Connect(function(position, severity, reportingPlayer)
	if reportingPlayer == player then
		return
	end
	playImpactSound(position, severity)
end)

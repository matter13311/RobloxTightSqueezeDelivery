-- Takes the driving client's crash reports, checks them, and turns them into
-- damage - which in this game means exactly one thing: cosmetic panels falling
-- off. Nothing here can ever stop a truck driving, by construction (see
-- VehicleCollision.CanDetach).
--
-- Why the client reports at all, when VehicleNetworkState's comment is all
-- about not trusting clients: the driving client OWNS the chassis
-- (Raycast.server.luau hands it network ownership on entry), so its physics
-- state is the real one and the server's copy is a replicated echo a
-- round-trip behind. Measuring a crash on the server would mean measuring the
-- echo. So the client is trusted about the SHAPE of its own crash and not
-- about anything else: how big it was is clamped, how often it can happen is
-- rate-limited, where it happened has to be near the car, and it has to be
-- that car's actual driver asking.

local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
-- Cargo rides on the back of this script's validation rather than listening to
-- the impact remote itself: validate() below is the only place a crash report
-- is checked, and a second listener would mean a second copy of those rules to
-- keep in step. See CargoManager's header.
local CargoManager = require(script.Parent.Modules.CargoManager)

local VehicleFolder = workspace.Vehicles

local impactRemote = Instance.new("RemoteEvent")
impactRemote.Name = "VehicleImpact"
impactRemote.Parent = ReplicatedStorage

local scrapeRemote = Instance.new("RemoteEvent")
scrapeRemote.Name = "VehicleScrape"
scrapeRemote.Parent = ReplicatedStorage

-- Server -> everyone. Fired whenever a car's Condition changes, so a HUD, a
-- smoke emitter or a repair prompt can react without polling the attribute.
local damageRemote = Instance.new("RemoteEvent")
damageRemote.Name = "VehicleDamageChanged"
damageRemote.Parent = ReplicatedStorage

-- Server -> everyone. VehicleCrashDetector.client.luau plays a crash sound
-- the instant the driving client measures an impact, entirely locally, so
-- that one player never waits on a round trip to hear their own crash. This
-- is what makes everyone ELSE hear it too - a bystander, or the other car's
-- driver in a car-vs-car hit, previously heard nothing at all. Carries the
-- reporting player so every client can skip replaying a crash it already
-- played for itself.
local impactSoundRemote = Instance.new("RemoteEvent")
impactSoundRemote.Name = "VehicleImpactSound"
impactSoundRemote.Parent = ReplicatedStorage

-- Loose panels live outside workspace.Vehicles deliberately: Raycast.server's
-- and VehicleDoors' ChildAdded listeners both watch that folder and would try
-- to set a wing mirror up as a car.
local debrisFolder = Instance.new("Folder")
debrisFolder.Name = "VehicleDebris"
debrisFolder.Parent = workspace

local liveDebrisCount = 0

-- Prefixed so the whole crash system can be filtered out of the Output window
-- with a single search. Costs a function call per line when logging is off,
-- which is nothing next to the crash it is describing.
local function log(format, ...)
	if VehicleCollision.DebugLogging then
		print("[Damage] " .. string.format(format, ...))
	end
end

--=============================================================================
-- Validation
--=============================================================================

local reportBuckets = {} -- [Player] = { Count, WindowStart }

local function withinRateLimit(player)
	local bucket = reportBuckets[player]
	local now = os.clock()
	if not bucket or now - bucket.WindowStart >= 1 then
		reportBuckets[player] = { Count = 1, WindowStart = now }
		return true
	end
	bucket.Count += 1
	return bucket.Count <= VehicleCollision.MaxReportsPerSecond
end

Players.PlayerRemoving:Connect(function(player)
	reportBuckets[player] = nil
end)

-- Same driver check VehicleNetworkState uses, and for the same reason: a
-- passenger has no crash of their own to report, and neither does someone
-- standing on the pavement.
local function isDriverOf(player, carModel)
	local seat = VehicleSeats.GetDriverSeat(carModel)
	local occupant = seat and seat.Occupant
	local occupantPlayer = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
	return occupantPlayer == player
end

-- Returns (false, reason) so a silently-dropped report can be logged. A crash
-- that produces no damage looks identical whether the numbers were too small or
-- the report never got past this function, and those have opposite fixes.
local function validate(player, carModel, position, magnitude)
	if typeof(carModel) ~= "Instance" or not carModel:IsA("Model") or carModel.Parent ~= VehicleFolder then
		return false, "not a Model inside workspace.Vehicles"
	end
	if typeof(position) ~= "Vector3" then
		return false, "position was not a Vector3"
	end
	-- magnitude ~= magnitude catches NaN, which clamp would happily pass
	-- through and which would then poison every Health attribute it touched.
	if typeof(magnitude) ~= "number" or magnitude ~= magnitude then
		return false, "magnitude was not a number"
	end
	if magnitude <= 0 or magnitude > VehicleCollision.MaxImpulse then
		return false, string.format("magnitude %.1f is outside 0..%.0f (MaxImpulse)", magnitude, VehicleCollision.MaxImpulse)
	end
	if not VehicleCollision.GetBodyFolder(carModel) then
		return false, "car has no Body folder"
	end
	if not withinRateLimit(player) then
		return false, string.format("rate limit of %d reports/sec exceeded", VehicleCollision.MaxReportsPerSecond)
	end
	if not isDriverOf(player, carModel) then
		return false, "reporting player is not the driver of this car"
	end
	-- A crash has to have happened somewhere near the car that reported it.
	local chassis = carModel.PrimaryPart
	if chassis and (chassis.Position - position).Magnitude > 100 then
		return false, "impact position is more than 100 studs from the chassis"
	end
	return true, nil
end

--=============================================================================
-- Detaching
--=============================================================================

-- Body panels are welded to the chassis by VehiclePhysics.WeldFolderToChassis,
-- which parents each WeldConstraint to the panel itself - but this scans the
-- whole car rather than just the part, so a panel that was ALSO welded to a
-- neighbouring panel in Studio comes fully free instead of staying dangling
-- off its sibling.
--
-- Joints leading to the part's OWN descendants are deliberately spared. A
-- mirror carries its Glass as a welded child (VehicleMirrorViews needs a flat
-- surface to adorn), and body panels often carry trim the same way. Cutting
-- those too would drop the mirror and its glass as two separate objects
-- falling apart in mid-air.
local JOINT_CLASSES = {
	WeldConstraint = true,
	Weld = true,
	ManualWeld = true,
	Motor6D = true,
	Snap = true,
}

local function breakJoints(carModel, part)
	for _, joint in carModel:GetDescendants() do
		if not JOINT_CLASSES[joint.ClassName] then
			continue
		end

		local other
		if joint.Part0 == part then
			other = joint.Part1
		elseif joint.Part1 == part then
			other = joint.Part0
		else
			continue
		end

		if other and other:IsDescendantOf(part) then
			continue -- holds this part's own hardware on; it travels with it
		end
		joint:Destroy()
	end
end

-- Parts that were riding on `part` and are about to have nothing holding them
-- on: a wing mirror mounted on a door panel, say. Their joint to it is cut by
-- breakJoints below, which frees them but leaves them sitting in their original
-- folder - unanchored, untracked, no despawn, and in a mirror's case still
-- rendering a live ViewportFrame on the way down. So they are collected first
-- and detached properly in their own right.
--
-- Descendants of `part` are deliberately not included: those travel WITH it as
-- one object and breakJoints leaves their joints alone.
local function dependentsOf(carModel, part)
	local dependents = {}
	for _, joint in carModel:GetDescendants() do
		if not JOINT_CLASSES[joint.ClassName] then
			continue
		end
		local other
		if joint.Part0 == part then
			other = joint.Part1
		elseif joint.Part1 == part then
			other = joint.Part0
		end
		if other and not other:IsDescendantOf(part) and VehicleCollision.CanDetach(carModel, other) then
			table.insert(dependents, other)
		end
	end
	return dependents
end

local function detach(carModel, part, impactPosition, seen)
	seen = seen or {}
	if seen[part] then
		return -- two parts mounted on each other; don't recurse forever
	end
	seen[part] = true

	local allowed, reason = VehicleCollision.CanDetach(carModel, part)
	if not allowed then
		log("  %s hit 0 health but will NOT detach: %s", part.Name, reason)
		return
	end
	if liveDebrisCount >= VehicleCollision.MaxDetachedParts then
		log("  %s hit 0 health but will NOT detach: debris cap of %d reached", part.Name, VehicleCollision.MaxDetachedParts)
		return -- the cap is a physics budget, not a gameplay rule; the panel just stays on
	end

	log("  DETACHING %s", part.Name)

	-- Collected before the joints are cut, while it is still possible to see
	-- what was mounted on this part.
	local dependents = dependentsOf(carModel, part)

	-- Read the velocity BEFORE breaking anything: once the joints are gone the
	-- part is its own assembly and AssemblyLinearVelocity stops meaning "what
	-- the truck was doing".
	local carriedVelocity = part.AssemblyLinearVelocity

	breakJoints(carModel, part)

	part.Anchored = false
	part.CanCollide = true
	part.CanQuery = false
	part.Massless = false -- it's its own assembly now, so it needs real mass to fall convincingly
	part.CollisionGroup = VehicleCollision.Groups.Debris
	part:SetAttribute(VehicleCollision.DEBRIS_ATTRIBUTE, true)

	-- Anything welded onto it comes along (a mirror's Glass, a panel's trim)
	-- and has to be regrouped too, or the hardware riding on a loose panel
	-- would still be colliding as though it were part of a car.
	for _, child in part:GetDescendants() do
		if child:IsA("BasePart") then
			child.Anchored = false
			child.CollisionGroup = VehicleCollision.Groups.Debris
			child:SetAttribute(VehicleCollision.DEBRIS_ATTRIBUTE, true)
		end
	end

	part.Parent = debrisFolder

	part.AssemblyLinearVelocity = carriedVelocity

	-- A nudge away from the impact, so it visibly leaves the truck rather than
	-- dribbling out of the bodywork at exactly the speed the truck is doing.
	local away = part.Position - impactPosition
	if away.Magnitude < 0.1 then
		away = Vector3.new(math.random() - 0.5, 0.6, math.random() - 0.5)
	end
	part:ApplyImpulse(away.Unit * part.AssemblyMass * (12 + math.random() * 10))
	part:ApplyAngularImpulse(
		Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * part.AssemblyMass * 8
	)

	liveDebrisCount += 1
	log("  %s detached (%d/%d debris parts live, despawns in %ds)", part.Name, liveDebrisCount, VehicleCollision.MaxDetachedParts, VehicleCollision.DetachedLifetime)
	Debris:AddItem(part, VehicleCollision.DetachedLifetime)
	task.delay(VehicleCollision.DetachedLifetime, function()
		liveDebrisCount = math.max(0, liveDebrisCount - 1)
	end)

	-- Whatever was riding on it goes too, however much health it had left - the
	-- thing it was bolted to has just bounced off down the road.
	for _, dependent in dependents do
		log("  %s was mounted on %s, so it goes too", dependent.Name, part.Name)
		detach(carModel, dependent, impactPosition, seen)
	end
end

--=============================================================================
-- Damage
--=============================================================================

-- This car's BodyStrength, the per-car upgradable toughness multiplier (see
-- VehiclePhysics.Defaults and the Upgrades ladders in Configs/). Resolved
-- through GetConfig, so it picks up the Chassis Attribute PlotManager stamps
-- on from the player's purchased level, falls back to the car type's config
-- file for a hand-placed car, and finally to DEFAULTS' 1.
--
-- Anything non-positive would divide damage into nonsense (or by zero), so
-- it is floored - a bad config makes a car ordinary, never invincible.
local function bodyStrengthOf(carModel)
	local chassis = carModel.PrimaryPart
	if not chassis then
		return 1
	end
	local strength = VehiclePhysics.GetConfig(chassis).BodyStrength
	if type(strength) ~= "number" or strength ~= strength or strength <= 0 then
		return 1
	end
	return strength
end

-- Damage falls off linearly to zero at the edge of `radius`, so a hit to the
-- front bumper takes the grille and the headlight surround with it and leaves
-- the tailgate alone. Condition is recomputed across the whole Body folder in
-- the same pass rather than tracked incrementally, so it can't drift.
local function applyDamage(carModel, position, amount, radius)
	local totalHealth, totalMaxHealth = 0, 0
	local damagedCount = 0

	-- Applied by dividing the incoming damage rather than by scaling every
	-- part's MaxHealth. The two are equivalent in what survives a hit, but
	-- this way the Health/MaxHealth attributes stay on the scale the builder
	-- wrote them on, and Condition (totalHealth / totalMaxHealth, and what
	-- the HUD shows) keeps meaning "how intact is this car" rather than
	-- silently rescaling itself when a player buys an upgrade. It also means
	-- an upgrade bought mid-crash-sequence applies from that moment on
	-- instead of retroactively healing panels.
	--
	-- Read once per pass, not per part: every panel on one car shares it, and
	-- this is on the crash path.
	local strength = bodyStrengthOf(carModel)

	for _, part in VehicleCollision.GetDetachableParts(carModel) do
		-- Already knocked off in an earlier crash and now sitting in the debris
		-- folder; GetDetachableParts can't see it, but guard anyway so a part
		-- mid-detach can't be damaged twice in one pass.
		if part:GetAttribute(VehicleCollision.DEBRIS_ATTRIBUTE) then
			continue
		end

		local maxHealth = VehicleCollision.GetMaxHealth(part)
		local health = VehicleCollision.GetHealth(part)

		local distance = (part.Position - position).Magnitude
		if health > 0 and distance <= radius then
			local falloff = 1 - (distance / radius)
			local dealt = amount * falloff / strength
			local before = health
			health = math.max(0, health - dealt)
			part:SetAttribute(VehicleCollision.HEALTH_ATTRIBUTE, health)
			damagedCount += 1
			log(
				"  %-28s %.1f studs away, falloff %.2f, /%.2f strength, -%.1f dmg, health %.1f -> %.1f (max %.0f)",
				part.Name,
				distance,
				falloff,
				strength,
				dealt,
				before,
				health,
				maxHealth
			)
			if health <= 0 then
				detach(carModel, part, position)
			end
		end

		totalHealth += health
		totalMaxHealth += maxHealth
	end

	if damagedCount == 0 then
		log(
			"  NOTHING DAMAGED - no damageable part within %.0f studs of the impact still had health. Widen DamageRadius, or check the impact position is where you think it is.",
			radius
		)
	end

	if totalMaxHealth > 0 then
		local condition = totalHealth / totalMaxHealth
		carModel:SetAttribute(VehicleCollision.CONDITION_ATTRIBUTE, condition)
		damageRemote:FireAllClients(carModel, position, condition)
	end
end

-- The car (if any) that a hit part belongs to. Walks up rather than checking
-- Parent, because the part reported is a hull box or a panel several folders
-- deep, not a direct child of the car.
local function carModelFromPart(part)
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model.Parent == VehicleFolder then
			return model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

--=============================================================================
-- Remotes
--=============================================================================

impactRemote.OnServerEvent:Connect(function(player, carModel, position, impulse, hitPart)
	local ok, reason = validate(player, carModel, position, impulse)
	if not ok then
		log("IMPACT REJECTED from %s: %s", player.Name, reason)
		return
	end

	local amount = impulse * VehicleCollision.DamagePerImpulse
	log(
		"IMPACT on %s - hit %s, impulse %.0f, x DamagePerImpulse %.4f = %.1f damage at the centre",
		carModel.Name,
		if typeof(hitPart) == "Instance" then hitPart:GetFullName() else "<nothing>",
		impulse,
		VehicleCollision.DamagePerImpulse,
		amount
	)
	applyDamage(carModel, position, amount, VehicleCollision.DamageRadius)

	-- Same 0-1 scale CargoManager.ApplyImpact uses just below - impulse as a
	-- fraction of the largest one validate() will accept - so a bystander's
	-- copy of the crash sound is scaled the same way the reporting client
	-- scaled its own local one (see severity in VehicleCrashDetector's
	-- onImpact), without the server needing to know deltaV at all.
	local severity = math.clamp(impulse / VehicleCollision.MaxImpulse, 0, 1)
	impactSoundRemote:FireAllClients(position, severity, player)

	-- ...and the same crash, applied to whatever is in the bed. Severity is
	-- the impulse as a fraction of the largest one validate() will accept, so
	-- CargoTypes' Fragility numbers are calibrated against a known 0-1 scale
	-- rather than against raw impulses whose range depends on vehicle mass.
	CargoManager.ApplyImpact(carModel, impulse / VehicleCollision.MaxImpulse)

	-- Hitting another player's truck damages theirs too. Halved because only
	-- one of the two clients is going to report this crash (whichever one was
	-- doing the hitting), and both cars taking the full amount from a single
	-- report would make car-vs-car twice as destructive as hitting a wall at
	-- the same speed.
	if typeof(hitPart) == "Instance" and hitPart:IsA("BasePart") then
		local otherCar = carModelFromPart(hitPart)
		if otherCar and otherCar ~= carModel then
			applyDamage(otherCar, position, amount * 0.5, VehicleCollision.DamageRadius)
			-- Halved for the same reason the panel damage is: only one of the
			-- two clients reports this crash, and the driver who got hit
			-- should not lose a full load's worth of condition to a collision
			-- they may not have caused.
			CargoManager.ApplyImpact(otherCar, (impulse * 0.5) / VehicleCollision.MaxImpulse)
		end
	end
end)

scrapeRemote.OnServerEvent:Connect(function(player, carModel, position, tangentSpeed)
	local ok, reason = validate(player, carModel, position, tangentSpeed)
	if not ok then
		log("SCRAPE REJECTED from %s: %s", player.Name, reason)
		return
	end

	-- Grinding takes paint off. The rate is per SECOND and the client reports
	-- every ScrapeReportInterval, so multiplying by the interval is what keeps
	-- the damage tied to how long you scraped rather than to how chatty the
	-- client happened to be. Capped at 2x so an absurd reported speed can't
	-- strip a truck in one message.
	local amount = VehicleCollision.ScrapeDamageRate
		* VehicleCollision.ScrapeReportInterval
		* math.clamp(tangentSpeed / 40, 0, 2)
	log("SCRAPE on %s - %.1f studs/s along the surface, %.2f damage", carModel.Name, tangentSpeed, amount)
	applyDamage(carModel, position, amount, VehicleCollision.DamageRadius * 0.5)
end)

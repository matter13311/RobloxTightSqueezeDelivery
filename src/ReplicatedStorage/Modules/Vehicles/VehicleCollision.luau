-- The shared rules and tuning for crashing a car into things. Shared for the
-- same reason VehicleOwnership is: the driving client MEASURES the crash (it
-- owns the chassis, so it's the only machine with accurate numbers) and the
-- server DECIDES what the crash costs, and both have to agree on what counts
-- as a crash in the first place or the two halves drift apart.
--
-- Two things a car can do to the world, and they need separating because they
-- want completely different responses:
--
--   IMPACT  - a sudden loss of speed. Measured as the velocity the assembly
--             sheds in a SINGLE physics step, not as raw speed. A truck doing
--             100 studs/s down a straight is not a crash; a truck losing 40
--             studs/s in one 60th of a second is. This is the only measure
--             that works, because Roblox exposes no contact-force API at all.
--
--   SCRAPE  - sustained contact with speed ALONG a surface and almost none
--             INTO it. Dragging a flank down a wall while threading a gap,
--             which for this game is going to happen constantly.
--
-- The structural rule (what may fall off) lives here too rather than in the
-- damage script, so the client can grey out or skip parts it knows are never
-- going to detach instead of re-deriving that rule its own way.

local VehicleCollision = {}

--=============================================================================
-- Folder layout
--=============================================================================

-- Invisible boxes that are the car's REAL shape. See BuildCollisionHulls in
-- tools/ for why this folder exists at all: a MeshPart's collision hull is not
-- its mesh, and two cars' hull errors stack, which is why one car's bumper
-- sinks into another car's door but stops dead against a building wall.
VehicleCollision.HULL_FOLDER = "Collision"

-- Cosmetic panels, doors included now that they are welded rather than hinged.
-- Also the folder every other script uses to recognise a set-up car, which is
-- why it stays named on its own rather than being folded into the list below.
VehicleCollision.BODY_FOLDER = "Body"

-- The folders damage is allowed to touch, and the only places a part can ever
-- fall off from. Wheels, Lights, Engine, the seats, the frame and the Chassis
-- itself are all absent on purpose: no amount of damage can leave a truck
-- undriveable or stranded, by construction rather than by tuning.
--
-- Losing a door is purely cosmetic now that doors don't open - you get in and
-- out by teleport, and the way in is defined by the Exit attachments on the
-- chassis, not by the panel. Losing a mirror costs you that mirror's view,
-- which is a real gameplay consequence in a game about reversing into tight
-- spaces, and is meant to be.
VehicleCollision.DETACHABLE_FOLDERS = { "Body", "Mirror" }

--=============================================================================
-- Collision groups
--=============================================================================

-- The rule Roblox actually follows: parts rigidly joined together (welds,
-- WeldConstraints, Motor6Ds) form ONE assembly, and two parts in the same
-- assembly NEVER collide with each other however badly they overlap. Two parts
-- in DIFFERENT assemblies collide normally.
--
-- This is what the doors used to violate. A HingeConstraint does not join parts
-- into one assembly - that is the point of a hinge - so each door was its own
-- body, and a door overlapping a flank hull was two separate bodies trying to
-- hold one piece of ground. The solver shoved them apart, the servo dragged
-- the door back, and the truck shook itself to bits. Doors are plain welded
-- panels now (see VehicleDoors.server.luau) so that particular case is gone.
--
-- The grouping stays, because the RULE is what protects the car, not the fix
-- to one instance of it. It is a WHITELIST, not a list of exceptions: Vehicle
-- holds the hulls and the chassis, which together ARE the car's shape, and
-- everything else on the vehicle goes in Attached and simply cannot touch it.
-- Listing exceptions instead means the truck comes apart again the next time
-- an unwelded prop is bolted on, with a symptom (violent shaking) that looks
-- nothing like its cause.
VehicleCollision.Groups = {
	Vehicle = "Vehicle", -- hull boxes + chassis: the car's real shape, and the only things that collide as the car
	Cosmetic = "VehicleCosmetic", -- body mesh parts once hulls exist: collide with nothing at all
	Attached = "VehicleAttached", -- doors, mirrors, seats, frame, steering wheel, wheels: collide with the world, never with vehicle geometry
	Debris = "VehicleDebris", -- knocked-off panels: bounce on the ground, never shove a car
}

--=============================================================================
-- Impact detection
--=============================================================================

-- Velocity lost in one physics step, in studs/s. Below Min, ignored - kerbs,
-- potholes and suspension landings all produce a few studs/s of this and none
-- of them are crashes.
--
-- TUNING: crashes not registering, raise nothing - LOWER Min. Speed bumps
-- setting off the crash sound, raise it. Severe is only a scale endpoint (it's
-- what maps to severity = 1), so moving it changes how quickly damage ramps,
-- not whether anything is detected.
VehicleCollision.ImpactMinDeltaV = 12
VehicleCollision.ImpactSevereDeltaV = 45
VehicleCollision.ImpactCooldown = 0.12 -- seconds; one crash is several frames of contact, and should be reported once

--=============================================================================
-- Bounce suppression
--=============================================================================

-- Fraction of the rebound the car is allowed to keep. A real car crashing into
-- a wall does not bounce off it: the kinetic energy goes into folding metal,
-- which is a perfectly inelastic collision. 0 is that; 1 is a superball.
--
-- Note this is the ACTIVE half of the fix. The passive half is setting
-- Elasticity to 0 at a high ElasticityWeight on every car part (see
-- VehicleCollisionSetup), which stops most of the bounce before the solver
-- ever produces it. Neither alone is enough: the weight only wins the contact
-- against whatever the wall is made of, it doesn't stop the solver adding
-- separation velocity of its own to resolve penetration.
VehicleCollision.RestitutionKeep = 0.05

-- Spin kept after an impact. Without this, clipping a lamp post at the corner
-- of the bumper spins a 2-tonne truck like a top.
VehicleCollision.AngularKeepOnImpact = 0.4

--=============================================================================
-- Scrape detection
--=============================================================================

VehicleCollision.ScrapeMinTangentSpeed = 8 -- studs/s along the surface before it counts as grinding
VehicleCollision.ScrapeMaxNormalSpeed = 6 -- studs/s into the surface; above this it's an impact, not a scrape
VehicleCollision.ScrapeDrag = 14 -- studs/s^2 bled off while grinding. Dragging a flank down a wall SHOULD cost you speed
VehicleCollision.ScrapeReportInterval = 0.25 -- seconds between reports to the server; the effects themselves are per-frame and local

--=============================================================================
-- Damage
--=============================================================================

-- Impulse (AssemblyMass * deltaV) -> hit points. Deliberately tiny, because
-- this truck's chassis mass is in the hundreds and the impulse numbers that
-- come out of a real crash are in the tens of thousands.
--
-- TUNING: work backwards from what you want. A panel with the default 100
-- health should survive roughly (100 / DamagePerImpulse / chassisMass) studs/s
-- of accumulated deltaV before it comes off.
VehicleCollision.DamagePerImpulse = 0.0015
VehicleCollision.DamageRadius = 12 -- studs from the impact point; damage falls off linearly to zero at the edge

-- Health for any Body part without its own MaxHealth attribute. THIS is the
-- global "how easily do panels come off" knob - halve it and everything falls
-- off twice as readily.
--
-- Per part, set a MaxHealth attribute in Studio to override it: a wing mirror
-- at 15 should be gone the first time you clip a bollard, a door skin at 300
-- should survive several real crashes. Setting MaxHealth is the right tool for
-- "this specific thing is too tough"; this number is the right tool for
-- "nothing ever comes off".
--
-- Note the two knobs are redundant with DamagePerImpulse above - halving this
-- and doubling that produce the identical result. Pick one and leave the other
-- alone, or you will end up chasing your own tail.
VehicleCollision.DefaultPartHealth = 3
VehicleCollision.ScrapeDamageRate = 0.5 -- hit points per second of grinding, before the speed scale. Paint, not panels

VehicleCollision.MaxDetachedParts = 30 -- world-wide cap on loose debris, so a demolition derby can't fill the physics budget
VehicleCollision.DetachedLifetime = 20 -- seconds before a knocked-off panel despawns

--=============================================================================
-- Debug logging
--=============================================================================

-- Turn on to have VehicleDamage print, per crash: what was hit, how much
-- damage each panel took, its health before and after, and - when a panel
-- reaches zero - whether it actually came off and if not, why not.
--
-- Also logs every report the server THREW AWAY and the reason. That half
-- matters as much as the other: a crash that produces no damage looks
-- identical whether the numbers were too small or the report never passed
-- validation, and those have opposite fixes.
--
-- Noisy by design. Turn it off once the numbers are tuned.
VehicleCollision.DebugLogging = true

--=============================================================================
-- Anti-cheat
--=============================================================================

-- The driving client is trusted about its own crash because it genuinely is
-- the authority - it owns the chassis, so its numbers ARE the simulation. What
-- it is NOT trusted about is scale or frequency, hence these.
VehicleCollision.MaxReportsPerSecond = 15
VehicleCollision.MaxImpulse = 5e6

--=============================================================================
-- Attributes
--=============================================================================

-- Per-part, set in Studio on anything inside Body:
--   MaxHealth (number)  - punishment before it comes off. A mirror might be 15,
--                         a door skin 300. Defaults to DefaultPartHealth.
--   NoDetach  (boolean) - never comes off, whatever happens to it.
-- Per-part, set by the damage script at runtime:
--   Health    (number)  - what's left.
--   IsDebris  (boolean) - marks a part that has already fallen off.
-- Per-car, set by the damage script:
--   Condition (number)  - 0..1 across the whole Body folder. Hook a HUD to it.
VehicleCollision.HEALTH_ATTRIBUTE = "Health"
VehicleCollision.MAX_HEALTH_ATTRIBUTE = "MaxHealth"
VehicleCollision.NO_DETACH_ATTRIBUTE = "NoDetach"
VehicleCollision.DEBRIS_ATTRIBUTE = "IsDebris"
VehicleCollision.CONDITION_ATTRIBUTE = "Condition"

function VehicleCollision.GetHullFolder(carModel)
	return carModel:FindFirstChild(VehicleCollision.HULL_FOLDER)
end

function VehicleCollision.GetBodyFolder(carModel)
	return carModel:FindFirstChild(VehicleCollision.BODY_FOLDER)
end

function VehicleCollision.GetMaxHealth(part)
	local max = part:GetAttribute(VehicleCollision.MAX_HEALTH_ATTRIBUTE)
	return if type(max) == "number" then max else VehicleCollision.DefaultPartHealth
end

function VehicleCollision.GetHealth(part)
	local health = part:GetAttribute(VehicleCollision.HEALTH_ATTRIBUTE)
	return if type(health) == "number" then health else VehicleCollision.GetMaxHealth(part)
end

-- The one question both sides ask, and the guarantee that damage can never
-- render a truck un-driveable: cosmetic Body panels only, never the Chassis,
-- never a wheel, never a door, never a light, and never anything a builder has
-- explicitly pinned down with NoDetach.
--
-- Every part damage may touch, across all DETACHABLE_FOLDERS. Used both to
-- apply damage and to total up a car's Condition, so the two can never
-- disagree about which parts count.
function VehicleCollision.GetDetachableParts(carModel)
	local parts = {}
	for _, folderName in VehicleCollision.DETACHABLE_FOLDERS do
		local folder = carModel:FindFirstChild(folderName)
		if folder then
			for _, part in folder:GetDescendants() do
				if part:IsA("BasePart") then
					table.insert(parts, part)
				end
			end
		end
	end
	return parts
end

-- Returns (false, reason) rather than a bare false so the damage log can say
-- WHY a part that reached zero health is still bolted on - which is otherwise
-- indistinguishable from the damage never having been applied at all.
function VehicleCollision.CanDetach(carModel, part)
	if part == carModel.PrimaryPart then
		return false, "it is the car's PrimaryPart (the Chassis)"
	end
	if part:GetAttribute(VehicleCollision.NO_DETACH_ATTRIBUTE) == true then
		return false, "it has the NoDetach attribute set"
	end
	for _, folderName in VehicleCollision.DETACHABLE_FOLDERS do
		local folder = carModel:FindFirstChild(folderName)
		if folder and part:IsDescendantOf(folder) then
			return true, nil
		end
	end
	return false, "it is not inside " .. table.concat(VehicleCollision.DETACHABLE_FOLDERS, " or ")
end

return VehicleCollision

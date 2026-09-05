-- Shared raycast suspension physics for all vehicles. Used by both the
-- server (simulates parked cars, holding them at ride height when nobody's
-- driving) and the driving player's own client (simulates the one car they
-- currently have network ownership of). This is the single source of truth
-- for the suspension/grip/drive math - previously the server and client
-- each had their own hand-copied version of this loop, which is exactly the
-- kind of thing that quietly drifts out of sync (see WheelSuspensionLengthMemory).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- One-way dependency: CargoLoad knows nothing about this module, so there is
-- no cycle. It is required here only for the handling penalty a load applies -
-- see the two call sites in Step.
local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)

local VehiclePhysics = {}

local WHEEL_NAMES = { "FL", "FR", "RL", "RR" }
VehiclePhysics.WheelNames = WHEEL_NAMES

-- studs/s below which a stopped car is treated as genuinely stopped, and the
-- low-speed brake controller stops correcting entirely. Without a deadzone it
-- keeps chasing float noise forever, which reads as a permanent fine jitter.
local REST_VELOCITY_EPSILON = 0.1

-- Base defaults every car falls back to if nothing else overrides a value.
local DEFAULTS = {
	-- 2 empirically holds ground contact reliably - 1.3 was just barely too
	-- short, letting the wheel flicker grounded/ungrounded on marginal
	-- frames (zero suspension force applied on a "miss" frame), which shows
	-- up as visible jitter, most noticeably lateral.
	SuspensionMaxLength = 2,
	WheelRadius = 1.5,
	Stiffness = 100,
	Damper = 5,
	LateralGripStrength = 1.5, -- friction coefficient (like a real tire, roughly 0.7-1.5 is a normal grippy range) - the max sideways g-force this wheel's grip can generate. Applies to whichever axle doesn't have its own Front/RearLateralGripStrength override. Raised from 1 for more margin before an ordinary turn trips the binary grip/no-grip model
	DriveWheels = "All", -- "All", "Front", or "Rear" - which axle receives drive/brake force from the throttle
	WheelSpinBoost = 0, -- 0 = off. Extra visual wheel-spin speed under throttle at low speed, for a burnout/wheelspin look on drive wheels
	Torque = 10,
	MaxSpeed = 50,
	SteerAngle = 45,

	-- How fast the steering moves, in "steer units per second" - the input is
	-- -1..1, so a value of 5 reaches full lock in 1/5 of a second. This is
	-- steering FEEL, entirely separate from SteerAngle above, which is how far
	-- the road wheels actually point at full lock. Lower = heavier, slower,
	-- more deliberate; the difference between a go-kart and a loaded truck.
	SteerSpeed = 5,
	SteerReturnSpeed = 8, -- letting go re-centres faster than turning in does, the way a real car's castor pulls the wheel straight on its own

	-- The steering wheel PROP in the cab (see GetSteeringWheelPart). Degrees
	-- it rotates at full lock. Games usually use something tiny like 30, which
	-- looks obviously fake; a real car is more like 450 (1.25 turns) each way.
	-- 180 is the compromise: unmistakably a wheel being turned, without
	-- spinning wildly in first person every time you tap A.
	SteeringWheelMaxAngle = 180,
	-- Which axis the wheel spins about. "Auto" works this out from the part
	-- itself and is almost always right: a steering wheel is a flat disc, so
	-- the column necessarily runs through its THINNEST dimension. There is
	-- nothing else it could be.
	--
	-- Set an explicit Vector3 only if Auto guesses wrong (a wheel whose part
	-- is not disc-shaped - a cube-ish bounding box, or a Model whose
	-- PrimaryPart is a hub rather than the rim). If you do, note that it is in
	-- the PART'S OWN local space, NOT world space. This trips people up:
	-- Studio's rotate handles default to World, where red is the world X axis,
	-- but a steering wheel is mounted on a tilted column so its local axes do
	-- not line up with the world's. Switch Studio to Local axis mode before
	-- reading a colour off the handles - red/green/blue are then X/Y/Z here.
	SteeringWheelAxis = "Auto",
	SteeringWheelInvert = false, -- flip if the wheel spins the correct way round its column but in the wrong direction. Kept separate from the axis on purpose, so getting the direction wrong never means second-guessing the axis

	-- Traction loss. Used ONLY to drive the screech and smoke effects - none
	-- of it feeds back into the physics, so tuning these can't change how the
	-- car actually handles.
	--
	-- A tire counts as slipping when its contact patch is sliding across the
	-- ground faster than TractionSlipThreshold. Both gates exist to suppress
	-- movement that is technically slip but obviously shouldn't make a noise:
	TractionSlipThreshold = 7, -- studs/s the patch must be sliding. Ordinary cornering always slips a little; this is the line between "a tire working" and "a tire letting go"
	TractionMinCarSpeed = 10, -- studs/s the CAR must be doing before any slip counts. This is what stops a car parked on a slope and creeping sideways from screeching forever - it genuinely is sliding, but nobody would expect a sound
	TireScreechSoundId = "rbxassetid://109487442763183",
	TireScreechVolume = 0.55,
	-- 0-1: fraction of a full stop applied per frame once braking. 1 (fully
	-- instant, every frame, no gradualness) is a bang-bang controller with no
	-- settling room - any tiny nudge from elsewhere (suspension force not
	-- being perfectly vertical, float noise) gets fully snapped back to zero
	-- based on that instant's reading, then re-appears and gets snapped back
	-- again next frame - a real, visible jitter, not just an edge case.
	BrakeStrength = 0.3,
	-- Drag applied when you lift off the gas above CoastSpeedThreshold, as
	-- the FRACTION OF SPEED SHED PER SECOND: 0.08 means the car bleeds ~8% of
	-- its speed each second, so it holds a cruise for a long time instead of
	-- slowing the moment you stop pressing W. 1/CoastDrag is roughly the
	-- seconds it takes to shed most of the speed, so lower = more coasting.
	--
	-- This used to be a raw per-FRAME impulse, which made it two things it
	-- should never have been: framerate-dependent (a 120fps client coasted
	-- half as far as a 60fps one) and mass-dependent (the same 0.5 shed 12%
	-- per second on a light chassis and 1% on a heavy one). It is now scaled
	-- by mass and by delta, so both of those cancel out and the number means
	-- the same thing on every car and every machine.
	CoastDrag = 0.08,
	CoastSpeedThreshold = 3, -- studs/s
	-- 0-1: how far down the tire forces (grip + drive/brake) are applied.
	-- 1 = at the tire's actual ground contact patch, which is what gives the
	-- body a moment arm about its centre of mass, and therefore squat under
	-- power, dive under braking and roll in a turn. 0 = at the strut mount
	-- (roughly hub height), which leaves almost no moment arm and drives
	-- dead flat like a gokart no matter how soft the spring is. Anything
	-- between scales how pronounced the lean is - this is a feel knob, not a
	-- correctness one, so a deliberately arcadey car can turn it down.
	BodyLean = 1,

	-- Foot brake (S). A friction coefficient like LateralGripStrength, not a
	-- 0-1 fraction: the most decelerating force one tire can put down is
	-- BrakeFriction * that tire's share of the car's weight. Brakes act on
	-- every wheel, not just the driven axle, and the force is applied at the
	-- contact patch, so hard braking pitches the nose down.
	--
	-- The mass cancels out, which makes this directly tunable by feel:
	--     deceleration   = BrakeFriction * workspace.Gravity   (studs/s^2)
	--     stopping distance from v = v^2 / (2 * BrakeFriction * Gravity)
	-- At the default Gravity of 196.2, BrakeFriction 0.6 stops a car from
	-- 100 studs/s in 0.85s over 42 studs. Values near 1.5+ stop inside a car
	-- length and read as hitting a wall, not braking.
	--
	-- Keep this above HandbrakeLockFriction/2 (the handbrake only locks one
	-- axle, so its deceleration is halved) or the handbrake out-brakes the
	-- brake pedal, which feels backwards to drive.
	BrakeFriction = 0.3,
	BrakeRampTime = 0.3, -- seconds for the pedal to travel from released to fully applied. S is a digital key, so without this a tap is indistinguishable from standing on the brake

	-- The same idea for the gas, and the cure for a car that LURCHES off the
	-- line. A digital key means full torque arrives on a single frame, and at
	-- a standstill that torque is multiplied by the torque converter's stall
	-- factor - so the worst spike in the whole drivetrain lands at exactly the
	-- moment the car is least able to absorb it.
	--
	-- Ramping the throttle in fixes the lurch WITHOUT giving up the shove,
	-- which is the point: pulling away on the flat, the car is already moving
	-- (and the converter already fading) by the time full torque arrives, so
	-- the spike never happens. Pushing against a kerb, nothing moves, you hold
	-- the key for longer than the ramp anyway, and you still get every bit of
	-- the force. Releasing is instant, so lifting off still cuts power at once.
	ThrottleRampTime = 0.35,

	-- Handbrake (Space). Deliberately NOT a stronger foot brake: it locks its
	-- axle's wheels, and a locked tire is a sliding one. That means two
	-- separate things, and the second is the whole point:
	HandbrakeWheels = "Rear", -- "All", "Front" or "Rear" - which axle the handbrake locks. Rear is what makes the back step out
	HandbrakeLockFriction = 0.5, -- sliding friction of a locked tire along its rolling direction. This is PER LOCKED WHEEL, and the handbrake only locks one axle, so the car-wide deceleration it produces is half this - compare BrakeFriction directly against HandbrakeLockFriction/2, not against the raw number
	HandbrakeGripMultiplier = 0.18, -- what fraction of its normal LateralGripStrength a locked wheel keeps. A tire already sliding lengthwise has almost nothing left to resist sideways with - this is the number that actually makes the car break loose and skid when you yank it mid-corner at speed

	-- Sound assets. Per-car so a different vehicle can have its own, but they
	-- default to the shared ones so a new car needs no audio setup at all.
	HandbrakeSoundId = "rbxassetid://105954464235496",
	GearShiftSoundId = "rbxassetid://13331481802", -- the automatic box changing gear inside D, heard constantly while driving - hence the low volume
	SelectorSoundId = "rbxassetid://5565325193", -- the driver moving the R/N/D lever with Q/E. A deliberate action, so it stays louder and more mechanical than the automatic shifts above
	ShiftSoundVolume = 0.25,
	SelectorSoundVolume = 0.5,
	HandbrakeSoundVolume = 0.6,

	-- Crash damage. A multiplier on how much punishment the bodywork takes
	-- before panels detach, applied in VehicleDamage.server.luau: 1 is the
	-- baseline every part's health is written against (see
	-- VehicleCollision.DefaultPartHealth), 2 makes every panel last twice as
	-- long. It is here rather than in VehicleCollision because it is per-car
	-- tuning and an upgradable stat, where that module's DefaultPartHealth /
	-- DamagePerImpulse are the game-wide knobs behind it.
	--
	-- Purely cosmetic, like all damage in this game - it cannot make a car
	-- more driveable, and it does NOT shield the cargo, which carries its own
	-- separate condition and is what actually decides a delivery's payout.
	BodyStrength = 1,

	-- The horn (H). Unlike every other sound listed above, this one is NOT
	-- created or played by the driving client - it is a Sound the SERVER puts
	-- on the Chassis and plays, so every player in the game hears it, coming
	-- from the car that honked. See VehicleHorn.server.luau.
	--
	-- Looped while the key is held, so a short "beep" recording sustains into
	-- a lean-on-the-horn if you keep H down. Volume/rolloff are deliberately
	-- higher than the in-cab sounds: a horn is meant to carry to other
	-- players, not just to the person pressing it.
	HonkSoundId = "rbxassetid://127513531122725",
	HonkSoundVolume = 1,
	HonkSoundRollOffMaxDistance = 250,

	-- Cargo. How many crates the bed holds, how heavy each one is, and how
	-- much worse the truck handles for carrying them. See
	-- docs/CargoDesign.md, and CargoLoad.luau's header for why a handling
	-- penalty is applied at all when we are already adding real mass (short
	-- version: mass cancels out of both the brake and grip math below, so a
	-- fully loaded truck would otherwise stop and corner exactly like an
	-- empty one).
	--
	-- Defaults are deliberately a no-op: capacity 0 means a car that has said
	-- nothing about cargo simply cannot carry any, and every multiplier here
	-- is 1 so an unloaded or non-cargo vehicle drives byte-for-byte the way it
	-- did before cargo existed.
	CargoCapacity = 0,
	CargoMassFractionPerUnit = 0, -- mass per crate, as a fraction of the vehicle's own EMPTY mass - see CargoLoad.AddedMass for why it isn't an absolute figure
	CargoLoadedBrakeMultiplier = 1, -- BrakeFriction multiplier at 100% load. Deceleration is BrakeFriction * gravity, so 0.7 here is a 43% longer stopping distance
	CargoLoadedGripMultiplier = 1, -- lateral grip multiplier at 100% load. Below 1 the tires break away sooner in a corner
}
VehiclePhysics.Defaults = DEFAULTS

-- Transmission tuning. Unlike everything in DEFAULTS this is a nested table,
-- so it can't come from an Attribute (Attributes can't hold tables) - it's
-- config-file-only, and a car's Configs/<name>.luau overrides it key by key
-- (so a car can specify just `Gears` and inherit the shift timing here).
--
-- Each forward gear is { Ratio, SpeedFraction }:
--   Ratio         torque multiplier applied on top of config.Torque. A low
--                 gear multiplies torque a lot but is geared short, so it
--                 runs out of pull almost immediately - that's the tradeoff
--                 that makes a gearbox feel like one rather than a free
--                 power boost.
--   SpeedFraction the share of config.MaxSpeed this gear tops out at, 0-1.
--                 Drive force fades to zero as the car approaches it, exactly
--                 like the single-speed model used to do against MaxSpeed.
--                 The LAST gear should be 1.0, or the car can never reach its
--                 own MaxSpeed.
local DEFAULT_TRANSMISSION = {
	StartingGear = "D", -- "R" or "D" - what the car is in when you sit down. There is no neutral: the direction is chosen automatically from the keys, so a gear the player can't select and can't leave would only ever read as the car being broken

	-- Automatic direction change. There is no gear lever - S brakes the car,
	-- and only once it is fully stopped AND S is STILL held for this long does
	-- the car drop into reverse (and the same the other way, holding W to go
	-- back into drive). The timer only counts while the car is stopped, so
	-- braking from speed always brakes first.
	--
	-- Too short and braking to a halt at a delivery point flings you
	-- backwards before you've let go; too long and reversing out of somewhere
	-- feels unresponsive. Half a second is deliberate without being a wait.
	AutoReverseDelay = 0.5,
	StoppedSpeed = 1.5, -- studs/s under which the car counts as "stopped" for that flip. Must be above the speed the low-speed brake controller settles at, or the flip can never trigger
	ShiftTime = 0.35, -- seconds an automatic upshift/downshift takes. Drive torque is cut to zero for this whole window, which is the pause you hear and feel between gears
	-- Upshift once speed reaches this fraction of the CURRENT gear's top
	-- speed. Not as late as it looks: drive force fades linearly to zero at
	-- a gear's top speed, so with these ratios the next gear already
	-- out-pulls the current one from about 0.5 onwards. Shifting a little
	-- past that (0.62) means each gear is still visibly pulling when it
	-- hands over, and the new gear picks up harder than the old one was -
	-- which is what a shift should feel like. Push this near 1.0 and the car
	-- crawls to every shift point on the 5% of torque it has left there.
	ShiftUpAt = 0.62,
	ShiftDownAt = 0.42, -- downshift once speed falls below this fraction of the NEXT GEAR DOWN's top speed. Must stay clearly below ShiftUpAt - the gap between them is the whole hysteresis band, and without one the box hunts up and down every other frame at a steady throttle
	IdleRpm = 0.12, -- 0-1 floor, so a stopped engine still idles rather than going silent
	ShiftRpmDrop = 0.55, -- revs fall to this fraction mid-shift (clutch out, engine unloaded) and pick back up in the new gear - the audible "wah-WAH" of shifting
	RpmSmoothing = 6, -- per-second rate the audible revs chase their target. Higher snaps faster
	IdlePitch = 0.7, -- engine sound PlaybackSpeed at 0 revs...
	-- ...and at redline. PlaybackSpeed 1.0 is the sound file's own recorded
	-- pitch, so anything much above ~1.5 is resampling the engine loop far
	-- past what it was recorded at and starts to sound thin and synthetic.
	-- This is the knob for "the engine screams before it shifts" - lower it.
	MaxPitch = 1.45, -- ...and at redline. The sound now tracks REVS, not road speed, so it climbs through a gear and drops on each shift instead of rising once from a standstill to top speed
	-- Torque converter, and the reason a heavy vehicle can pull away up a
	-- curb without also accelerating like a sports car once it's rolling.
	-- Torque is multiplied by StallTorqueMultiplier at a dead standstill and
	-- fades to 1x by StallSpeed. That splits two things the raw Torque number
	-- could not separate before: how hard the car can shove from rest (set by
	-- Torque * gear ratio * this) and how briskly it gains speed afterwards
	-- (set by Torque * gear ratio alone). Want slow, deliberate acceleration
	-- but enough grunt to climb a kerb? Lower Torque and raise this.
	StallTorqueMultiplier = 3,
	StallSpeed = 3, -- studs/s over which the multiplication fades out. Keep this well under the first upshift, or the boost carries the car most of the way through 1st gear and 1st feels like it never happened

	Gears = {
		{ Ratio = 2.6, SpeedFraction = 0.24 },
		{ Ratio = 1.7, SpeedFraction = 0.45 },
		{ Ratio = 1.25, SpeedFraction = 0.7 },
		{ Ratio = 1.0, SpeedFraction = 1.0 },
	},
	Reverse = { Ratio = 2.4, SpeedFraction = 0.28 }, -- single reverse gear: geared short, so backing up is torquey but slow
}
VehiclePhysics.DefaultTransmission = DEFAULT_TRANSMISSION

-- Per-car-TYPE tuning lives in ModuleScripts under Configs/, one file per car
-- type (e.g. Configs/PickupTruck.luau), each returning a table of only the
-- values that differ from DEFAULTS. A car picks up its config automatically
-- by matching its Model's Name to a file of the same name - so a car named
-- "PickupTruck" in workspace.Vehicles automatically uses
-- Configs/PickupTruck.luau, no attribute-setting required. Set a "ConfigName"
-- attribute on the Chassis to use a different config file than the model's
-- own name - which is what PlotManager does for every terminal-spawned car,
-- so vehicle identity (VehicleCatalog.Id) and physics config identity can
-- never drift apart.
local configsFolder = script.Parent:FindFirstChild("Configs")

local configCache = {} -- [configName] = table or false (false = looked up, none found)

local function loadNamedConfig(name)
	if configCache[name] ~= nil then
		return configCache[name] or nil
	end

	local module = configsFolder and configsFolder:FindFirstChild(name)
	local result = nil
	if module and module:IsA("ModuleScript") then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" then
			result = loaded
		else
			warn("VehiclePhysics: Configs/" .. name .. " didn't return a table (" .. tostring(loaded) .. ")")
		end
	end

	configCache[name] = result or false
	return result
end

-- The upgrade ladder for a car type, or nil if it has none: the specs the
-- garage terminal draws sliders from, the server prices purchases with, and
-- PlayerDataStore clamps saved values against. All three go through here, so
-- there is one definition of what a level means.
--
-- The reason this is a function rather than just handing back the config
-- file's Upgrades table: **`Min` is not written in the config file at all -
-- it is filled in here from the stat's own plain field.**
--
-- A stat's level-0 value and its plain field are the same number by
-- definition (level 0 IS "no upgrades bought", i.e. the car as the config
-- file describes it). Writing it twice made that an invariant a human had to
-- maintain by hand, and the hand slipped: StarterVehicle's Torque was tuned
-- down to 15 while its Upgrades entry kept saying Min = 25, so the free
-- level-0 truck silently drove with 25 instead - the file's own tuning value
-- never reached the road. Deriving it means that class of bug cannot happen
-- again, and re-tuning a stat automatically re-bases its whole ladder.
--
-- Chassis Attributes are deliberately NOT consulted (unlike GetConfig): a
-- ladder is a property of the car TYPE, priced and drawn identically for
-- everyone, and the terminal has to draw it before any car instance exists.
local upgradeSpecCache = {} -- [configName] = table or false (false = looked up, no Upgrades)

function VehiclePhysics.GetUpgradeSpecs(name)
	if upgradeSpecCache[name] ~= nil then
		return upgradeSpecCache[name] or nil
	end

	local fileConfig = loadNamedConfig(name)
	local authored = fileConfig and fileConfig.Upgrades
	if type(authored) ~= "table" then
		upgradeSpecCache[name] = false
		return nil
	end

	local specs = {}
	for statName, authoredSpec in authored do
		-- The car's own value if it sets one, otherwise whatever every car
		-- falls back to - exactly the precedence GetConfig applies, minus the
		-- per-instance Attribute layer.
		local base = fileConfig[statName]
		if base == nil then
			base = DEFAULTS[statName]
		end

		if type(base) ~= "number" then
			warn(
				"VehiclePhysics: Configs/"
					.. name
					.. " lists "
					.. statName
					.. " as an upgrade, but there is no plain "
					.. statName
					.. " value for it to start from (not in the file, not in DEFAULTS) - skipping it. "
					.. "Every upgradable stat needs a plain numeric field, which is its free level-0 value."
			)
			continue
		end

		if authoredSpec.Min ~= nil then
			warn(
				"VehiclePhysics: Configs/"
					.. name
					.. "'s "
					.. statName
					.. " upgrade sets Min = "
					.. tostring(authoredSpec.Min)
					.. ", which is ignored - Min comes from the plain "
					.. statName
					.. " field ("
					.. tostring(base)
					.. "). Delete the Min line."
			)
		end

		local spec = table.clone(authoredSpec)
		spec.Min = base

		-- Max has to land exactly on a notch, or it lies about the ceiling:
		-- VehicleUpgrades.MaxLevel rounds, so Min 55 / Max 110 / Step 10
		-- rounds 5.5 up to 6 levels and the top notch is really 115, while
		-- the terminal's slider still scales its track to 110. Snapping Max
		-- to the top notch keeps the two agreeing.
		local levels = math.round((spec.Max - spec.Min) / spec.Step)
		local reachableMax = spec.Min + spec.Step * levels
		if math.abs(reachableMax - spec.Max) > 1e-6 then
			warn(
				"VehiclePhysics: Configs/"
					.. name
					.. "'s "
					.. statName
					.. " upgrade has Max = "
					.. tostring(spec.Max)
					.. ", which isn't a whole number of Steps above Min = "
					.. tostring(spec.Min)
					.. " - using "
					.. tostring(reachableMax)
					.. " instead. Pick a Max of Min + Step * (whole number of levels)."
			)
			spec.Max = reachableMax
		end

		specs[statName] = spec
	end

	upgradeSpecCache[name] = specs
	return specs
end

-- Optional - no default, since these should normally just fall back to
-- LateralGripStrength. Set either to give the front and rear axles
-- different grip - e.g. a drift car wants the front to hold on for
-- steering control while the rear breaks loose (RearLateralGripStrength
-- much lower than FrontLateralGripStrength).
--
-- Speed-sensitive steering is optional for the same reason: a steered tire's
-- grip force points perpendicular to the WHEEL, not to the car, so a fraction
-- sin(steer) of it always points backwards along the car. That's cornering
-- drag - real physics, and why a car coasting into a hard turn slows down
-- markedly. It can't be removed without making the tire force fictional, but
-- a real driver can't hold full lock at speed either; the wheels would just
-- scrub. Set both to taper the lock available from the full SteerAngle at a
-- standstill down to HighSpeedSteerAngle by SteerAngleFalloffSpeed studs/s
-- (which defaults to MaxSpeed), so parking-speed manoeuvring keeps every
-- degree of lock and cruising doesn't scrub. Leaving HighSpeedSteerAngle
-- unset steers exactly as before.
--
-- The steering wheel prop in the cab is deliberately NOT tapered: it reflects
-- what the driver is asking for, and a wheel that stopped moving at speed
-- would read as a broken animation.
local OPTIONAL_KEYS = {
	"FrontLateralGripStrength",
	"RearLateralGripStrength",
	"HighSpeedSteerAngle",
	"SteerAngleFalloffSpeed",
}

-- Non-numeric per-car-type overrides that don't belong in DEFAULTS (they're
-- not physics tuning). Same precedence as everything else: Attribute on the
-- Chassis > Configs/<name>.luau > nil (falls back to Raycast.server.luau's
-- own default wheel model).
local OPTIONAL_STRING_KEYS = { "WheelModelName", "CargoBedAttachmentName" }

-- Where each mirror POINTS, in degrees, consumed by VehicleMirrorViews on the
-- client. Per car type, because it depends entirely on the cab: how wide the
-- body is, how far out the mirrors sit and how high the driver's head is all
-- change the angle that frames the road nicely instead of the truck's own
-- flank. A van and a low sports car want quite different numbers.
--
--   Yaw    swing OUTWARD from straight-back. Bigger magnitude = less of your
--          own bodywork and more of the lane beside you. Which SIGN points
--          outward depends on the chassis' forward axis, so don't reason about
--          it - if a mirror swings the wrong way, flip the sign. On the
--          PickupTruck the left mirror is negative and the right positive.
--   Pitch  tilt DOWN from the horizon, positive is downward. Bigger = more
--          road and less sky, which is what helps for kerbs and tight gaps.
--
-- Only used when VehicleMirrorViews is in AIM_MODE "Rearward" (its default),
-- which ignores how the mirror mesh happens to be rotated. In "Physical" mode
-- the aim comes off the glass itself and these are not consulted.
--
-- These values are the ones tuned by eye on the PickupTruck; they are a
-- reasonable starting point for any car, not a physical constant.
local DEFAULT_MIRRORS = {
	LeftMirror = { Yaw = -15, Pitch = 15 },
	RightMirror = { Yaw = 15, Pitch = 15 },
	RearViewMirror = { Yaw = 0, Pitch = 4 },
}

-- Precedence, highest first: an Attribute set directly on this Chassis
-- instance > the car-type's Configs/<name>.luau file > DEFAULTS. This lets
-- you define a car type once in a file, and still nudge one specific
-- instance of it via Attributes without touching the shared file.
function VehiclePhysics.GetConfig(chassis)
	local carModel = chassis.Parent
	local configName = chassis:GetAttribute("ConfigName") or (carModel and carModel.Name)
	local fileConfig = configName and loadNamedConfig(configName)

	local config = {}
	for key, default in DEFAULTS do
		local value = default
		if fileConfig and fileConfig[key] ~= nil then
			value = fileConfig[key]
		end
		local attributeValue = chassis:GetAttribute(key)
		if attributeValue ~= nil then
			value = attributeValue
		end
		config[key] = value
	end
	for _, key in OPTIONAL_KEYS do
		local value = nil
		if fileConfig and fileConfig[key] ~= nil then
			value = fileConfig[key]
		end
		local attributeValue = chassis:GetAttribute(key)
		if attributeValue ~= nil then
			value = attributeValue
		end
		config[key] = value
	end
	for _, key in OPTIONAL_STRING_KEYS do
		local value = nil
		if fileConfig and fileConfig[key] ~= nil then
			value = fileConfig[key]
		end
		local attributeValue = chassis:GetAttribute(key)
		if attributeValue ~= nil then
			value = attributeValue
		end
		config[key] = value
	end

	-- Transmission is the one nested table, so it sits outside the loops
	-- above: no Attribute tier (Attributes can't hold tables), and merged one
	-- key deep rather than copied, so a car listing only `Gears` still gets
	-- every timing/audio value from DEFAULT_TRANSMISSION. `Gears` itself is
	-- replaced wholesale, which is what you want - half a gear list merged
	-- onto a longer default one would silently leave stray extra gears on the
	-- end of the car's ratios.
	local transmission = {}
	for key, default in DEFAULT_TRANSMISSION do
		transmission[key] = default
	end
	local fileTransmission = fileConfig and fileConfig.Transmission
	if fileTransmission then
		for key, value in fileTransmission do
			transmission[key] = value
		end
	end
	config.Transmission = transmission

	-- Mirrors merge one level DEEPER than Transmission: per mirror name, and
	-- then per field within it. A car that only wants to widen its left mirror
	-- writes Mirrors = { LeftMirror = { Yaw = 40 } } and keeps the default
	-- Pitch, plus both other mirrors untouched. Replacing wholesale (the way
	-- Gears is) would silently zero the fields it didn't mention, and an
	-- unstated angle reading as 0 is a mirror aimed at the horizon.
	local mirrors = {}
	local fileMirrors = fileConfig and fileConfig.Mirrors
	for name, defaults in DEFAULT_MIRRORS do
		local merged = {}
		for key, value in defaults do
			merged[key] = value
		end
		local override = fileMirrors and fileMirrors[name]
		if override then
			for key, value in override do
				merged[key] = value
			end
		end
		mirrors[name] = merged
	end
	config.Mirrors = mirrors

	return config
end

-- A wheel can be a single Part (like UAZWheel) or a multi-part Model (rim,
-- tire, hubcap, etc. welded together internally with WeldConstraints, with
-- Model.PrimaryPart set to whichever part is the external attachment point).
-- Everywhere else in this module treats "the wheel" as this one part - the
-- only external connection to the chassis - so a multi-part wheel needs no
-- special-casing anywhere but here.
-- Rigidly attaches every BasePart under `folder` (at any depth) to `chassis`
-- via a WeldConstraint, so static decoration (body panels, lights) rides
-- along with the chassis's suspension movement instead of being left behind.
-- Not for anything that needs to move independently later (doors on a hinge,
-- a rotating steering wheel) - don't point this at those folders.
function VehiclePhysics.WeldFolderToChassis(folder, chassis)
	for _, part in folder:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = chassis
			weld.Part1 = part
			weld.Parent = part
		end
	end
end

function VehiclePhysics.GetWheelPrimaryPart(wheelInstance)
	if wheelInstance:IsA("Model") then
		assert(wheelInstance.PrimaryPart ~= nil, "Wheel model " .. wheelInstance:GetFullName() .. " needs a PrimaryPart set")
		return wheelInstance.PrimaryPart
	end
	return wheelInstance
end

-- Each wheel's mount point is an Attachment named "Wheel" .. name (e.g.
-- "WheelFL"), parented directly to the Chassis and positioned visually in
-- Studio - its Position IS the wheel/raycast offset, nothing to type by hand.
function VehiclePhysics.GetWheelAttachments(chassis)
	local attachments = {}
	for _, name in WHEEL_NAMES do
		local attachment = chassis:FindFirstChild("Wheel" .. name)
		assert(attachment ~= nil, "Chassis " .. chassis:GetFullName() .. " is missing a 'Wheel" .. name .. "' Attachment")
		attachments[name] = attachment
	end
	return attachments
end

-- One of these per drive session (created when a player sits down). Just the
-- smoothed steer value now: the damper used to need last frame's suspension
-- length per wheel and no longer does (see the damper comment in Step - it
-- reads chassis velocity instead, which is exactly what removed the need to
-- carry any per-wheel history). A parked car has no State at all - it's
-- fully Anchored and not simulated, see Raycast.server.luau.
function VehiclePhysics.NewState()
	return { SmoothSteer = 0 }
end

-- Runs one physics step for one car. Only ever called for the car a player
-- is actively driving (the chassis is unanchored for exactly that long).
--
-- `input` fields, all optional except Throttle/Steer:
--   Throttle          -1..1 drive demand. NOT the raw seat ThrottleFloat any
--                     more - the sign is the GEAR's direction, so holding W
--                     in reverse arrives here as a negative number and S
--                     arrives as Brake instead. See Gearbox.luau.
--   Steer             -1..1, straight from the seat.
--   Brake             0..1 foot brake (S).
--   Handbrake         true while Space is held.
--   TorqueMultiplier  current gear's ratio (defaults to 1 = single-speed).
--   GearMaxSpeed      current gear's top speed (defaults to config.MaxSpeed).
--   Rpm               0..1 engine revs, for the engine sound's pitch. Absent
--                     means "no gearbox here", and the sound falls back to
--                     tracking road speed.
-- Degrees of lock available at this road speed - see HighSpeedSteerAngle in
-- DEFAULTS. Both the physics and the wheel visuals go through here, and they
-- have to: a front wheel drawn at an angle the grip model isn't using would
-- put the smoke and screech back out of step with the handling.
function VehiclePhysics.SteerAngleAtSpeed(config, speed)
	local highSpeedAngle = config.HighSpeedSteerAngle
	if not highSpeedAngle then
		return config.SteerAngle
	end
	-- Floored at 1: this is a divisor, and a zero here would hand every
	-- caller a NaN steer angle rather than merely steering badly.
	local falloffSpeed = math.max(config.SteerAngleFalloffSpeed or config.MaxSpeed, 1)
	local t = math.clamp(speed / falloffSpeed, 0, 1)
	return config.SteerAngle + (highSpeedAngle - config.SteerAngle) * t
end

function VehiclePhysics.Step(carModel, attachments, config, state, delta, input)
	local carPrim = carModel.PrimaryPart

	-- Rate-limited rather than instant, so the road wheels sweep toward lock
	-- instead of snapping there the frame A or D goes down. Re-centring gets
	-- its own faster rate: a real car's castor pulls the wheel straight by
	-- itself, so letting go should settle quicker than turning in does.
	local targetSteer = input.Steer or 0
	local recentering = math.abs(targetSteer) < math.abs(state.SmoothSteer)
	local steerRate = if recentering then config.SteerReturnSpeed else config.SteerSpeed
	local steerStep = delta * steerRate
	local steerDiff = targetSteer - state.SmoothSteer
	state.SmoothSteer = if math.abs(steerDiff) <= steerStep
		then targetSteer
		else state.SmoothSteer + math.sign(steerDiff) * steerStep

	local steerAngle = VehiclePhysics.SteerAngleAtSpeed(config, carPrim.AssemblyLinearVelocity.Magnitude)

	-- What the cargo aboard does to braking and grip. Read once per step
	-- rather than per wheel (all four get the same penalty), and read from an
	-- ATTRIBUTE each step rather than baked into `config` at GetConfig time,
	-- because GetConfig runs once when the player sits down, and the load can
	-- change while they are already sitting in the truck at the loading dock.
	--
	-- Both multipliers are 1 for an empty or non-cargo vehicle, so this costs
	-- one attribute read and changes nothing at all for a car that never
	-- carries anything.
	local cargoHandling = CargoLoad.HandlingForModel(config, carModel)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { carModel }
	-- RaycastParams defaults this to FALSE, which means a plain workspace
	-- raycast happily hits parts that nothing can physically touch. For a
	-- suspension ray that is flatly wrong: a wheel cannot rest on something
	-- the chassis drives straight through. Left off, every invisible trigger
	-- volume in the map reads as road - most visibly each vehicle plot's
	-- CollisionBox (deliberately CanCollide = false, see
	-- PlotCollisionGuard.server.luau), whose top face sits above the real
	-- ground. Clipping the edge of one shortens the ray, the spring reads a
	-- near-fully-compressed strut, and the wheel is fired upward off a
	-- surface that isn't there.
	rayParams.RespectCanCollide = true

	for _, wheelName in WHEEL_NAMES do
		local attachment = attachments[wheelName]
		local carCFrame = carPrim.CFrame
		local rayOrigin = attachment.WorldPosition
		local rayDirection = -carCFrame.UpVector * (config.SuspensionMaxLength + config.WheelRadius)
		local raycast = workspace:Raycast(rayOrigin, rayDirection, rayParams)

		if raycast then
			local raycastDistance = (rayOrigin - raycast.Position).Magnitude
			local springLength = math.clamp(raycastDistance - config.WheelRadius, 0, config.SuspensionMaxLength)
			local stiffnessForce = config.Stiffness * (config.SuspensionMaxLength - springLength)
			-- The damper measures how fast the strut is being compressed, and
			-- it reads that off the chassis' OWN velocity at the strut mount -
			-- not off how much springLength changed since last frame.
			--
			-- That distinction is the whole fix. springLength is a property of
			-- the GROUND under the wheel, so it jumps discontinuously whenever
			-- the surface under a wheel changes height, even by a sliver: roll
			-- a wheel off the edge of a 0.21-stud floor part and springLength
			-- steps by 0.21 in a single frame with the chassis barely moving.
			-- Differentiating that step invents a compression rate of
			-- 0.21/0.016 = 13 studs/s out of nothing, which here is a damper
			-- impulse many times the one holding the truck up - and it points
			-- DOWN, slamming the wheel into the road. Next frame the ray is
			-- long again, the sign flips, the wheel is flung up, and the two
			-- alternate: the screeching, smoking, self-damaging jitter that
			-- only a handbrake could break out of. The airborne case fixed
			-- earlier (WasGrounded) was the same bug through a bigger step;
			-- this is that bug's grounded twin, and no Damper value avoids it
			-- because the phantom rate scales with Damper too.
			--
			-- Chassis velocity has no such discontinuity - it is continuous by
			-- definition - so an edge produces exactly the damping the truck's
			-- real vertical motion deserves, which over a 0.21-stud lip is
			-- almost none. Magnitudes are unchanged for genuine suspension
			-- movement (both forms are Damper x studs/s), so nothing needs
			-- retuning; only the phantom spikes are gone.
			local mountVelocity = carPrim:GetVelocityAtPosition(rayOrigin)
			local compressionRate = -mountVelocity:Dot(carCFrame.UpVector)
			-- Belt and braces: a suspension spring can push the body up, but it
			-- must never yank it down harder than it is currently holding it
			-- up. Clamping the damper against the spring's own force keeps the
			-- total suspension impulse non-negative, so no future edge case can
			-- reintroduce a strut that pulls the truck into the ground.
			local damperForce = math.clamp(
				config.Damper * compressionRate,
				-stiffnessForce,
				config.Stiffness * config.SuspensionMaxLength
			)
			-- Applied along the GROUND's normal, not the chassis' own up
			-- vector. The magnitude above is still measured along the strut
			-- (springLength and compressionRate both run along carCFrame.
			-- UpVector, which is the axis the strut physically compresses on)
			-- - only the direction it pushes changes.
			--
			-- This is the difference between a car that coasts and a car that
			-- drives itself. The suspension carries the entire weight of the
			-- vehicle, so pointing it along the chassis' up vector means that
			-- whenever the body sits at a pitch angle, a component
			-- `weight * sin(pitch)` points along the car - and unlike a real
			-- strut, whose horizontal reaction is taken by the tire's contact
			-- patch, nothing here opposes it. It is free thrust, proportional
			-- to how the car happens to be sitting.
			--
			-- Measured on the StarterVehicle, throttle confirmed shut: a
			-- constant 4.77 studs/s^2 forward, dead flat from 15 to 35 studs/s
			-- (a stuck drive force would have faded off as 1 - v/gearTop, and
			-- did not). 4.77 / gravity is sin(1.39 degrees) - the car rests
			-- about a degree and a half nose-down, and was converting that
			-- into acceleration. Nothing above CoastSpeedThreshold could
			-- absorb it: CoastDrag only sheds 5% of speed per second, so the
			-- two would not have balanced until about 95 studs/s.
			--
			-- Why it looked like a low-speed bug: under CoastSpeedThreshold
			-- the stabilizer branch cancels ~30% of the car's velocity per
			-- frame, which swamps this easily, so the car sits still. Getting
			-- it past 3 studs/s hands it to CoastDrag, and it runs away.
			--
			-- A surface normal is straight up on flat ground no matter how the
			-- body is pitched or rolled, so a resting attitude can no longer
			-- push the car anywhere. Lean, squat and dive are untouched: they
			-- come from the four struts compressing by DIFFERENT amounts (and
			-- from the tire forces at the contact patch), which still produces
			-- exactly the same moment about the centre of mass.
			local suspensionForce = raycast.Normal * (stiffnessForce + damperForce)

			local isFrontWheel = wheelName:sub(1, 1) == "F"

			-- Handbrake locks its axle's wheels outright. "Locked" is not a
			-- synonym for "braking hard" anywhere below: it swaps this wheel's
			-- rolling behaviour for sliding behaviour, which costs it most of
			-- its sideways grip (see axleGrip) as well as changing what it
			-- does lengthwise. That grip loss is the skid.
			local isHandbrakeWheel = config.HandbrakeWheels == "All"
				or (config.HandbrakeWheels == "Front" and isFrontWheel)
				or (config.HandbrakeWheels == "Rear" and not isFrontWheel)
			local isLocked = (input.Handbrake == true) and isHandbrakeWheel

			local wheelDirCFrame = CFrame.lookAt(Vector3.zero, carCFrame.LookVector, carCFrame.UpVector)
			if isFrontWheel then
				wheelDirCFrame = wheelDirCFrame * CFrame.Angles(0, math.rad(-state.SmoothSteer * steerAngle), 0)
			end
			local localVelocity = wheelDirCFrame:ToObjectSpace(CFrame.new(carPrim:GetVelocityAtPosition(raycast.Position)))

			-- LateralGripStrength is a friction coefficient, like a real tire's:
			-- the max sideways force this wheel can generate is coefficient *
			-- its share of the car's weight. Below that limit, sideways slip is
			-- fully cancelled (full grip, mass-scaled so it can't overshoot).
			-- Above it, the tire can only partially resist - it breaks traction
			-- and the car actually slides, instead of snapping straight back
			-- within a fraction of a second regardless of how low the
			-- coefficient is (which is what a flat "cancel X% of velocity every
			-- frame" model does - even a "weak" 10%/frame at 60fps converges
			-- back to zero in a fraction of a second, never a real slide).
			local axleGrip = if isFrontWheel
				then (config.FrontLateralGripStrength or config.LateralGripStrength)
				else (config.RearLateralGripStrength or config.LateralGripStrength)
			-- A tire already sliding lengthwise has very little left to resist
			-- sideways with. Collapsing the locked axle's friction coefficient
			-- is what makes the back end break away mid-corner - the existing
			-- saturation model then does the rest for free, since the same
			-- cornering load that was comfortably under the limit a frame ago
			-- is now far over it, so the grip force pins at a fixed magnitude
			-- and the car genuinely slides instead of being snapped straight.
			if isLocked then
				axleGrip *= config.HandbrakeGripMultiplier
			end
			-- A loaded truck's tires let go sooner. This has to be applied by
			-- hand because grip is the one place mass genuinely cancels out:
			-- maxLateralImpulse below is `axleGrip * (mass/4) * g * delta` and
			-- the impulse it is clamping is `-v.X * (mass/4)`, so the mass the
			-- cargo adds appears identically on both sides and a full load
			-- would otherwise corner exactly like an empty bed.
			axleGrip *= cargoHandling.Grip
			local wheelWeight = (carPrim.AssemblyMass / 4) * workspace.Gravity
			local maxLateralImpulse = axleGrip * wheelWeight * delta
			local neededLateralImpulse = -localVelocity.X * (carPrim.AssemblyMass / 4)
			local lateralImpulseMagnitude = math.clamp(neededLateralImpulse, -maxLateralImpulse, maxLateralImpulse)
			local lateralForce = wheelDirCFrame.RightVector * lateralImpulseMagnitude

			-- How hard this tire is working, 0-1, and with it the same
			-- stabilizer-vs-real-force split the longitudinal branch makes
			-- below. BELOW the friction limit this is a slip-CANCELLING
			-- controller, and the "can't overshoot" claim above only held while
			-- it was applied near the centre of mass: at the contact patch a
			-- large share of a mass/4 * velocity impulse becomes roll instead
			-- of deceleration, rolling creates fresh sideways velocity at the
			-- patch, and it corrects that again next frame - a self-exciting
			-- loop that reads as the whole car vibrating. SATURATED, it's a
			-- real friction force pinned at a fixed magnitude with no feedback
			-- term at all, so the patch is exactly where it belongs - and that
			-- (a tire at its grip limit) is precisely when cornering roll
			-- should appear. Blending by saturation rather than switching keeps
			-- the force continuous, so there's no pop at the crossover.
			local lateralSaturation = if maxLateralImpulse > 0
				then math.min(1, math.abs(lateralImpulseMagnitude) / maxLateralImpulse)
				else 0

			-- Only wheels on the driven axle (DriveWheels: "All"/"Front"/"Rear")
			-- push the car forward - the other axle just rolls (falls through to
			-- coast/brake below), same as a real FWD/RWD car.
			local isDriveWheel = config.DriveWheels == "All"
				or (config.DriveWheels == "Front" and isFrontWheel)
				or (config.DriveWheels == "Rear" and not isFrontWheel)

			-- The low-speed full-stop branch below is a stabilizing controller
			-- rather than a real tire force, and unlike the others it must NOT
			-- be applied at the contact patch - see the note where it's set.
			local longitudinalIsStabilizer = false

			-- Both real-friction longitudinal branches (handbrake, foot brake)
			-- want the same thing: the largest force this tire can put down
			-- against its direction of travel, but never more than the impulse
			-- that would bring it to a dead stop this frame. Without that
			-- second clamp a strong-enough coefficient doesn't just stop the
			-- car, it drags it backwards through zero and oscillates.
			local function frictionStopImpulse(coefficient)
				local maxImpulse = coefficient * wheelWeight * delta
				local neededImpulse = localVelocity.Z * (carPrim.AssemblyMass / 4)
				return math.clamp(neededImpulse, -maxImpulse, maxImpulse)
			end

			local brakeAmount = math.clamp(input.Brake or 0, 0, 1)

			-- Gear selection reaches here as two plain numbers so this loop
			-- stays gearbox-agnostic: a torque multiplier, and the speed this
			-- gear tops out at (which the drive force fades toward, exactly as
			-- it used to fade toward MaxSpeed when there was only one gear).
			-- Both default to the single-speed behaviour, so the server's
			-- settle loop and any caller that doesn't know about gears is
			-- unaffected.
			local gearTorque = config.Torque * (input.TorqueMultiplier or 1)
			-- Floored at 1: this is a divisor, and a config that ever produced
			-- a zero-speed gear would otherwise turn the drive force into NaN
			-- and fling the car out of the world rather than just driving badly.
			local gearMaxSpeed = math.max(input.GearMaxSpeed or config.MaxSpeed, 1)

			local longitudinalForce
			if isLocked then
				-- Locked and sliding. Note this branch sits ABOVE the throttle
				-- one, so a locked drive wheel puts no power down at all - on a
				-- rear-drive car that means the handbrake cuts drive entirely,
				-- which is correct.
				longitudinalForce = wheelDirCFrame.LookVector * frictionStopImpulse(config.HandbrakeLockFriction)
			elseif brakeAmount > 0 and math.abs(localVelocity.Z) > REST_VELOCITY_EPSILON then
				-- Foot brake, on every wheel rather than just the driven axle.
				-- A real tire force at the contact patch, so stopping hard
				-- pitches the nose down through the same moment arm that gives
				-- the car squat and roll.
				-- cargoHandling.Brake is the load penalty, and like the grip
				-- one above it has to be explicit: frictionStopImpulse caps at
				-- `coefficient * wheelWeight` against a needed impulse of
				-- `v.Z * mass/4`, so deceleration works out to
				-- `coefficient * gravity` regardless of what the truck weighs.
				-- Without this line a fully laden truck would stop in exactly
				-- the same distance as an empty one.
				longitudinalForce = wheelDirCFrame.LookVector
					* frictionStopImpulse(config.BrakeFriction * cargoHandling.Brake * brakeAmount)
			elseif input.Throttle and input.Throttle ~= 0 and isDriveWheel then
				longitudinalForce = wheelDirCFrame.LookVector * input.Throttle * gearTorque * (1 - math.min(1, math.abs(localVelocity.Z) / gearMaxSpeed))
			elseif input.Throttle and input.Throttle ~= 0 then
				-- An UNDRIVEN wheel while the player is on the gas. It just
				-- rolls: no drive force (that is the axle above), and
				-- crucially no drag either.
				--
				-- Without this branch these wheels fell through to the two
				-- below, and the second of those is a velocity-cancelling
				-- controller - so on a rear-drive car the FRONT axle actively
				-- braked the car every time it was under CoastSpeedThreshold,
				-- which is every launch. It removes BrakeStrength/2 of the
				-- car's speed per frame (0.15 at the default 0.3), against a
				-- drive force that at that moment has just lost its stall
				-- boost, because StallSpeed and CoastSpeedThreshold are both
				-- 3. The car settles wherever those two balance instead of
				-- pulling away: on the StarterVehicle at Torque 7.5 that was
				-- a hard ceiling of about 2.6 studs/s (~2 mph), escapable
				-- only by breaking traction to skip past 3 studs/s.
				--
				-- Both branches below are for a car nobody is asking to move
				-- (see their own comments - CoastDrag is explicitly "lift off
				-- the gas" drag, and the stabilizer is there so a stopped car
				-- does not creep). Holding W is the player asking, so neither
				-- should be running at all.
				longitudinalForce = Vector3.zero
			elseif math.abs(localVelocity.Z) > config.CoastSpeedThreshold then
				-- Still going fast enough to be "coasting" - light drag only, so
				-- momentum carries through instead of slamming to a stop.
				longitudinalForce = wheelDirCFrame.LookVector
					* localVelocity.Z
					* (carPrim.AssemblyMass / 4)
					* config.CoastDrag
					* delta
			else
				-- Slow enough that continuing to creep would just look stuck
				-- rolling - fully brake to a stop. Mass-scaled and clamped to
				-- the exact impulse a full stop needs (BrakeStrength is 0-1,
				-- the fraction of that applied per frame) - an unscaled raw
				-- coefficient here only cancels BrakeStrength/mass of the
				-- velocity each frame, which for a real car's mass is a weak
				-- handful of percent, nowhere near enough to actually stop it.
				--
				-- This one is a velocity-cancelling CONTROLLER, not a real tire
				-- force, so it's applied at the strut mount rather than the
				-- contact patch. Off-centre, part of its impulse turns into
				-- rotation instead of deceleration - and rotating the body
				-- creates fresh velocity at the contact patch (v = v_com + w x r),
				-- which this same controller then reads next frame as "still
				-- moving" and corrects again. That's a positive feedback loop,
				-- and it shows up as the whole car jittering while stopped.
				-- Nothing is lost by exempting it: real braking now has its own
				-- contact-patch branch above and only falls through to here
				-- once the car is already crawling, so all the braking dive
				-- still comes from the patch where it belongs.
				longitudinalIsStabilizer = true

				-- ...and for the same reason it READS the velocity at the strut
				-- mount too, not at the contact patch like every other branch
				-- here does. Moving only the application point closed half of
				-- the loop described above and left the other half open: the
				-- controller was still measuring v_com + w x r at the patch,
				-- so a pitching body handed it a longitudinal velocity the
				-- chassis does not actually have, and it "corrected" that
				-- phantom with an impulse at the mount - which pitches the
				-- body further. Reading and acting at the same point makes it
				-- a plain velocity controller again, with no path from its own
				-- output back into its own input.
				--
				-- Housekeeping, not a bug fix: this was changed while hunting
				-- the self-accelerating car, and it turned out NOT to be the
				-- cause (that was the suspension force direction - see the
				-- note on suspensionForce above). It is kept because a
				-- controller that reads and acts at different points is a
				-- latent oscillation source regardless, but nothing observed
				-- was ever traced to it.
				local mountLocalZ = wheelDirCFrame:VectorToObjectSpace(mountVelocity).Z

				-- Below a hair of movement, correcting at all is just chasing
				-- float noise - a deadzone stops the controller from ever
				-- engaging when the car is already effectively at rest.
				if math.abs(mountLocalZ) < REST_VELOCITY_EPSILON then
					longitudinalForce = Vector3.zero
				else
					local neededLongitudinalImpulse = mountLocalZ * (carPrim.AssemblyMass / 4)
					local longitudinalImpulseMagnitude = math.clamp(
						neededLongitudinalImpulse * config.BrakeStrength,
						-math.abs(neededLongitudinalImpulse),
						math.abs(neededLongitudinalImpulse)
					)
					longitudinalForce = wheelDirCFrame.LookVector * longitudinalImpulseMagnitude
				end
			end

			-- The spring genuinely does push on the body at the strut mount,
			-- so suspensionForce stays at rayOrigin. The TIRE forces (grip and
			-- drive/brake) act at the contact patch on the ground instead -
			-- well below the centre of mass. That offset is the moment arm
			-- that makes the body pitch and roll; applying them at rayOrigin
			-- like the suspension force left effectively no moment arm, so the
			-- car could never lean regardless of how the spring was tuned
			-- (the spring only ever reacts to compression, and nothing was
			-- creating a compression difference between the wheels).
			local tireForcePosition = raycast.Position:Lerp(rayOrigin, 1 - config.BodyLean)
			carPrim:ApplyImpulseAtPosition(suspensionForce, rayOrigin)
			carPrim:ApplyImpulseAtPosition(lateralForce, rayOrigin:Lerp(tireForcePosition, lateralSaturation))
			carPrim:ApplyImpulseAtPosition(
				longitudinalForce,
				if longitudinalIsStabilizer then rayOrigin else tireForcePosition
			)
		end
		-- Airborne needs no bookkeeping at all now: with the damper reading
		-- chassis velocity there is no per-wheel history to keep in step, and
		-- so no stale value for a landing frame to differentiate against.
	end

	-- Searched recursively (not just directly on the Chassis) since the engine
	-- sound now lives under Engine/<enginePart>/Sound instead, so it comes
	-- from the actual engine part rather than the chassis.
	local sound = carModel:FindFirstChild("Sound", true)
	if sound then
		if input.Rpm then
			-- Driven by a gearbox: pitch follows ENGINE revs, so it climbs
			-- through each gear and drops back on every shift, instead of
			-- rising once monotonically from a standstill to top speed. The
			-- gearbox is what decides the revs (including the mid-shift dip) -
			-- all that happens here is mapping 0-1 onto the pitch range.
			local transmission = config.Transmission
			sound.PlaybackSpeed = transmission.IdlePitch
				+ math.clamp(input.Rpm, 0, 1) * (transmission.MaxPitch - transmission.IdlePitch)
		else
			-- No gearbox driving this step (e.g. the server's settle loop) -
			-- fall back to the old road-speed pitch so a car being simulated
			-- without a driver still sounds like something.
			sound.PlaybackSpeed = 0.8 + carPrim.AssemblyLinearVelocity.Magnitude / config.MaxSpeed
		end
	end
end

-- Purely cosmetic: positions/rotates a car's wheel meshes to follow the
-- ground and spin/steer, independent of the physics raycast above. Called
-- from the client for every vehicle it can see (not just the one driven),
-- since every viewer computes this locally from replicated position data.
-- Finds the steering wheel prop in the cab, if the car has one. Convention
-- is a child of the car model named "SteeringWheel" - either the part itself,
-- or a Model/Folder of that name containing the part (its PrimaryPart, or a
-- part of the same name inside). Returns nil for a car without one, which is
-- fine everywhere - nothing here is required.
function VehiclePhysics.GetSteeringWheelPart(carModel)
	local found = carModel:FindFirstChild("SteeringWheel")
	if not found then
		return nil
	end
	if found:IsA("BasePart") then
		return found
	end
	if found:IsA("Model") and found.PrimaryPart then
		return found.PrimaryPart
	end
	return found:FindFirstChild("SteeringWheel") or found:FindFirstChildWhichIsA("BasePart")
end

-- Surface speed a burnout's drive wheels are shown spinning at when the car
-- doesn't set WheelSpinBoost (which is off by default, and is about wheelspin
-- on a normal launch - a different thing). Purely a visual number: nothing in
-- the physics knows or cares how fast a wheel is turning.
local BURNOUT_SPIN_SPEED = 45

-- `input` fields, all optional:
--   SmoothSteer  -1..1, only known for the car this client drives
--   Throttle     gear-aware drive demand, for the wheelspin visual
--   Handbrake    true while the driver holds it
--   Burnout      true while the driver is holding the handbrake AND the gas
--   SlipOut      table to fill with [wheelName] = contact patch slip in
--                studs/s. Populated for EVERY car, not just the driven one -
--                lateral slip needs only replicated velocity and the car's
--                config, so a bystander computes the same numbers the driver
--                does and sees the same smoke and hears the same screech.
function VehiclePhysics.UpdateWheelVisuals(vehicle, attachments, config, rotationState, input)
	local smoothSteer = input.SmoothSteer or 0
	local throttle = input.Throttle or 0
	local handbrake = input.Handbrake
	local carPrim = vehicle.PrimaryPart
	local carCFrame = carPrim.CFrame
	local wheelsFolder = vehicle:FindFirstChild("Wheels")
	if not wheelsFolder then
		return
	end

	-- Computed from replicated velocity, so a bystander lands on the same
	-- angle the driver's own physics step is using.
	local steerAngle = VehiclePhysics.SteerAngleAtSpeed(config, carPrim.AssemblyLinearVelocity.Magnitude)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { vehicle }
	-- Same reason as the physics ray in Step - and it has to match it, or a
	-- bystander would see wheels ride up over trigger volumes that the
	-- driver's own car is ignoring.
	rayParams.RespectCanCollide = true

	for _, wheelName in WHEEL_NAMES do
		local attachment = attachments[wheelName]
		local wheelPart = wheelsFolder:FindFirstChild(wheelName)
		if attachment and wheelPart then
			local localOffset = attachment.Position
			local rayOrigin = attachment.WorldPosition
			local rayDirection = -carCFrame.UpVector * (config.SuspensionMaxLength + config.WheelRadius)
			local raycast = workspace:Raycast(rayOrigin, rayDirection, rayParams)

			if raycast then
				local weld = VehiclePhysics.GetWheelPrimaryPart(wheelPart):FindFirstChild("Weld")
				if weld then
					local isFrontWheel = wheelName:sub(1, 1) == "F"
					local isDriveWheel = config.DriveWheels == "All"
						or (config.DriveWheels == "Front" and isFrontWheel)
						or (config.DriveWheels == "Rear" and not isFrontWheel)

					-- Place the wheel's CENTER (its pivot) WheelRadius above the actual
					-- ground contact point, not AT it - otherwise the wheel mesh's own
					-- radius sinks its bottom half straight into the ground, since a
					-- mesh extends both above and below its pivot by its own radius.
					local raycastDistance = (rayOrigin - raycast.Position).Magnitude
					local springLength = math.clamp(raycastDistance - config.WheelRadius, 0, config.SuspensionMaxLength)
					weld.C0 = CFrame.new(localOffset - Vector3.new(0, springLength, 0))
					if localOffset.X > 0 then
						weld.C0 = weld.C0 * CFrame.Angles(0, math.rad(180), 0)
					end
					if isFrontWheel then
						weld.C0 = weld.C0 * CFrame.Angles(0, -math.rad(smoothSteer * steerAngle), 0)
					end

					-- The wheel's OWN frame, steer included - the same frame
					-- Step measures grip in, and it has to be, or the effects
					-- contradict the physics. In the chassis frame a steered
					-- front wheel that is rolling perfectly still shows a
					-- sideways velocity of speed * sin(steer), purely because
					-- it is pointed somewhere the car is not: at 20 studs/s on
					-- half lock that is 20 * sin(20deg) = 6.8 studs/s, over
					-- this truck's 6.5 threshold, so every ordinary turn
					-- screeched and smoked while the physics considered the
					-- tire completely gripped. Rotating the frame with the
					-- wheel takes that term out and leaves only genuine slip.
					local wheelDirCFrame = CFrame.lookAt(Vector3.zero, carCFrame.LookVector, carCFrame.UpVector)
					if isFrontWheel then
						wheelDirCFrame = wheelDirCFrame * CFrame.Angles(0, math.rad(-smoothSteer * steerAngle), 0)
					end
					local localVelocity = wheelDirCFrame:ToObjectSpace(CFrame.new(carPrim:GetVelocityAtPosition(raycast.Position)))

					local wheelSurfaceSpeed = localVelocity.Z

					-- A locked wheel is dragging, not rolling, so it must stop
					-- turning even while the car is still very much moving.
					-- Leaving it spinning is the single most obvious tell that
					-- the handbrake is only pretending to lock anything.
					local isLocked = handbrake == true
						and (config.HandbrakeWheels == "All"
							or (config.HandbrakeWheels == "Front" and isFrontWheel)
							or (config.HandbrakeWheels == "Rear" and not isFrontWheel))
					if isLocked then
						-- A burnout is the driven axle overpowering the locked
						-- brake, so those wheels are the one thing the
						-- handbrake does NOT hold still - they were being
						-- forced to zero along with everything else, which is
						-- why the rears sat frozen during one. There is no road
						-- speed to derive their spin from (the car going
						-- nowhere is what makes it a burnout), so it comes
						-- straight off the throttle. Negated because this is
						-- a velocity in the wheel's own frame, where forward is
						-- -Z (CFrame.lookAt points a CFrame's -Z along the
						-- direction given) - so positive throttle has to
						-- produce a NEGATIVE surface speed to spin the same way
						-- driving forwards does.
						wheelSurfaceSpeed = if input.Burnout and isDriveWheel
							then -throttle * (if config.WheelSpinBoost ~= 0 then config.WheelSpinBoost else BURNOUT_SPIN_SPEED)
							else 0
					end

					if not isLocked and isDriveWheel and throttle ~= 0 and config.WheelSpinBoost ~= 0 then
						-- Wheelspin: under throttle, the tire's surface can move
						-- faster than the car actually is - it's spinning "in
						-- place" rather than purely rolling with the ground. Fades
						-- out as the car catches up to MaxSpeed, so it reads as a
						-- burnout/wheelspin rather than the wheel spinning forever.
						-- Negated for the same reason as the burnout case
						-- above: forward is -Z in this frame.
						local slipRoom = math.max(0, 1 - math.abs(localVelocity.Z) / config.MaxSpeed)
						wheelSurfaceSpeed -= throttle * config.WheelSpinBoost * slipRoom
					end

					rotationState[wheelName] = (rotationState[wheelName] or 0.5) + wheelSurfaceSpeed / 56 --56 should be same as math.rad(number)

					-- Right-side wheels are mirrored outward-facing via the 180deg Y
					-- flip above. Spinning around a mirrored local X axis is the
					-- visual opposite of spinning around the unmirrored one - so
					-- without this, the right side rolls backwards relative to the
					-- left even though both are being told to roll the same amount.
					-- (This bug existed for the old single-part wheel too - it just
					-- didn't show, since a plain symmetric cylinder looks identical
					-- spinning either direction.)
					local spinSign = if localOffset.X > 0 then -1 else 1
					weld.C0 = weld.C0 * CFrame.Angles(spinSign * rotationState[wheelName], 0, 0)

					-- How fast this tire's contact patch is sliding across the
					-- ground, in studs/s. Measured directly as patch velocity
					-- rather than derived from the grip force, which matters
					-- for two reasons: it's the quantity that physically makes
					-- a tire howl and smoke, and unlike anything computed from
					-- the per-frame impulse model it doesn't change meaning
					-- with framerate.
					--
					--   sideways  a tire that grips has its sideways velocity
					--             cancelled, so this only grows once the tire
					--             is genuinely letting go. This is cornering
					--             slip, and it's the case that works for every
					--             car on screen, not just the driven one.
					--   lengthwise only a LOCKED wheel slides along its
					--             rolling direction - a rolling one is, by
					--             definition, not sliding that way.
					if input.SlipOut then
						local lateralSlip = math.abs(localVelocity.X)
						local longitudinalSlip = if isLocked then math.abs(localVelocity.Z) else 0
						local slip = math.sqrt(lateralSlip * lateralSlip + longitudinalSlip * longitudinalSlip)

						-- A burnout is the one case with no slip velocity to
						-- measure: the wheels are spinning but the car isn't
						-- going anywhere, and nothing in this model tracks
						-- wheel rotation independently of road speed. It's an
						-- unambiguous, deliberate two-key action though, so
						-- the driver's client just declares it - but only for
						-- the wheels actually being driven. The undriven axle
						-- is standing still doing nothing during a burnout and
						-- has no business smoking.
						local burningOut = input.Burnout == true and isDriveWheel
						if burningOut then
							slip = math.max(slip, config.TractionSlipThreshold * 1.6)
						end

						-- The two gates. A car has to actually be travelling
						-- before any of this counts, which is what keeps a car
						-- parked on a slope - genuinely creeping sideways, and
						-- genuinely slipping by the maths - silent instead of
						-- screeching and smoking forever. A burnout is exempt,
						-- since being stationary is the whole point of it.
						local carSpeed = carPrim.AssemblyLinearVelocity.Magnitude
						local counts = burningOut
							or (carSpeed >= config.TractionMinCarSpeed and slip >= config.TractionSlipThreshold)
						input.SlipOut[wheelName] = if counts then slip else 0
					end
				end
			end
		end
	end
end

return VehiclePhysics

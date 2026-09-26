-- Everything the Induction Upgrade actually DOES: the spool whistle, the
-- blow-off chirp, the anti-lag pops and bangs, the exhaust flames, the
-- two-step launch, and the boost the turbo hands the drive force.
--
-- See VehicleInduction.luau for the ladder itself (stages, prices, which stage
-- turns what on). This file owns none of that; it reads the stage off the car
-- and plays what that stage is entitled to.
--
-- BUILT PER VEHICLE, LAZILY, FOR EVERY CAR THE CLIENT CAN SEE - not just the
-- one being driven - exactly like ExhaustEffects and VehicleEffects. That is
-- what makes a bystander hear another player's anti-lag: each client runs this
-- same state machine on that car, off the state that is already replicated
-- (the stage Attribute, NetRpm, NetThrottle, NetBraking, NetShiftCount,
-- NetTwoStep). Nothing is fired over a remote and nothing is created on the
-- server, so the sounds cost no bandwidth and every player is hearing their
-- own copy in the right place in 3D.
--
-- WHERE THE SOUNDS LIVE. The whistle goes on the engine part (it is a noise
-- from under the bonnet); the chirp, the pops and the bangs go on the exhaust
-- (they are noises from the tailpipe), along with the flame and spark
-- emitters. A car built with a Sound named "Turbo" in its Engine folder has
-- that one ADOPTED as its whistle - three of the trucks were built that way in
-- Studio and it is the better-placed, better-mixed sound for them - and every
-- other car gets an identical one created here, so no car needs any audio
-- setup to be upgradable.
--
-- THE EXHAUST. Same convention as ExhaustEffects: an Attachment named
-- "Attachment" under a child of the car named "Exhaust". Two of the templates
-- (StarterVehicle, AmericanHitchTruck) do not have one, so rather than leaving
-- those cars with silent, flameless upgrades there is a fallback attachment
-- built at the back of the model's bounding box. It is not as well placed as a
-- hand-authored one - add an Exhaust attachment in Studio and it is used
-- instead, with nothing to change here.
--
-- THE AUTOMATIC GEARBOX. Real anti-lag fires when the throttle shuts, and in a
-- game with no clutch pedal there are exactly two moments that happens: the
-- player lifting off, and the box cutting drive for its own shift (see
-- Gearbox's ShiftTime).
--
-- They are NOT given the same treatment, and the split is the whole character
-- of the feature. Lifting off is the event: the crackle, the bangs and the
-- flames all live there, it is something the player did on purpose, and it is
-- the sound they bought the upgrade for. An upshift happens by itself several
-- times per pull, so it gets one small crackle, no bang and nothing visible -
-- punctuation between gears rather than a second performance competing with
-- the first. See VehicleInduction.Bursts for both recipes.

local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VehicleInduction = require(ReplicatedStorage.Modules.Vehicles.VehicleInduction)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local InductionEffects = {}

--============================================================================
-- Tuning
--============================================================================

-- How much of the throttle counts as "on the gas", and how little counts as
-- "off it". Two thresholds rather than one so a throttle hovering on a single
-- boundary cannot fire a blow-off valve every other frame.
local LIFT_FROM = 0.45
local LIFT_TO = 0.12

-- Below this much spool, lifting off is just lifting off - there is no boost
-- in the system to dump, so nothing should make a noise. This is what stops
-- the chirp firing every time the car rolls to a stop at idle.
local MIN_EVENT_SPOOL = 0.3

-- An upshift has to clear a HIGHER bar than that. Lifting off is something a
-- player does on purpose and notices; an upshift happens by itself, several
-- times per pull, and at the low bar the truck crackled its way up through the
-- gears on every gentle departure. This is the number to raise if upshift pops
-- still feel too frequent, and it is a better one to reach for than the
-- recipe's volume: making a too-frequent sound quieter leaves it too frequent.
local UPSHIFT_MIN_SPOOL = 0.62

-- Floor on the gap between two lift-off events, so feathering the throttle
-- does not machine-gun.
local EVENT_COOLDOWN = 0.32

-- THE SAFETY CAP on the shift mask, as a multiple of the gearbox's own
-- ShiftTime plus a margin. It is a BACKSTOP, not the mechanism: the mask
-- normally ends the moment the throttle comes back up (see the lift-off block),
-- and this only decides how long it may last if the throttle never does.
--
-- Deliberately generous, because the cap and the gearbox measure time with
-- different clocks - this one runs on os.clock while the gearbox counts down
-- the frame delta it is handed - and a cap that expires while drive is still
-- cut reads the cut as a lift-off and fires a full bang-and-flames burst
-- mid-gearchange. The only cost of it being too long is that a lift-off which
-- happened DURING a shift is heard a fraction late.
local SHIFT_MASK_SCALE = 2
local SHIFT_MASK_MARGIN = 0.25

-- Gap between cracks, in seconds, picked fresh for every gap. Short enough to
-- read as machine-gun rather than as a series of separate noises. Shared by
-- every event: how FAST a stutter is does not change between them, only how
-- long it runs and what it is made of - and those live per event in
-- VehicleInduction.Bursts.
local CRACK_GAP_MIN = 0.022
local CRACK_GAP_MAX = 0.075

-- Bursts DECAY: each successive gap is stretched a little, so a burst runs out
-- of steam the way an overrun does instead of stopping dead on a metronome.
local BURST_DECAY = 0.55

-- Per-crack volume randomisation, as a scale on top of the recipe's own
-- Volume, so a burst sputters unevenly rather than being flat.
local CRACK_VOLUME_MIN = 0.5
local CRACK_VOLUME_MAX = 1

-- How many Sound instances the crack voices rotate through. Has to comfortably
-- exceed the number of cracks that can overlap - at the tightest gap and the
-- longest crackle sample that is about four - or a voice gets re-used while it
-- is still sounding and cuts itself off mid-crack.
local VOICE_COUNT = 8

-- Anti-lag keeps the turbo spinning when the throttle shuts - that is its
-- entire purpose - so the fade-out is stretched by this much at stage 3+.
-- Drivers feel it as the car picking straight back up out of a corner instead
-- of waiting for the turbo to catch up.
local ANTI_LAG_FADE_SCALE = 2.4

-- Two-step. Revs are pinned here (0-1) while the launch is being held, which
-- is what the limiter sounds like, with a small flutter on top so it is
-- audibly bouncing off something rather than holding a flat note.
local TWO_STEP_RPM = 0.82
local TWO_STEP_FLUTTER = 0.06
local TWO_STEP_FLUTTER_HZ = 11
local TWO_STEP_BANG_MIN = 0.16 -- seconds between limiter bangs...
local TWO_STEP_BANG_MAX = 0.34 -- ...picked randomly in this range, so it never sounds metronomic

-- Anti-lag (W+S held, any speed). Revs are driven up to ANTI_LAG_RPM (0-1 of
-- redline) and then bounce around it. Real anti-lag holds the engine roughly
-- 55-70% up the rev range - high enough to keep the turbo spooled, low enough
-- not to hit the limiter - so 0.6 rather than a literal half. The bounce is the
-- ignition cut/refire cycle, so it is faster and rougher than the two-step's.
local ANTI_LAG_RPM = 0.9
local ANTI_LAG_FLUTTER = 0.09
local ANTI_LAG_FLUTTER_HZ = 16 -- the bounce itself is the only thing W+S does; no pops or fire while held
local ANTI_LAG_RISE_TIME = 0.35 -- seconds to swing from the real revs up to the bounce
local ANTI_LAG_FALL_TIME = 0.25

-- WHAT COUNTS AS A BANG-WORTHY MOMENT. Revs and turbo are separate: revs are
-- the engine turning, spool is energy actually going into moving the car (see
-- the spool block in Update). A pop's character depends on both:
--   full spool + high revs  crackle AND a big bang (accelerating hard, then off)
--   high revs, not spooled  crackle only (revving in place, W+S at a standstill)
--   full spool, low revs    a lone big bang (needs a high gear at a standstill;
--                           the automatic box all but prevents it)
-- Anything else is silent. Only FULL spool earns a bang.
local FULL_SPOOL = 0.95
local HIGH_RPM = 0.45

-- What letting go of the brake is worth, and for how long. On top of the
-- stage's own Boost, decaying to nothing - a shove off the line, not a
-- permanent extra gear.
local LAUNCH_BOOST = 0.55

-- ANTI-LAG LAUNCH. Holding W+S pre-loads the engine at its optimal revs: a
-- charge builds while held (0 -> 1 over ANTI_LAG_CHARGE_TIME), and letting go
-- into the gas cashes it in as a torque shove that fades over LAUNCH_TIME.
-- It is the HOLD that pays, not revs or standing still, so ordinary driving
-- (and a plain launch from a standstill) is untouched. A full charge is worth
-- LAUNCH_BOOST * ANTI_LAG_LAUNCH_SCALE extra torque at the instant of release.
local ANTI_LAG_CHARGE_TIME = 0.9
local ANTI_LAG_MIN_CHARGE = 0.15 -- a tap of W+S is not a launch
local ANTI_LAG_LAUNCH_SCALE = 15 -- full charge = +5x drive torque at release (was 1.8), fading over LAUNCH_TIME
local LAUNCH_TIME = 1.8

-- How long after the launch is let go the throttle has to come up for it to
-- count. It cannot be "on the same frame": the gas pedal RAMPS (see Gearbox's
-- ThrottleRampTime), so on the frame the brake comes off the throttle is still
-- almost exactly zero, and a launch that demanded a raised throttle right then
-- would never once fire.
local LAUNCH_ARM_WINDOW = 0.45

-- A hitch longer than this must not jump a fade (or a launch timer) to its
-- end - same guard the turbo fade has always had.
local MAX_DT = 0.1

-- Seconds between re-reads of a car's stage Attribute. Cheap either way, but
-- there is no reason to do it per car per frame.
local STAGE_RECHECK_INTERVAL = 0.5

-- Unburnt fuel lighting off in a hot pipe does not stop the instant the crack
-- does, so a Torch leaves a low flame burning afterwards - for a random length
-- inside this range, and at a random rate, so no two look alike.
local FLAME_LINGER_MIN = 0.35
local FLAME_LINGER_MAX = 2
local FLAME_LINGER_RATE_MIN = 8
local FLAME_LINGER_RATE_MAX = 28

local FLASH_TIME = 0.09 -- how long the muzzle-flash light stays up after a crack

--============================================================================
-- Rig construction
--============================================================================

local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"

local FALLBACK_ATTACHMENT_NAME = "InductionExhaustPoint"

-- The part the whistle hangs off: whatever part holds the car's engine Sound,
-- so the whistle comes from the same place the engine does. Falls back to the
-- chassis for a car with no engine sound at all.
local function findEngineParent(vehicle)
	local engineSound = vehicle:FindFirstChild("Sound", true)
	local parent = engineSound and engineSound.Parent
	if parent and parent:IsA("BasePart") then
		return parent
	end
	return vehicle.PrimaryPart
end

-- Same lookup ExhaustEffects uses, so a car set up for exhaust smoke is
-- already set up for flames with nothing further to do.
local function findAuthoredExhaustAttachment(vehicle)
	local exhaustRoot = vehicle:FindFirstChild("Exhaust")
	if not exhaustRoot then
		return nil
	end
	local attachment = exhaustRoot:FindFirstChild("Attachment", true)
	return if attachment and attachment:IsA("Attachment") then attachment else nil
end

-- For a car whose model has no Exhaust attachment. Placed at the back of the
-- bounding box, a third of the way up from the bottom, pointing backwards -
-- which is where a tailpipe is on every car in the game even when nobody has
-- marked one.
--
-- Local to this client (created under a replicated part, which never
-- replicates back), and reused rather than rebuilt: a second one would double
-- every particle burst.
local function ensureFallbackAttachment(vehicle)
	local primary = vehicle.PrimaryPart
	if not primary then
		return nil
	end
	local existing = primary:FindFirstChild(FALLBACK_ATTACHMENT_NAME)
	if existing and existing:IsA("Attachment") then
		return existing
	end

	local boxCFrame, boxSize = vehicle:GetBoundingBox()
	local rear = boxCFrame.Position
		- boxCFrame.LookVector * (boxSize.Z * 0.5)
		- boxCFrame.UpVector * (boxSize.Y * 0.2)
	-- A CFrame's LookVector IS its local -Z, and ParticleEmitter's "Front"
	-- emission direction is that same local -Z (see ExhaustEffects) - so
	-- looking backwards here is what aims the flame out of the back of the car.
	local worldCFrame = CFrame.lookAt(rear, rear - boxCFrame.LookVector)

	local attachment = Instance.new("Attachment")
	attachment.Name = FALLBACK_ATTACHMENT_NAME
	attachment.CFrame = primary.CFrame:ToObjectSpace(worldCFrame)
	attachment.Parent = primary
	return attachment
end

-- `spec` is one entry of VehicleInduction.Sounds - the id, the level and the
-- reach together. Levels are NOT set here: this file decides when a sound
-- plays and at what pitch, and VehicleInduction decides how loud it is, so
-- there is one place to go when something needs turning down.
local function makeSound(parent, name, spec)
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = spec.SoundId
	sound.Volume = spec.Volume
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 15
	sound.RollOffMaxDistance = spec.MaxDistance
	sound.Parent = parent
	return sound
end

-- The crack voices: blank Sounds that get a pool's id, level and pitch written
-- into them at the moment they fire, then rotate.
--
-- WHY A BANK rather than one Sound per pool. A burst is up to ten cracks about
-- 30ms apart, and the samples are longer than that - so several are always
-- sounding at once. Replaying ONE Sound restarts it, which cuts the previous
-- crack off and collapses the whole burst into a single ragged noise; it also
-- means every crack in the burst is stuck at one volume and one pitch, because
-- changing either would yank the one already playing. Rotating through a bank
-- lets them overlap, which is what a stutter actually is.
local function buildVoices(parent)
	local voices = table.create(VOICE_COUNT)
	for index = 1, VOICE_COUNT do
		local sound = Instance.new("Sound")
		sound.Name = "InductionVoice" .. index
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = 15
		sound.Parent = parent
		voices[index] = sound
	end
	return voices
end

-- Fires one crack: a random sample from `pool`, at its own level and pitch, on
-- whichever voice comes next. `volumeScale` is relative to the pool's level.
local function playFromPool(rig, pool, volumeScale, pitch)
	local voices = rig.Voices
	if not voices then
		return
	end
	rig.NextVoice = (rig.NextVoice % #voices) + 1
	local sound = voices[rig.NextVoice]
	if not sound.Parent then
		return
	end
	local ids = pool.SoundIds
	sound.SoundId = ids[math.random(#ids)]
	sound.Volume = pool.Volume * volumeScale
	sound.RollOffMaxDistance = pool.MaxDistance
	sound.PlaybackSpeed = pitch
	sound.TimePosition = 0
	sound:Play()
end

-- The whistle, adopted or built. Returns the Sound and whether this module
-- created it (and therefore owns destroying it).
local function getWhistle(vehicle, enginePart)
	local engine = vehicle:FindFirstChild("Engine")
	local authored = engine and engine:FindFirstChild("Turbo", true)
	if authored and authored:IsA("Sound") then
		return authored, false
	end
	if not enginePart then
		return nil, false
	end
	local sound = makeSound(enginePart, "InductionTurbo", VehicleInduction.Sounds.Whistle)
	return sound, true
end

local function buildFlame(attachment)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "InductionFlame"
	emitter.Texture = FIRE_TEXTURE
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Lifetime = NumberRange.new(0.12, 0.3)
	emitter.Speed = NumberRange.new(28, 52)
	emitter.SpreadAngle = Vector2.new(7, 7)
	emitter.Drag = 6
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.35, 1.6),
		NumberSequenceKeypoint.new(1, 0.2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.6, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	-- White-hot at the tip fading to orange: a flame that is one flat orange
	-- reads as a smoke puff tinted the wrong colour.
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 246, 214)),
		ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 154, 40)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 48, 12)),
	})
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.ZOffset = 0.2
	emitter.Parent = attachment
	return emitter
end

local function buildSparks(attachment)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "InductionSparks"
	emitter.Texture = SPARK_TEXTURE
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Lifetime = NumberRange.new(0.3, 0.8)
	emitter.Speed = NumberRange.new(20, 60)
	emitter.SpreadAngle = Vector2.new(24, 24)
	emitter.Drag = 2
	emitter.Acceleration = Vector3.new(0, -40, 0) -- sparks arc down and die, unlike the flame
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.28),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 214, 128), Color3.fromRGB(255, 108, 24))
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Parent = attachment
	return emitter
end

local function buildFlash(attachment)
	local light = Instance.new("PointLight")
	light.Name = "InductionFlash"
	light.Color = Color3.fromRGB(255, 160, 60)
	light.Range = 14
	light.Brightness = 0
	light.Enabled = false
	light.Shadows = false
	light.Parent = attachment
	return light
end

--============================================================================
-- Per-vehicle state
--============================================================================

-- Weakly keyed by car model, so a despawned car takes its entry with it even
-- if Clear is never reached (streaming, a server-side Destroy).
local states = setmetatable({}, { __mode = "k" })

local function destroyRig(rig)
	if not rig then
		return
	end
	-- The whistle may be a Sound the MODEL owns (see getWhistle) - stopping a
	-- borrowed instance is this module's business, destroying it is not.
	if rig.Whistle and rig.Whistle.Parent then
		rig.Whistle:Stop()
		rig.Whistle.Volume = rig.WhistleBaseVolume
		if rig.OwnsWhistle then
			rig.Whistle:Destroy()
		end
	end
	if rig.BlowOff then
		rig.BlowOff:Destroy()
	end
	for _, voice in rig.Voices or {} do
		voice:Destroy()
	end
	for _, name in { "Flame", "Sparks", "Flash" } do
		local instance = rig[name]
		if instance then
			instance:Destroy()
		end
	end
end

local function buildRig(vehicle, stage)
	local enginePart = findEngineParent(vehicle)
	local whistle, ownsWhistle = getWhistle(vehicle, enginePart)
	if not whistle then
		return nil -- no engine part and no authored sound: nothing to hang audio off
	end

	whistle.Looped = true
	local rig = {
		Whistle = whistle,
		OwnsWhistle = ownsWhistle,
		-- The authored level is the loudest the whistle ever gets; the fade
		-- scales from 0 up to it. Captured before the first frame overwrites
		-- Volume, and put back by destroyRig for a sound we borrowed.
		WhistleBaseVolume = whistle.Volume,
	}
	whistle.Volume = 0

	-- Everything below is the exhaust half, and every bit of it is optional:
	-- a car with no PrimaryPart at all still gets its whistle and its boost.
	local attachment = findAuthoredExhaustAttachment(vehicle) or ensureFallbackAttachment(vehicle)
	if not attachment then
		return rig
	end
	local exhaustPart = if attachment.Parent and attachment.Parent:IsA("BasePart") then attachment.Parent else enginePart

	rig.Attachment = attachment
	if exhaustPart then
		if VehicleInduction.Has(stage, "BlowOff") then
			rig.BlowOff = makeSound(exhaustPart, "InductionBlowOff", VehicleInduction.Sounds.BlowOff)
		end
		if VehicleInduction.Has(stage, "AntiLag") then
			rig.Voices = buildVoices(exhaustPart)
			rig.NextVoice = 0
		end
	end
	if VehicleInduction.Has(stage, "AntiLag") then
		rig.Flame = buildFlame(attachment)
		rig.Sparks = buildSparks(attachment)
		rig.Flash = buildFlash(attachment)
	end
	return rig
end

-- Reads the car's stage, (re)building or tearing down its rig when that stage
-- has changed - which it does the moment a player buys the next one, since
-- PlotManager writes the Attribute straight onto the car already on the road.
local function getState(vehicle, now)
	local state = states[vehicle]
	if not state then
		state = {
			Stage = -1, -- deliberately not 0: forces the first check to run
			NextStageCheck = 0,
			Spool = 0,
			Pitch = nil,
			Last = now,
			-- The spool tuning from the car's config, kept from the last
			-- driven frame so UpdateParked has one without asking for a config.
			Turbo = nil,
			PrevThrottle = 0,
			PrevShiftCount = nil,
			-- While os.clock() is under this, the gearbox is mid-shift and the
			-- throttle being at zero means nothing - see the lift-off block.
			ShiftUntil = 0,
			TwoStepHeld = false,
			AntiLagBlend = 0, -- 0-1, how far the revs have been pulled onto the anti-lag bounce
			AntiLagHeld = false,
			GasRpm = 0,
			NextEventAt = 0,
			NextTwoStepBangAt = 0,
			LaunchArmedUntil = 0,
			LaunchIsAntiLag = false,
			LaunchLeft = 0,
			LaunchPower = 1, -- scale on LAUNCH_BOOST for the launch now running
			PendingLaunchPower = 1, -- what the armed launch will be worth
			AntiLagCharge = 0,
			FlameUntil = 0,
			-- Rolled per torch (see applyFlameStyle); only read while a
			-- leftover flame is actually burning.
			FlameRate = FLAME_LINGER_RATE_MIN,
			FlashUntil = 0,
			-- True while the last draw left a flame or a flash switched on;
			-- see the note where it is written.
			Drawing = false,
			Queue = {}, -- scheduled pops, so a burst is several cracks rather than one
		}
		states[vehicle] = state
	end

	if now >= state.NextStageCheck then
		state.NextStageCheck = now + STAGE_RECHECK_INTERVAL
		local stage = VehicleInduction.ClampStage(vehicle:GetAttribute(VehicleInduction.ATTRIBUTE))
		if stage ~= state.Stage then
			destroyRig(state.Rig)
			state.Rig = if stage > 0 then buildRig(vehicle, stage) else nil
			state.Stage = stage
			state.Spool = 0
			state.Pitch = nil
			table.clear(state.Queue)
		end
	elseif state.Rig and state.Rig.Whistle and not state.Rig.Whistle.Parent then
		-- The car was rebuilt underneath us (streaming, a part destroyed) and
		-- the rig is pointing at instances that are gone. Torn down first so
		-- the parts of it that DID survive are not left playing, orphaned from
		-- any state that could ever stop them again.
		destroyRig(state.Rig)
		state.Rig = buildRig(vehicle, state.Stage)
	end

	return state
end

--============================================================================
-- Events
--============================================================================

-- For the blow-off valve, which is a single sound and a single event - the
-- crack pools go through playFromPool instead.
local function playOneShot(sound, pitch)
	if not sound or not sound.Parent then
		return
	end
	sound.PlaybackSpeed = pitch
	sound.TimePosition = 0
	sound:Play()
end

-- Picks one entry out of a weighted list and returns its `field`. Used for both
-- halves of a recipe - which pool a crack comes from, and what the exhaust does
-- about it - because they are the same roll over differently-named data.
--
-- Rolled fresh per crack, which is what makes one burst contain a couple of
-- sparks, a flash and nothing at all rather than ten identical fireballs.
local function pickWeighted(entries, field)
	local total = 0
	for _, entry in entries do
		total += entry.Weight
	end
	local roll = math.random() * total
	for _, entry in entries do
		roll -= entry.Weight
		if roll <= 0 then
			return entry[field]
		end
	end
	return entries[#entries][field]
end

-- Builds one burst and drops it in the queue, timed out over the next fraction
-- of a second. `recipe` is one entry of VehicleInduction.Bursts - it decides
-- what this burst is MADE of (which pools, how loud, what the exhaust does);
-- `intensity` (0-1) is how much boost was behind THIS firing and decides how
-- long it runs and whether a bang is on the table.
--
-- The split matters: "what a lift-off sounds like" is a design decision that
-- belongs next to the sounds, and "how hard was this particular lift-off" is a
-- runtime measurement. Folding them together is what previously left upshifts
-- drawing lift-off samples at a lower volume.
--
-- EVERYTHING else is rolled per crack: which pool, which sample from it, its
-- level, its pitch, the gap before the next one, and what the exhaust does
-- about it - so no two bursts of the same event are the same either.
local function queueBurst(state, recipe, intensity)
	if not recipe then
		return -- an event with no recipe is simply switched off
	end
	intensity = math.clamp(intensity, 0, 1)
	local count = recipe.Count.Min + math.random(0, math.max(0, math.floor(intensity * recipe.Count.Spread)))

	-- A bang, when the recipe allows one at all, OPENS the burst - the big one
	-- first and the stutter running out behind it, which is the shape a real
	-- overrun has. Never in the middle, where a two-second sample would bury
	-- everything after it.
	local bang = recipe.Bang
	local openWithBang = bang ~= nil and intensity >= bang.MinIntensity and math.random() < bang.Chance

	local at = 0
	local gapScale = 1
	for index = 1, count do
		local isBang = openWithBang and index == 1
		local pool = if isBang then "Bang" else pickWeighted(recipe.Pools, "Pool")

		-- The first crack of a burst is the loudest; the rest sputter. Without
		-- the taper a burst has no shape and reads as a rattle.
		local taper = 1 - (index - 1) / count * 0.45
		local volume = (CRACK_VOLUME_MIN + math.random() * (CRACK_VOLUME_MAX - CRACK_VOLUME_MIN)) * taper
		table.insert(state.Queue, {
			At = at,
			Pool = pool,
			Volume = volume * recipe.Volume,
			Pitch = recipe.Pitch.Min + math.random() * (recipe.Pitch.Max - recipe.Pitch.Min),
			-- No Flames table at all means this event never shows anything at
			-- the exhaust. Checked here rather than left to a "None"-only
			-- weight table, so an event that opts out cannot be given a stray
			-- spark by a later edit to the weights.
			Flame = if recipe.Flames then pickWeighted(recipe.Flames, "Style") else "None",
		})

		at += (CRACK_GAP_MIN + math.random() * (CRACK_GAP_MAX - CRACK_GAP_MIN)) * gapScale
		gapScale += BURST_DECAY / count
	end
end

-- What the exhaust does about one crack. Four outcomes, and "nothing" is the
-- most common on most events - see each recipe's Flames in VehicleInduction.
local function applyFlameStyle(rig, state, now, style)
	if style == "None" or not rig.Flame then
		return
	end

	if style == "Spark" then
		-- Unburnt fuel that did not quite light: grit out of the pipe, no
		-- flame and no light. This is the one that keeps most cracks visually
		-- quiet without them looking like nothing happened at all.
		if rig.Sparks then
			rig.Sparks:Emit(math.random(3, 8))
		end
		return
	end

	if style == "Flash" then
		rig.Flame:Emit(math.random(6, 14))
		if rig.Sparks then
			rig.Sparks:Emit(math.random(4, 10))
		end
		state.FlashUntil = math.max(state.FlashUntil, now + FLASH_TIME)
		return
	end

	-- Torch: it lit properly, and there is enough left in the pipe to keep
	-- burning for a moment. Both the length and the rate are rolled, so two
	-- torches in a row do not look like the same effect played twice.
	rig.Flame:Emit(math.random(18, 34))
	if rig.Sparks then
		rig.Sparks:Emit(math.random(12, 24))
	end
	state.FlashUntil = math.max(state.FlashUntil, now + FLASH_TIME)
	state.FlameRate = math.random(FLAME_LINGER_RATE_MIN, FLAME_LINGER_RATE_MAX)
	state.FlameUntil = math.max(
		state.FlameUntil,
		now + FLAME_LINGER_MIN + math.random() * (FLAME_LINGER_MAX - FLAME_LINGER_MIN)
	)
end

local function drainQueue(state, rig, dt, now)
	local index = 1
	while index <= #state.Queue do
		local event = state.Queue[index]
		event.At -= dt
		if event.At <= 0 then
			playFromPool(rig, VehicleInduction.Sounds[event.Pool], event.Volume, event.Pitch)
			applyFlameStyle(rig, state, now, event.Flame)
			table.remove(state.Queue, index)
		else
			index += 1
		end
	end
end

-- Which burst a release earns (see FULL_SPOOL / HIGH_RPM), or nil for silence.
local function pickReleaseRecipe(spool, rpm)
	local full = spool >= FULL_SPOOL
	local high = rpm >= HIGH_RPM
	if full and high then
		return VehicleInduction.Bursts.LiftOff
	elseif high then
		return VehicleInduction.Bursts.PopOnly
	elseif full then
		return VehicleInduction.Bursts.BangOnly
	end
	return nil
end

--============================================================================
-- Update
--============================================================================

-- Call once per frame per visible vehicle. `input` is:
--   Rpm         0-1 engine revs (the driver's own gearbox value, or NetRpm)
--   Throttle    signed drive demand (DriveThrottle, or NetThrottle)
--   Braking     brake pedal down
--   ShiftCount  a counter that increments on every gearshift, or nil
--   TwoStep     brake and gas held together at a standstill
--
-- Returns the revs the ENGINE SOUND should use, which is `input.Rpm` for every
-- car except one sitting on a two-step limiter. Callers feed the return value
-- to VehiclePhysics.UpdateEngineSound rather than their own rpm, which is what
-- makes a held launch actually sound like one.
function InductionEffects.Update(vehicle, config, input)
	local rpm = math.clamp(input.Rpm or 0, 0, 1)
	if not RunService:IsClient() then
		return rpm -- the server runs Step for parked cars; a Play there would replicate
	end

	local now = os.clock()
	local state = getState(vehicle, now)
	local dt = math.min(now - state.Last, MAX_DT)
	state.Last = now

	local stage = state.Stage
	local rig = state.Rig
	if stage <= 0 or not rig then
		state.Spool = 0
		return rpm
	end

	-- Remembered so a PARKED car can finish its fade-out without its caller
	-- having to produce a config for it - see UpdateParked, and note that
	-- VehiclePhysics.GetConfig builds a fresh table on every call, so asking
	-- for one per parked car per frame is not free.
	-- GetConfig always merges one of these in, so the fallback is only for a
	-- caller that built a config by hand. Taken from VehiclePhysics rather
	-- than written out again here, so a retuned default spool does not have to
	-- be changed in two files to take effect everywhere.
	local turbo = config.Turbo or VehiclePhysics.DefaultTurbo
	state.Turbo = turbo
	local startRpm = turbo.StartRpm
	local fullRpm = turbo.FullRpm
	local throttleMag = math.abs(input.Throttle or 0)
	local braking = input.Braking == true

	--------------------------------------------------------------------
	-- Two-step (stage 4). Pins the revs only: it adds NO spool, since nothing
	-- is being driven while the car is held on the brake.
	--------------------------------------------------------------------
	local twoStep = input.TwoStep == true and VehicleInduction.Has(stage, "TwoStep")
	local antiLag = input.AntiLag == true and VehicleInduction.Has(stage, "AntiLag") and not twoStep
	if twoStep then
		-- A limiter is an engine hitting a wall and bouncing off it, so the
		-- revs flutter rather than sitting on a note.
		rpm = TWO_STEP_RPM + math.sin(now * TWO_STEP_FLUTTER_HZ * math.pi * 2) * TWO_STEP_FLUTTER
		if now >= state.NextTwoStepBangAt then
			state.NextTwoStepBangAt = now + TWO_STEP_BANG_MIN + math.random() * (TWO_STEP_BANG_MAX - TWO_STEP_BANG_MIN)
			-- Little bursts on a fast repeat, NOT a big bang each time: a
			-- limiter is a rapid stutter, and firing a two-second sample five
			-- times a second just turns into mud.
			if VehicleInduction.Has(stage, "AntiLag") then
				queueBurst(state, VehicleInduction.Bursts.TwoStep, 0.35)
			end
		end
	end

	--------------------------------------------------------------------
	-- Spool. NOT a function of revs alone: the turbo spins up on energy being
	-- put into moving the car, so it needs the throttle actually driving AND
	-- the revs up to carry it. Revs with no drive (W+S anti-lag, a two-step
	-- hold) or a car rolling downhill on a closed throttle put nothing in, so
	-- the target is zero and any spool already there just runs down.
	--------------------------------------------------------------------
	local driving = not twoStep and not antiLag
	local target = 0
	if driving then
		local revFactor = math.clamp((rpm - startRpm) / math.max(fullRpm - startRpm, 1e-3), 0, 1)
		target = math.clamp(throttleMag, 0, 1) * revFactor
		target = target * target * (3 - 2 * target)
	end

	local fadeTime
	if target > state.Spool then
		fadeTime = turbo.FadeInTime
	else
		fadeTime = turbo.FadeOutTime
		if VehicleInduction.Has(stage, "AntiLag") then
			fadeTime *= ANTI_LAG_FADE_SCALE
		end
	end
	local step = dt / math.max(fadeTime, 0.01)
	state.Spool += math.clamp(target - state.Spool, -step, step)

	-- Pull the revs onto the bounce (and back off it on release) rather than
	-- snapping, so the note sweeps up the way a real engine would.
	local blendStep = dt / (if antiLag then ANTI_LAG_RISE_TIME else ANTI_LAG_FALL_TIME)
	state.AntiLagBlend = math.clamp(state.AntiLagBlend + (if antiLag then blendStep else -blendStep), 0, 1)
	if state.AntiLagBlend > 0 then
		local bounce = ANTI_LAG_RPM + math.sin(now * ANTI_LAG_FLUTTER_HZ * math.pi * 2) * ANTI_LAG_FLUTTER
			+ (math.random() - 0.5) * 0.03
		rpm = rpm + (bounce - rpm) * state.AntiLagBlend
	end

	if antiLag then
		state.AntiLagCharge = math.min(1, state.AntiLagCharge + dt / ANTI_LAG_CHARGE_TIME)
	end
	-- LETTING GO of W+S arms the launch with whatever charge was built...
	if state.AntiLagHeld and not antiLag then
		if state.AntiLagCharge >= ANTI_LAG_MIN_CHARGE then
			state.PendingLaunchPower = state.AntiLagCharge * ANTI_LAG_LAUNCH_SCALE
			state.LaunchArmedUntil = now + LAUNCH_ARM_WINDOW
			state.LaunchIsAntiLag = true
		end
		state.AntiLagCharge = 0
	end
	if not antiLag and not state.AntiLagHeld then
		state.AntiLagCharge = 0
	end
	-- ...and is also the moment a real anti-lag car dumps what it built up.
	if state.AntiLagHeld and not antiLag and not braking then
		local recipe = pickReleaseRecipe(state.Spool, rpm)
		if recipe then
			queueBurst(state, recipe, state.Spool)
		end
	end
	state.AntiLagHeld = antiLag

	-- The launch is ARMED when the hold ends and FIRES when the throttle
	-- actually comes up, which are not the same frame. Letting go of the gas
	-- instead of the brake simply lets the window lapse - that is what stops a
	-- player collecting the boost by backing out of a launch they thought
	-- better of.
	if state.TwoStepHeld and not twoStep then
		state.LaunchArmedUntil = now + LAUNCH_ARM_WINDOW
		state.PendingLaunchPower = 1
		state.LaunchIsAntiLag = false
		state.NextTwoStepBangAt = 0
	end
	state.TwoStepHeld = twoStep

	if state.LaunchArmedUntil > 0 and now <= state.LaunchArmedUntil and throttleMag > LIFT_TO then
		state.LaunchArmedUntil = 0
		-- Spool is already full from the hold, so this lands on top of a car
		-- that is also making its full boost torque.
		state.LaunchLeft = LAUNCH_TIME
		state.LaunchPower = state.PendingLaunchPower
		-- An anti-lag launch already popped on release; only the two-step
		-- launch gets its own bang here.
		if not state.LaunchIsAntiLag and VehicleInduction.Has(stage, "AntiLag") then
			-- The one place a bang is all but guaranteed - see the Launch
			-- recipe's 90% Chance.
			queueBurst(state, VehicleInduction.Bursts.Launch, 1)
		end
	elseif now > state.LaunchArmedUntil then
		state.LaunchArmedUntil = 0
	end

	state.LaunchLeft = math.max(0, state.LaunchLeft - dt)

	--------------------------------------------------------------------
	-- Gearshifts. CHECKED BEFORE LIFT-OFF, and that order is load-bearing.
	--
	-- Gearbox.Update returns Throttle = 0 for the whole ShiftTime window -
	-- that drive cut IS the shift, it is what you feel between gears. But it
	-- is indistinguishable, from here, from the player taking their foot off:
	-- both arrive as the throttle going from 1 to 0 in one frame. Detected in
	-- the other order, every single upshift fired a full LiftOff burst - bangs,
	-- flames and a blow-off chirp - on top of its own blip, which is exactly
	-- "I still hear other sounds when accelerating".
	--
	-- So a shift opens a window, and inside it lift-off is not looked for at
	-- all. The window is the gearbox's own ShiftTime plus a margin, because the
	-- shift count and the throttle drop can land a frame apart for a bystander
	-- reading them off replicated attributes.
	--------------------------------------------------------------------
	local shiftCount = input.ShiftCount
	if shiftCount ~= nil then
		if state.PrevShiftCount ~= nil and shiftCount ~= state.PrevShiftCount then
			local transmission = config.Transmission or VehiclePhysics.DefaultTransmission
			state.ShiftUntil = now + transmission.ShiftTime * SHIFT_MASK_SCALE + SHIFT_MASK_MARGIN

			-- A HIGHER BAR than the other events (UPSHIFT_MIN_SPOOL, not
			-- MIN_EVENT_SPOOL): an upshift happens several times per pull
			-- whether the player is driving hard or pottering to a delivery,
			-- and only the hard ones should make any noise at all. Everything
			-- else about how small this is lives in the Upshift recipe.
			if VehicleInduction.Has(stage, "AntiLag") and state.Spool >= UPSHIFT_MIN_SPOOL and not twoStep and not antiLag then
				queueBurst(state, VehicleInduction.Bursts.Upshift, state.Spool)
			end
		end
		state.PrevShiftCount = shiftCount
	end

	--------------------------------------------------------------------
	-- Lift-off: the blow-off chirp and the anti-lag crackle.
	--------------------------------------------------------------------
	local inShift = now < state.ShiftUntil
	if inShift and throttleMag > LIFT_TO then
		-- THE THROTTLE CAME BACK, so the drive cut is over whatever the clock
		-- says - and THIS, not the timer, is what normally ends the mask. The
		-- timer only exists as a cap for the case where the throttle never
		-- returns because the player genuinely lifted off mid-shift.
		--
		-- Ending it on the signal itself rather than on a duration is what
		-- makes this robust: the mask no longer has to predict how long the
		-- gearbox will hold drive down, so the two cannot disagree.
		state.ShiftUntil = 0
		inShift = false
	end

	local lifted = false
	if not inShift then
		lifted = state.PrevThrottle >= LIFT_FROM and throttleMag <= LIFT_TO
		state.PrevThrottle = throttleMag
		if throttleMag > LIFT_FROM then
			-- The revs the driver was actually pulling, for the release recipe:
			-- by the frame of the lift they have already started to fall.
			state.GasRpm = rpm
		end
	end
	-- PrevThrottle is deliberately FROZEN for the length of the window rather
	-- than tracking the cut down to zero and back. That is what makes a genuine
	-- lift-off during a gearchange still count: the window ends, PrevThrottle is
	-- still the value from before the shift, and if the player really has come
	-- off the gas the very next frame sees the drop and fires normally. Letting
	-- it track would leave PrevThrottle at 0 when the window closed, and a real
	-- lift-off mid-shift would be swallowed entirely.

	-- BRAKING IS NOT LIFTING OFF. A blow-off valve opens because the throttle
	-- plate shut on a spinning turbo, which is a thing that happens when you
	-- come off the gas - not when you stand on the brake, and not when you
	-- coast at idle with nothing in the system. Both halves of that are
	-- enforced here and it is the whole reason the sound stays special.
	if lifted and not braking and not twoStep and not antiLag and now >= state.NextEventAt then
		local recipe = pickReleaseRecipe(state.Spool, state.GasRpm)
		-- The chirp is boost venting, so it still wants a spooled turbo; the
		-- pops follow the full/high-revs rules instead.
		local chirp = state.Spool >= MIN_EVENT_SPOOL and VehicleInduction.Has(stage, "BlowOff")
		if recipe or chirp then
			state.NextEventAt = now + EVENT_COOLDOWN
			if chirp then
				playOneShot(rig.BlowOff, 0.94 + state.Spool * 0.22)
			end
			if recipe and VehicleInduction.Has(stage, "AntiLag") then
				queueBurst(state, recipe, state.Spool)
			end
		end
	end

	drainQueue(state, rig, dt, now)

	--------------------------------------------------------------------
	-- Draw: whistle level and pitch, lingering flame, flash decay.
	--------------------------------------------------------------------
	local whistle = rig.Whistle
	if whistle and whistle.Parent then
		local pitchT = math.clamp((rpm - startRpm) / math.max(1 - startRpm, 1e-3), 0, 1)
		local minPitch, maxPitch = turbo.MinPitch, turbo.MaxPitch
		local targetPitch = minPitch + pitchT * (maxPitch - minPitch)
		if not state.Pitch then
			state.Pitch = targetPitch
		end
		state.Pitch += (targetPitch - state.Pitch) * (1 - math.exp(-turbo.PitchSmoothing * dt))
		whistle.PlaybackSpeed = state.Pitch
		whistle.Volume = rig.WhistleBaseVolume * state.Spool
		-- Only playing while audible, so a car with its turbo faded out (every
		-- parked one) isn't mixing a silent looping sound.
		if state.Spool > 0.001 then
			if not whistle.IsPlaying then
				whistle:Play()
			end
		elseif whistle.IsPlaying then
			whistle:Stop()
		end
	end

	local burning = now < state.FlameUntil
	if rig.Flame then
		rig.Flame.Enabled = burning
		-- The rate was rolled when the torch lit (see applyFlameStyle), so one
		-- leftover flame guts out and the next one idles.
		rig.Flame.Rate = if burning then state.FlameRate else 0
	end
	local lit = now < state.FlashUntil
	if rig.Flash then
		rig.Flash.Enabled = lit
		rig.Flash.Brightness = if lit then 3.5 else 0
	end
	-- Recorded rather than recomputed by UpdateParked from FlameUntil, because
	-- the two answer different questions. "Is the timer still running" goes
	-- false one frame BEFORE this function has run again to switch the emitter
	-- off - so a parked car whose caller stopped as soon as the timer expired
	-- would be left burning forever. "Did the last draw leave something on" is
	-- the question that has to be false before it is safe to stop drawing.
	state.Drawing = burning or lit

	return rpm
end

-- Lets a PARKED car's whistle finish fading out and its flames burn out. The
-- client's per-frame loop skips an Anchored car entirely (the server anchors it
-- the instant its driver gets out), so Update stops being called for it - and
-- the whistle, being a local looping sound nothing else stops, would drone on
-- at whatever volume it had when the driver left, for every player.
--
-- Cheap enough to call every frame for every parked car: a car with no rig, or
-- one already silent, returns at once.
function InductionEffects.UpdateParked(vehicle)
	local state = states[vehicle]
	if not state or not state.Rig or not state.Turbo then
		return
	end
	if state.Spool <= 0 and #state.Queue == 0 and not state.Drawing then
		return
	end
	InductionEffects.Update(vehicle, { Turbo = state.Turbo }, { Rpm = 0, Throttle = 0, Braking = false })
end

-- The torque multiplier this car's turbo is currently worth, for the client
-- that is DRIVING it to fold into VehiclePhysics.Step's TorqueMultiplier. 1
-- for a stock car (or for a car this client has never run Update on), so
-- callers can multiply unconditionally.
--
-- Read rather than pushed, because boost is a continuous value the physics
-- wants on its own frame and the effects layer happens to be where the spool
-- is tracked - not because the physics needs to know anything about turbos.
function InductionEffects.TorqueMultiplier(vehicle)
	local state = states[vehicle]
	if not state or state.Stage <= 0 then
		return 1
	end
	local boost = VehicleInduction.TorqueMultiplier(state.Stage, state.Spool)
	if state.LaunchLeft > 0 then
		boost += LAUNCH_BOOST * state.LaunchPower * (state.LaunchLeft / LAUNCH_TIME)
	end
	return boost
end

-- Is this car's two-step currently able to fire? Used by the driving client to
-- decide whether holding both pedals means anything, so a stock car's brake
-- still just brakes.
function InductionEffects.HasTwoStep(vehicle)
	local state = states[vehicle]
	return state ~= nil and VehicleInduction.Has(state.Stage, "TwoStep")
end

-- Can this car's anti-lag fire? Same role as HasTwoStep: a stock or lower-stage
-- car holding W+S just brakes.
function InductionEffects.HasAntiLag(vehicle)
	local state = states[vehicle]
	return state ~= nil and VehicleInduction.Has(state.Stage, "AntiLag")
end

-- Is a launch shove running right now? The driving client hands this to the
-- gearbox so shifts do not cut drive in the middle of it.
function InductionEffects.LaunchActive(vehicle)
	local state = states[vehicle]
	return state ~= nil and state.LaunchLeft > 0
end

-- Called when a car goes away, and when the client stops tracking it.
function InductionEffects.Clear(vehicle)
	local state = states[vehicle]
	if not state then
		return
	end
	destroyRig(state.Rig)
	states[vehicle] = nil
end

return InductionEffects

-- Tire screech and smoke, driven entirely by the per-wheel slip numbers
-- VehiclePhysics.UpdateWheelVisuals produces. Nothing here decides whether a
-- tire is slipping - it only reacts to being told that it is.
--
-- Built per vehicle, lazily, and for EVERY car the client can see rather than
-- just the one it's driving. That works because cornering slip is computable
-- from replicated velocity alone (see the SlipOut comment in VehiclePhysics),
-- so a bystander independently arrives at the same numbers the driver does
-- and gets the same smoke and screech out of them, with nothing sent over the
-- network. The exception is a burnout, which needs the driver's key state and
-- so only shows for the driver themselves.

local VehiclePhysics = require(game:GetService("ReplicatedStorage").Modules.Vehicles.VehiclePhysics)

local VehicleEffects = {}

-- How far past TractionSlipThreshold a tire has to slide before the effects
-- are at full strength. Without a ramp the screech and smoke snap to full the
-- instant the threshold is crossed, which makes every mild slide sound like a
-- maximum-effort drift.
local SLIP_RAMP = 18

local SMOKE_TEXTURE = "rbxassetid://243660364" -- soft round puff, the standard Roblox smoke sprite

local rigs = {} -- [vehicle] = { Smoke = { [wheelName] = { Emitter, Anchor, WheelPart } }, Screech = Sound }

local function buildSmoke(chassis)
	-- A free-floating Attachment on the CHASSIS, not the wheel: the wheel
	-- mesh spins around its axle several times a second at speed
	-- (VehiclePhysics rotationState), and a ParticleEmitter fires along its
	-- parent's local up-axis. Parented straight to the wheel, that axis
	-- sweeps a full circle every spin, so instead of a puff each particle
	-- gets flung out along whatever direction the wheel happened to be
	-- facing at that instant - a spinning fan of thin streaks, which is
	-- exactly the "lines instead of smoke" look. The attachment's position
	-- is re-pinned to the wheel every frame (see Update) so it still tracks
	-- suspension travel and steering, but its orientation only ever follows
	-- the chassis, never the wheel spin, so smoke always puffs straight up.
	local anchor = Instance.new("Attachment")
	anchor.Name = "TireSmokeAnchor"
	anchor.Parent = chassis

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "TireSmoke"
	emitter.Texture = SMOKE_TEXTURE
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(1, 1.8)
	-- Drifts up and away from the wheel rather than being flung: tire smoke
	-- billows, it doesn't spray. Wide spread and low speed so puffs overlap
	-- into a cloud instead of reading as separate dots/streaks.
	emitter.Speed = NumberRange.new(2, 5)
	emitter.SpreadAngle = Vector2.new(50, 50)
	emitter.Drag = 4 -- bleeds off initial speed fast so puffs hang and billow rather than fly outward
	emitter.Acceleration = Vector3.new(0, 4, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-30, 30)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(0.5, 5),
		NumberSequenceKeypoint.new(1, 8),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.15, 0.35),
		NumberSequenceKeypoint.new(0.6, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Color = ColorSequence.new(Color3.fromRGB(224, 222, 218))
	emitter.LightEmission = 0.02
	emitter.LightInfluence = 1
	emitter.ZOffset = -0.5 -- nudges puffs toward camera so they don't get lost inside the wheel/chassis mesh
	emitter.Parent = anchor
	return emitter, anchor
end

local function getRig(vehicle, config)
	local rig = rigs[vehicle]
	if rig then
		return rig
	end

	local wheelsFolder = vehicle:FindFirstChild("Wheels")
	local chassis = vehicle.PrimaryPart
	if not (wheelsFolder and chassis) then
		return nil -- car isn't fully set up yet; try again next frame
	end

	rig = { Smoke = {} }
	for _, wheelName in VehiclePhysics.WheelNames do
		local wheel = wheelsFolder:FindFirstChild(wheelName)
		if not wheel then
			return nil
		end
		local emitter, anchor = buildSmoke(chassis)
		rig.Smoke[wheelName] = {
			Emitter = emitter,
			Anchor = anchor,
			WheelPart = VehiclePhysics.GetWheelPrimaryPart(wheel),
		}
	end

	-- One looping screech for the whole car, not one per wheel: four
	-- overlapping copies of the same loop phase-cancel into a mess, and a
	-- sliding car is a single sound to anyone listening to it anyway.
	local screech = Instance.new("Sound")
	screech.Name = "TireScreech"
	screech.SoundId = config.TireScreechSoundId
	screech.Looped = true
	screech.Volume = 0
	screech.RollOffMaxDistance = 200
	screech.Parent = chassis
	rig.Screech = screech

	rigs[vehicle] = rig
	return rig
end

-- `slip` is [wheelName] = contact patch slip in studs/s, already gated by
-- VehiclePhysics (a non-slipping wheel reads exactly 0).
function VehicleEffects.Update(vehicle, config, slip)
	local rig = getRig(vehicle, config)
	if not rig then
		return
	end

	local worst = 0
	for wheelName, smoke in rig.Smoke do
		local wheelSlip = slip[wheelName] or 0
		worst = math.max(worst, wheelSlip)

		-- Re-pin every frame to the wheel's current position (tracks
		-- suspension travel and steering) without touching orientation, so
		-- the anchor keeps puffing straight up regardless of how fast the
		-- wheel itself is spinning - see the comment in buildSmoke.
		smoke.Anchor.WorldPosition = smoke.WheelPart.Position - Vector3.new(0, config.WheelRadius * 0.8, 0)

		-- 0-1 for this wheel, measured from the threshold rather than from
		-- zero, so a tire that has only just let go smokes faintly.
		local intensity = math.clamp((wheelSlip - config.TractionSlipThreshold) / SLIP_RAMP, 0, 1)
		if wheelSlip > 0 then
			smoke.Emitter.Enabled = true
			smoke.Emitter.Rate = 12 + intensity * 60
		else
			smoke.Emitter.Enabled = false
			smoke.Emitter.Rate = 0
		end
	end

	local intensity = math.clamp((worst - config.TractionSlipThreshold) / SLIP_RAMP, 0, 1)
	if worst > 0 then
		rig.Screech.Volume = config.TireScreechVolume * (0.35 + intensity * 0.65)
		-- A harder slide is a higher, more urgent note. Kept to a narrow
		-- range: pitch-shifting a screech loop far from its recorded pitch is
		-- immediately obvious.
		rig.Screech.PlaybackSpeed = 0.92 + intensity * 0.25
		if not rig.Screech.IsPlaying then
			rig.Screech:Play()
		end
	elseif rig.Screech.IsPlaying then
		rig.Screech:Stop()
	end
end

-- Called when a car goes away, and when the client stops tracking it.
function VehicleEffects.Clear(vehicle)
	local rig = rigs[vehicle]
	if not rig then
		return
	end
	for _, smoke in rig.Smoke do
		smoke.Anchor:Destroy()
	end
	rig.Screech:Destroy()
	rigs[vehicle] = nil
end

return VehicleEffects

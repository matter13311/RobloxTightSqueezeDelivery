-- Exhaust smoke, driven by engine Rpm (see VehicleNetworkState/Raycast.server
-- for how NetRpm gets onto the vehicle - 0 exactly when nobody's driving,
-- otherwise Gearbox's 0-1 normalized value with an IdleRpm floor around 0.12).
--
-- Built per vehicle, lazily, for every car the client can see (not just the
-- one it's driving), same as VehicleEffects - the caller only ever runs this
-- while the vehicle is unanchored (i.e. occupied), so there's nothing here
-- deciding on/off, only how much.
--
-- The emitter is parented to a pre-placed Attachment rather than one built
-- here, because only the car's author can see the model and knows where the
-- exhaust tip actually is and which way it faces. Convention: an Attachment
-- named "Attachment" somewhere under a child of the car model named
-- "Exhaust" (e.g. CarName.Exhaust.Exhaust.Attachment) - not hardcoded to any
-- one car, so every car just needs that same shape to get smoke for free.

local ExhaustEffects = {}

-- Same built-in smoke sprite VehicleEffects uses for tire smoke.
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"

-- Particles/second at idle (Rpm == IdleRpm) and at Rpm == 1 respectively.
-- Never fully zero while the engine's on, so idling still shows a light puff
-- rather than looking like the exhaust has stalled.
local IDLE_RATE = 12
local MAX_RATE = 65

local rigs = {} -- [vehicle] = { Emitter }

local function findExhaustAttachment(vehicle)
	local exhaustRoot = vehicle:FindFirstChild("Exhaust")
	if not exhaustRoot then
		return nil
	end
	-- Recursive: covers CarName.Exhaust.Attachment directly as well as
	-- CarName.Exhaust.Exhaust.Attachment (an Exhaust part nested inside an
	-- Exhaust folder/model), whatever depth a given car's author used.
	return exhaustRoot:FindFirstChild("Attachment", true)
end

local function buildSmoke(attachment)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "ExhaustSmoke"
	emitter.Texture = SMOKE_TEXTURE
	emitter.Enabled = false
	emitter.Rate = 0

	-- Points along the Attachment's own local -Z (its "Front") rather than a
	-- fixed world direction, so the author aims it just by orienting the
	-- Attachment in Studio to face out of the tailpipe.
	emitter.EmissionDirection = Enum.NormalId.Front

	emitter.Lifetime = NumberRange.new(0.8, 1.6)
	emitter.Speed = NumberRange.new(3, 7)
	emitter.SpreadAngle = Vector2.new(12, 12)
	emitter.Drag = 1
	emitter.Acceleration = Vector3.new(0, 1.5, 0)

	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-30, 30)

	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2, 0.3),
		NumberSequenceKeypoint.new(0.4, 3, 0.6),
		NumberSequenceKeypoint.new(1, 4.5, 0.8),
	})
	-- Starts near-opaque (0.15) rather than half-see-through - a diesel puff
	-- is thick right at the tip, not a faint haze that only shows up once it's
	-- ballooned in size.
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15, 0.05),
		NumberSequenceKeypoint.new(0.3, 0.3, 0.1),
		NumberSequenceKeypoint.new(1, 1, 0),
	})
	-- Deliberately dark gray, not the near-white VehicleEffects uses for tire
	-- smoke - the two need to read as different effects at a glance.
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(90, 90, 90)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(50, 50, 50)),
	})

	emitter.LightEmission = 0
	emitter.LightInfluence = 1
	emitter.Parent = attachment
	return emitter
end

local function getRig(vehicle)
	local rig = rigs[vehicle]
	if rig then
		return rig
	end

	local attachment = findExhaustAttachment(vehicle)
	if not attachment then
		return nil -- car has no Exhaust attachment set up; nothing to do
	end

	rig = { Emitter = buildSmoke(attachment) }
	rigs[vehicle] = rig
	return rig
end

-- `rpm` is the 0-1 value off the NetRpm attribute (or the driving client's
-- own Gearbox output for its own car) - already 0 exactly when unoccupied,
-- though callers only invoke this while the car is actually unanchored.
function ExhaustEffects.Update(vehicle, rpm)
	local rig = getRig(vehicle)
	if not rig then
		return
	end

	if rpm > 0 then
		rig.Emitter.Enabled = true
		rig.Emitter.Rate = IDLE_RATE + math.clamp(rpm, 0, 1) * (MAX_RATE - IDLE_RATE)
	else
		rig.Emitter.Enabled = false
		rig.Emitter.Rate = 0
	end
end

-- Called when a car goes away, and when the client stops tracking it.
function ExhaustEffects.Clear(vehicle)
	local rig = rigs[vehicle]
	if not rig then
		return
	end
	rig.Emitter:Destroy()
	rigs[vehicle] = nil
end

return ExhaustEffects

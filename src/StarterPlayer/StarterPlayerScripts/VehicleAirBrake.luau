-- The air-brake hiss - a one-shot burst of released air each time a big
-- truck's brake pedal goes down. Built per vehicle, lazily, the same rig
-- pattern as VehicleReverseBeep (see that module's header): a Sound sits on
-- the chassis and this plays it on the frame `isBraking` turns true.
--
-- Braking state is only known frame-perfectly for the car THIS client is
-- driving; every other car falls back to the NetBraking Attribute the driving
-- client replicates over VehicleNetworkState. Passing that straight through
-- means a bystander hears another player's truck hiss as it stops too, same
-- as its brake lights.
--
-- Not every car has air brakes - see VehiclePhysics.Defaults.AirBrakeSoundId
-- for why it's opt-in. A car with no id set never builds a rig, so calling
-- Update on it every frame is a cheap no-op.

local VehicleAirBrake = {}

local rigs = {} -- [vehicle] = { Sound, WasBraking, LastPlayed }

local function getRig(vehicle, config)
	local rig = rigs[vehicle]
	if rig then
		return rig
	end

	local soundId = config.AirBrakeSoundId
	if type(soundId) ~= "string" or soundId == "" then
		return nil -- this car has no air brakes; opted out
	end

	local chassis = vehicle.PrimaryPart
	if not chassis then
		return nil -- car isn't fully set up yet; try again next frame
	end

	local sound = Instance.new("Sound")
	sound.Name = "AirBrake"
	sound.SoundId = soundId
	sound.Volume = config.AirBrakeVolume
	sound.RollOffMaxDistance = config.AirBrakeRollOffMaxDistance
	sound.Parent = chassis

	rig = { Sound = sound, WasBraking = false, LastPlayed = 0 }
	rigs[vehicle] = rig
	return rig
end

function VehicleAirBrake.Update(vehicle, config, isBraking)
	local rig = getRig(vehicle, config)
	if not rig then
		return
	end

	if isBraking and not rig.WasBraking then
		-- The gap is what keeps feathering the pedal into a corner from
		-- machine-gunning the hiss: a tap inside it is simply silent.
		local now = os.clock()
		if now - rig.LastPlayed >= config.AirBrakeMinInterval then
			rig.LastPlayed = now
			rig.Sound:Play()
		end
	end
	rig.WasBraking = isBraking
end

-- Called when a car goes away, and when the client stops tracking it.
function VehicleAirBrake.Clear(vehicle)
	local rig = rigs[vehicle]
	if not rig then
		return
	end
	rig.Sound:Destroy()
	rigs[vehicle] = nil
end

return VehicleAirBrake

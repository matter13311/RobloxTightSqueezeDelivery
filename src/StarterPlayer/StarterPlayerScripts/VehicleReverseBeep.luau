-- The backup alarm - a looped beep while a car is reversing, the way a real
-- big truck warns anyone behind it. Built per vehicle, lazily, same rig
-- pattern as VehicleEffects' tire screech (see that module's header): a
-- looped Sound sits on the chassis and this just toggles :Play()/:Stop() and
-- volume off whatever `isReversing` it's handed.
--
-- Reversing state is only known frame-perfectly for the car THIS client is
-- driving; every other car falls back to the NetReversing Attribute the
-- driving client replicates over VehicleNetworkState (see the isReversing
-- comment above the VehicleLights.Update call in RayCastSuspension). Passing
-- that straight through here means a bystander hears another player's truck
-- beeping while it backs up too, same as the reverse lights.
--
-- Not every car has a beeper - see VehiclePhysics.Defaults.ReverseBeepSoundId
-- for why it's opt-in. A car with no id set never builds a rig, so calling
-- Update on it every frame is a cheap no-op.

local VehicleReverseBeep = {}

local rigs = {} -- [vehicle] = Sound

local function getSound(vehicle, config)
	local sound = rigs[vehicle]
	if sound then
		return sound
	end

	local soundId = config.ReverseBeepSoundId
	if type(soundId) ~= "string" or soundId == "" then
		return nil -- this car has no reverse beeper; opted out
	end

	local chassis = vehicle.PrimaryPart
	if not chassis then
		return nil -- car isn't fully set up yet; try again next frame
	end

	sound = Instance.new("Sound")
	sound.Name = "ReverseBeep"
	sound.SoundId = soundId
	sound.Looped = true
	sound.Volume = config.ReverseBeepVolume
	sound.RollOffMaxDistance = config.ReverseBeepRollOffMaxDistance
	sound.Parent = chassis

	rigs[vehicle] = sound
	return sound
end

function VehicleReverseBeep.Update(vehicle, config, isReversing)
	local sound = getSound(vehicle, config)
	if not sound then
		return
	end

	if isReversing then
		if not sound.IsPlaying then
			sound:Play()
		end
	elseif sound.IsPlaying then
		sound:Stop()
	end
end

-- Called when a car goes away, and when the client stops tracking it.
function VehicleReverseBeep.Clear(vehicle)
	local sound = rigs[vehicle]
	if not sound then
		return
	end
	sound:Destroy()
	rigs[vehicle] = nil
end

return VehicleReverseBeep

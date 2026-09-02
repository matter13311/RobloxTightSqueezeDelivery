-- The drivetrain between the player's two keys and VehiclePhysics.Step.
--
-- VehiclePhysics deliberately knows nothing about gears: it takes a signed
-- throttle, a brake, a torque multiplier and a top speed, and that's the
-- entire interface. Everything about WHICH gear that is - the direction the
-- car is in, the automatic box inside D, the dead window during a shift, the
-- revs the engine sound follows - lives here, so the suspension/grip loop
-- stays the one thing it already was.
--
-- There are only two controls, and no gear lever at all:
--
--   W   go forwards          S   brake, then reverse
--
-- Three layers, and it matters that they're separate:
--   * The DIRECTION (R / D) is chosen automatically from how the car is
--     already moving and which key is held. The player never selects it.
--   * The GEAR (1..#Gears) is the box's own business, and only exists inside
--     D. It shifts itself on road speed.
--   * The PEDALS are derived from the two keys, and what S means depends on
--     the direction: in D it's the brake, in R it's the gas.
--
-- The direction flip is what makes this work without a lever. S brakes the
-- car normally; only once the car is fully stopped AND S is still held for
-- AutoReverseDelay does it drop into reverse. That delay is the whole trick -
-- without it, braking to a halt would fling you backwards the instant you
-- touched zero, and with it "brake" and "reverse" can share one key without
-- ever being ambiguous.
--
-- Tuning lives in each car's Configs/<name>.luau under `Transmission` - see
-- VehiclePhysics.DefaultTransmission for what every key means.

local Gearbox = {}

-- Display order, left to right, on the dashboard. There is no neutral: with
-- no lever to leave it in, a neutral the player can't select and can't get
-- out of would only ever be a way for the car to feel broken.
local SELECTOR_ORDER = { "R", "D" }
Gearbox.SelectorOrder = SELECTOR_ORDER

-- Which way the car is driven in each direction. The sign lives here rather
-- than on the pedal, which is why W is never "backwards" and S is never
-- "negative throttle" - the gear decides, the key just asks for power.
local SELECTOR_DIRECTION = { R = -1, D = 1 }

function Gearbox.new(config)
	local transmission = config.Transmission
	local starting = if SELECTOR_DIRECTION[transmission.StartingGear] then transmission.StartingGear else "D"
	return {
		Selector = starting,
		Gear = 1, -- index into Transmission.Gears; only meaningful while Selector == "D"
		-- The gear the box is currently shifting INTO. Non-nil for exactly
		-- the ShiftTime window, during which no gear is engaged at all and
		-- drive torque is zero - that gap is the shift you hear and feel.
		PendingGear = nil,
		ShiftTimeRemaining = 0,
		Rpm = transmission.IdleRpm,
		-- How long the "other" key has been held while stopped. Reaching
		-- AutoReverseDelay flips the direction.
		DirectionHold = 0,
		DirectionHoldProgress = 0, -- 0-1, so the dashboard can show the flip coming
		BrakeInput = 0, -- ramped pedal position, not the raw key
		GasInput = 0, -- likewise: ramped, so the car pulls away instead of lurching
		-- Set for one frame when a shift happens, so the caller can play a
		-- sound without the gearbox needing to know what a Sound is. The two
		-- are separate because they are different events with different
		-- sounds: the box changing its own gear, versus the car changing
		-- which way it is pointed.
		ShiftedThisFrame = false,
		DirectionChangedThisFrame = false,
	}
end

-- The gear currently PROVIDING drive, or nil while mid-shift.
local function activeGear(state, transmission)
	if state.ShiftTimeRemaining > 0 then
		return nil -- between gears: nothing is engaged
	end
	if state.Selector == "R" then
		return transmission.Reverse
	end
	return transmission.Gears[state.Gear]
end

local function startShift(state, transmission, targetGear)
	state.PendingGear = targetGear
	state.ShiftTimeRemaining = transmission.ShiftTime
	state.ShiftedThisFrame = true
end

-- Call once per physics frame, before VehiclePhysics.Step.
--   signedSpeed  studs/s along the car's own forward axis: positive means
--                travelling forwards, negative backwards. Signed, not
--                magnitude, because "am I still rolling forwards?" is
--                exactly the question the direction flip has to answer.
--   forwardKey   W is down
--   backKey      S is down
--
-- Returns the numbers Step wants, so the caller can splice them straight
-- into its input table.
function Gearbox.Update(state, config, delta, signedSpeed, forwardKey, backKey)
	local transmission = config.Transmission
	local gears = transmission.Gears
	state.ShiftedThisFrame = false
	state.DirectionChangedThisFrame = false

	local speed = math.abs(signedSpeed)

	if state.ShiftTimeRemaining > 0 then
		state.ShiftTimeRemaining -= delta
		if state.ShiftTimeRemaining <= 0 then
			state.ShiftTimeRemaining = 0
			state.Gear = state.PendingGear or state.Gear
			state.PendingGear = nil
		end
	end

	-- What the two keys mean right now. In D, W is the gas and S is the
	-- brake; in R they swap over. Everything below is written in terms of
	-- "go" and "stop" so neither the pedals nor the gearbox has to special
	-- case which way the car happens to be pointed.
	local goKey = if state.Selector == "D" then forwardKey else backKey
	local stopKey = if state.Selector == "D" then backKey else forwardKey

	-- Direction flip. The timer only runs while the car is genuinely stopped,
	-- so braking from speed always brakes first - the count does not even
	-- start until the car has come to rest, and only then does continuing to
	-- hold the key mean "and now go the other way". `not goKey` means holding
	-- both keys never flips you, it just brakes.
	if stopKey and not goKey and speed <= transmission.StoppedSpeed then
		state.DirectionHold += delta
		if state.DirectionHold >= transmission.AutoReverseDelay then
			state.Selector = if state.Selector == "D" then "R" else "D"
			-- Whatever gear the forward box was in is meaningless now.
			state.Gear = 1
			state.PendingGear = nil
			state.ShiftTimeRemaining = 0
			state.DirectionHold = 0
			state.DirectionChangedThisFrame = true
			-- Start the throttle ramp from closed. The car is at a dead stop
			-- with the key already held, which is precisely where an
			-- un-ramped launch would lurch hardest.
			state.GasInput = 0
			-- The key the player is holding has just changed meaning under
			-- them: the S that was braking is now the gas. Re-read both, so
			-- the car pulls away on this frame instead of sitting still until
			-- they let go and press it again.
			goKey = if state.Selector == "D" then forwardKey else backKey
			stopKey = if state.Selector == "D" then backKey else forwardKey
		end
	else
		state.DirectionHold = 0
	end
	state.DirectionHoldProgress = math.clamp(state.DirectionHold / math.max(transmission.AutoReverseDelay, 0.001), 0, 1)

	-- Brake wins over gas, so holding both is always the safe outcome.
	local targetGas = if goKey and not stopKey then 1 else 0
	local targetBrake = if stopKey then 1 else 0

	-- Pedal travel, both pedals. The keys are digital, so without this each
	-- one goes from nothing to maximum in a single frame: a tap of the brake
	-- reads as standing on it, and a press of the gas puts peak stall torque
	-- through the wheels instantly, which is the lurch. Releasing either is
	-- instant - a real pedal comes back up as fast as you lift your foot.
	if targetBrake > state.BrakeInput then
		state.BrakeInput = math.min(targetBrake, state.BrakeInput + delta / math.max(config.BrakeRampTime, 0.001))
	else
		state.BrakeInput = targetBrake
	end
	if targetGas > state.GasInput then
		state.GasInput = math.min(targetGas, state.GasInput + delta / math.max(config.ThrottleRampTime, 0.001))
	else
		state.GasInput = targetGas
	end
	local gas = state.GasInput

	-- Top speed of forward gear `index`, in studs/s.
	local function gearTopSpeed(index)
		return gears[index].SpeedFraction * config.MaxSpeed
	end

	-- Rolling to a halt drops straight back to first, with no shift time and
	-- no sound. Braking hard from top gear crosses every downshift threshold
	-- inside a fraction of a second, but each timed shift takes ShiftTime to
	-- complete - so the box would still be working its way down the gears
	-- long after the car had stopped, firing a shift sound each time. One
	-- audible downshift as you slow, then silently ready to pull away again.
	if state.Selector == "D" and state.Gear > 1 and speed < gearTopSpeed(1) * transmission.ShiftDownAt then
		state.Gear = 1
		state.PendingGear = nil
		state.ShiftTimeRemaining = 0
	end

	-- The automatic box. Only D has one (R is a single gear), and it only
	-- shifts while a gear is actually engaged, so a shift cannot be
	-- interrupted halfway by another one.
	if state.Selector == "D" and state.ShiftTimeRemaining == 0 then
		if state.Gear < #gears and speed >= gearTopSpeed(state.Gear) * transmission.ShiftUpAt then
			startShift(state, transmission, state.Gear + 1)
		elseif state.Gear > 1 and speed < gearTopSpeed(state.Gear - 1) * transmission.ShiftDownAt then
			-- Downshift is measured against the gear BELOW's top speed, not
			-- this gear's, which is what gives the two thresholds room between
			-- them. If they were measured against the same speed the box would
			-- sit on the boundary shifting up and down every other frame at a
			-- steady throttle.
			startShift(state, transmission, state.Gear - 1)
		end
	end

	local gear = activeGear(state, transmission)
	local gearMaxSpeed = if gear then gear.SpeedFraction * config.MaxSpeed else config.MaxSpeed

	-- Which gear the REVS are measured against. Mid-shift no gear is driving
	-- the car, but the engine is still spinning up to meet the one about to
	-- engage - so the revs track the incoming gear and get the dip below,
	-- rather than being measured against the car's whole speed range (which
	-- would read as an implausible plunge to idle on every single shift).
	local rpmGear = gear
	if not rpmGear then
		rpmGear = if state.Selector == "R"
			then transmission.Reverse
			else gears[state.PendingGear or state.Gear]
	end
	local rpmGearMaxSpeed = rpmGear.SpeedFraction * config.MaxSpeed

	-- Revs are measured against the speed this gear SHIFTS at, not the speed
	-- it would asymptotically top out at, so a gear reaches redline exactly
	-- as the box decides to leave it. Measured against the gear's top speed
	-- instead, the needle would sweep a narrow band in the middle of the
	-- range and never reach the top of the tacho in any gear, and the engine
	-- note would have nowhere near the same climb-and-drop shape.
	--
	-- The top gear and reverse are the exception: nothing shifts out of them,
	-- so they use their full speed range and redline at their own limit
	-- rather than pinning early and going flat for the rest of it.
	local isLastForwardGear = state.Selector == "D" and (state.PendingGear or state.Gear) >= #gears
	local rpmSpan = if isLastForwardGear or state.Selector == "R" then 1 else transmission.ShiftUpAt

	local targetRpm = math.clamp(speed / (math.max(rpmGearMaxSpeed, 1) * rpmSpan), 0, 1)
	-- Sitting on the gas at a standstill should still raise the revs,
	-- otherwise the engine sounds asleep for the first moment of a launch.
	targetRpm = math.max(targetRpm, transmission.IdleRpm + gas * 0.15)
	if state.ShiftTimeRemaining > 0 then
		-- Mid-shift the engine is unloaded, so the revs sag and then pick
		-- back up in the new gear - the audible half of a gear change.
		targetRpm *= transmission.ShiftRpmDrop
	end
	state.Rpm += (targetRpm - state.Rpm) * math.min(1, delta * transmission.RpmSmoothing)

	-- Torque converter: full StallTorqueMultiplier at a dead stop, fading to
	-- 1x by StallSpeed. This is what lets Torque be tuned low enough for
	-- gentle, deliberate acceleration without leaving the car unable to shove
	-- itself up a kerb from rest - the shove and the acceleration are no
	-- longer the same number.
	local converter = 1
	if gear then
		local fade = math.clamp(1 - speed / math.max(transmission.StallSpeed, 0.001), 0, 1)
		converter = 1 + (transmission.StallTorqueMultiplier - 1) * fade
	end

	return {
		-- Signed: holding S in reverse arrives at Step as a negative
		-- throttle. Zero whenever no gear is engaged, which is what actually
		-- cuts the power during a shift and makes it a pause rather than a
		-- ratio swap.
		Throttle = if gear then gas * SELECTOR_DIRECTION[state.Selector] else 0,
		Brake = state.BrakeInput,
		TorqueMultiplier = if gear then gear.Ratio * converter else 0,
		GearMaxSpeed = gearMaxSpeed,
		Rpm = state.Rpm,
	}
end

-- What the dashboard shows: "R", or the current forward gear's number in D.
-- Mid-shift it reads the gear being engaged, so the display leads the power
-- by a fraction of a second exactly like a real shift indicator.
function Gearbox.DisplayGear(state)
	if state.Selector == "R" then
		return "R"
	end
	return tostring(state.PendingGear or state.Gear)
end

return Gearbox

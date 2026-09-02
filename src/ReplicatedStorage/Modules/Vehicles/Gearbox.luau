-- The drivetrain between the player's pedals and VehiclePhysics.Step.
--
-- VehiclePhysics deliberately knows nothing about gears: it takes a signed
-- throttle, a torque multiplier and a top speed, and that's the entire
-- interface. Everything about WHICH gear that is - the R/N/D selector, the
-- automatic box inside D, the dead window during a shift, the revs the
-- engine sound follows - lives here, so the suspension/grip loop stays the
-- one thing it already was.
--
-- Two layers, and it matters that they're separate:
--   * The SELECTOR (R / N / D) is the player's, changed only by Q and E.
--   * The GEAR (1..#Gears) is the box's own business, and only exists inside
--     D. The player never picks it; it shifts itself on road speed.
--
-- Tuning lives in each car's Configs/<name>.luau under `Transmission` - see
-- VehiclePhysics.DefaultTransmission for what every key means.

local Gearbox = {}

-- Ordered low-to-high, which is what makes "E shifts up, Q shifts down" a
-- single index step rather than a lookup table of special cases.
local SELECTOR_ORDER = { "R", "N", "D" }
Gearbox.SelectorOrder = SELECTOR_ORDER

local SELECTOR_INDEX = {}
for index, name in SELECTOR_ORDER do
	SELECTOR_INDEX[name] = index
end

-- Which way the car is driven in each selector position. This is the whole
-- reason S no longer reverses: direction comes from the GEAR, never from the
-- pedal, so W is always "gas" and its sign is decided here.
local SELECTOR_DIRECTION = { R = -1, N = 0, D = 1 }

function Gearbox.new(config)
	local transmission = config.Transmission
	local starting = SELECTOR_INDEX[transmission.StartingGear] and transmission.StartingGear or "N"
	return {
		Selector = starting,
		Gear = 1, -- index into Transmission.Gears; only meaningful while Selector == "D"
		-- The gear the box is currently shifting INTO. Non-nil for exactly
		-- the ShiftTime window, during which no gear is engaged at all and
		-- drive torque is zero - that gap is the shift you hear and feel.
		PendingGear = nil,
		ShiftTimeRemaining = 0,
		Rpm = transmission.IdleRpm,
		-- Set for one frame whenever a shift starts, so the caller can play a
		-- sound without the gearbox needing to know what a Sound is.
		ShiftedThisFrame = false,
	}
end

-- Q and E. Returns true if the selector actually moved (so the caller only
-- plays the shift sound on a real change, not on Q held at the R end).
function Gearbox.ShiftSelector(state, direction)
	local index = SELECTOR_INDEX[state.Selector]
	local newIndex = math.clamp(index + direction, 1, #SELECTOR_ORDER)
	if newIndex == index then
		return false
	end

	state.Selector = SELECTOR_ORDER[newIndex]
	-- Any selector change drops the box back to first and cancels a shift in
	-- progress. Without the reset, going D -> N -> D at speed would re-engage
	-- whatever gear you happened to leave in, and going D -> R would leave a
	-- forward gear's ratio driving the car backwards.
	state.Gear = 1
	state.PendingGear = nil
	state.ShiftTimeRemaining = 0
	return true
end

-- The gear currently PROVIDING drive, or nil while mid-shift / in neutral.
local function activeGear(state, transmission)
	if state.ShiftTimeRemaining > 0 then
		return nil -- between gears: nothing is engaged
	end
	if state.Selector == "R" then
		return transmission.Reverse
	elseif state.Selector == "D" then
		return transmission.Gears[state.Gear]
	end
	return nil -- neutral
end

local function startShift(state, transmission, targetGear)
	state.PendingGear = targetGear
	state.ShiftTimeRemaining = transmission.ShiftTime
	state.ShiftedThisFrame = true
end

-- Call once per physics frame, before VehiclePhysics.Step. `speed` is the
-- car's road speed in studs/s (unsigned), `gas` is 0..1 from W.
--
-- Returns the drive numbers Step wants, so the caller can splice them
-- straight into its input table.
function Gearbox.Update(state, config, delta, speed, gas)
	local transmission = config.Transmission
	local gears = transmission.Gears
	state.ShiftedThisFrame = false

	if state.ShiftTimeRemaining > 0 then
		state.ShiftTimeRemaining -= delta
		if state.ShiftTimeRemaining <= 0 then
			state.ShiftTimeRemaining = 0
			state.Gear = state.PendingGear or state.Gear
			state.PendingGear = nil
		end
	end

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

	-- The automatic box. Only D has one - R is a single gear and N drives
	-- nothing - and it only shifts while a gear is actually engaged, so a
	-- shift can't be interrupted halfway by another one.
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
	if not rpmGear and state.Selector ~= "N" then
		rpmGear = if state.Selector == "R"
			then transmission.Reverse
			else gears[state.PendingGear or state.Gear]
	end
	local rpmGearMaxSpeed = if rpmGear then rpmGear.SpeedFraction * config.MaxSpeed else config.MaxSpeed

	-- Revs are measured against the speed this gear SHIFTS at, not the speed
	-- it would asymptotically top out at, so a gear reaches redline exactly
	-- as the box decides to leave it. Measured against the gear's top speed
	-- instead, the needle would sweep a narrow band in the middle of the
	-- range and never reach the top of the tacho in any gear, and the engine
	-- note would have nowhere near the same climb-and-drop shape.
	--
	-- The top gear and reverse are the exception: nothing shifts out of
	-- them, so they use their full speed range and redline at their own
	-- limit rather than pinning early and going flat for the rest of it.
	local isLastForwardGear = state.Selector == "D" and (state.PendingGear or state.Gear) >= #gears
	local rpmSpan = if isLastForwardGear or state.Selector == "R" then 1 else transmission.ShiftUpAt

	local targetRpm
	local revRate = transmission.RpmSmoothing
	if state.Selector == "N" then
		-- Out of gear the engine isn't tied to the wheels, so the pedal revs
		-- it directly - but capped well short of redline and climbing lazily.
		-- Revving to the limiter in N sounds identical to flooring it in gear,
		-- which reads as "the car is broken" rather than "you're in neutral";
		-- a low, slow, obviously-different note is the hint.
		targetRpm = math.max(transmission.IdleRpm, gas * transmission.NeutralMaxRpm)
		revRate = transmission.NeutralRevRate
	else
		targetRpm = math.clamp(speed / (math.max(rpmGearMaxSpeed, 1) * rpmSpan), 0, 1)
		-- Sitting on the gas at a standstill should still raise the revs,
		-- otherwise the engine sounds asleep for the first moment of a launch.
		targetRpm = math.max(targetRpm, transmission.IdleRpm + gas * 0.15)
		if state.ShiftTimeRemaining > 0 then
			-- Mid-shift the engine is unloaded, so the revs sag and then pick
			-- back up in the new gear - the audible half of a gear change.
			targetRpm *= transmission.ShiftRpmDrop
		end
	end
	state.Rpm += (targetRpm - state.Rpm) * math.min(1, delta * revRate)

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
		-- Signed: W in reverse arrives at Step as a negative throttle. Zero
		-- whenever no gear is engaged, which is what actually cuts the power
		-- during a shift and makes it a pause rather than a ratio swap.
		Throttle = if gear then gas * SELECTOR_DIRECTION[state.Selector] else 0,
		TorqueMultiplier = if gear then gear.Ratio * converter else 0,
		GearMaxSpeed = gearMaxSpeed,
		Rpm = state.Rpm,
	}
end

-- What the dashboard shows: "R", "N", or the current forward gear's number
-- in D. Mid-shift it reads the gear being engaged, so the display leads the
-- power by a fraction of a second exactly like a real shift indicator.
function Gearbox.DisplayGear(state)
	if state.Selector ~= "D" then
		return state.Selector
	end
	return tostring(state.PendingGear or state.Gear)
end

return Gearbox

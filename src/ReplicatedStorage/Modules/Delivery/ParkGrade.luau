-- Did the truck park in this bay, and how well?
--
-- Shared rather than server-only so a HUD can show the player the SAME grade
-- the server is about to pay them - "you're crooked" is only useful feedback
-- if it is the exact test that decides the money. The server still does the
-- deciding; this module is the rule, not the guard (the same split
-- VehicleOwnership's header describes).
--
-- HOW REVERSE PARKING IS DETECTED, because it looks too simple to work:
--
-- One dot product between the truck's forward and the bay's forward. No gear
-- tracking, no entry-direction state machine, no history. That is sufficient
-- because the GEOMETRY does the enforcing: a bay sized so a truck cannot turn
-- around inside it means the direction it is facing at rest is a complete
-- proof of the direction it came in. Build the bays tight (see
-- docs/CargoDesign.md section 4.3) and there is no exploit left to close.
--
-- The bay Part's FRONT face points OUT toward the road, so a truck that has
-- reversed in correctly faces the same way the bay does - hence a POSITIVE
-- dot for a reverse park, and negative for nose-in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)

local ParkGrade = {}

-- Height is deliberately ignored: only the footprint is tested.
--
-- A bay is a flat marker on the ground, not a garage, and the truck's bounding
-- box grows upward with cargo aboard (crates are part of the model). Testing
-- the vertical extent too would mean a tall load could not park anywhere,
-- which is a rule nobody would guess from looking at the bay.
--
-- Returns the SLACK in studs on the worst corner: how far the truck could move
-- outward before it stopped fitting. Positive means parked, negative means
-- that corner is hanging out by that much, and zero is exactly on the line.
--
-- A signed distance rather than a boolean because the depot's floor guide
-- (DepotGuides.client.luau) shades from red to green on how close the player
-- is to a legal park, and "how close" has to be the same measurement as "is
-- it in" or the guide goes green a moment before or after the board opens -
-- which is precisely the confusion the guide exists to prevent.
local function footprintSlack(carModel, spacePart)
	local boxCFrame, boxSize = carModel:GetBoundingBox()
	local halfX = spacePart.Size.X / 2 + DeliveryConfig.Parking.ContainmentTolerance
	local halfZ = spacePart.Size.Z / 2 + DeliveryConfig.Parking.ContainmentTolerance

	-- All eight corners, transformed into the bay's own frame. Corners rather
	-- than the centre point because a truck can sit with its middle nicely
	-- inside a bay while half its length hangs out into the road, and that
	-- should not count as parked.
	local worst = math.huge
	for _, x in { -0.5, 0.5 } do
		for _, y in { -0.5, 0.5 } do
			for _, z in { -0.5, 0.5 } do
				local corner = (boxCFrame * CFrame.new(boxSize.X * x, boxSize.Y * y, boxSize.Z * z)).Position
				local localPoint = spacePart.CFrame:PointToObjectSpace(corner)
				worst = math.min(worst, halfX - math.abs(localPoint.X), halfZ - math.abs(localPoint.Z))
			end
		end
	end
	return worst
end

-- Is this chassis parked rather than merely slow?
--
-- HORIZONTAL AND VERTICAL SPEED ARE JUDGED SEPARATELY, and that is the whole
-- content of this function - see DeliveryConfig.Parking.StoppedVerticalSpeed
-- for the long version. Briefly: a loaded car sitting on a raycast suspension
-- bobs, `AssemblyLinearVelocity.Magnitude` folds that bob into one number, and
-- every caller below then flickers in time with the springs.
--
-- It lives HERE, next to the geometry, for the same reason Evaluate does: the
-- HUD, the tutorial and the server's payout all have to give the same answer
-- to "is it parked", and they were each asking it in their own inlined line.
-- Three copies of a rule is three chances to fix it in two places.
function ParkGrade.IsStopped(chassis)
	if not chassis then
		return false
	end
	local velocity = chassis.AssemblyLinearVelocity
	local parking = DeliveryConfig.Parking
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	return horizontal <= parking.StoppedSpeed and math.abs(velocity.Y) <= parking.StoppedVerticalSpeed
end

-- 0 when the truck is ApproachStuds or more outside the bay, rising to 1 the
-- instant it is fully inside. 1 therefore means EXACTLY "Evaluate would say
-- Inside", which is what makes it safe to drive a go/no-go colour from.
function ParkGrade.Approach(carModel, spacePart)
	if not carModel.PrimaryPart then
		return 0
	end
	local slack = footprintSlack(carModel, spacePart)
	if slack >= 0 then
		return 1
	end
	local reach = math.max(DeliveryConfig.Guides.ApproachStuds, 0.001)
	return math.clamp(1 + slack / reach, 0, 1)
end

-- `Inside` false means everything else in the result is meaningless - a truck
-- that is not in the bay has no alignment to speak of. Callers should check it
-- first and ignore the rest.
--
-- Returns a table rather than several values so a HUD can show partial
-- feedback ("inside, but crooked") without the caller having to remember which
-- of five return values was which.
function ParkGrade.Evaluate(carModel, spacePart)
	local chassis = carModel.PrimaryPart
	if not chassis then
		return { Inside = false }
	end

	if footprintSlack(carModel, spacePart) < 0 then
		return { Inside = false }
	end

	-- Positive = the truck faces the same way the bay does = it backed in.
	local facing = chassis.CFrame.LookVector:Dot(spacePart.CFrame.LookVector)
	local alignment = math.abs(facing) -- 1 is dead square, 0 is sideways across the bay
	local threshold = DeliveryConfig.Parking.AlignmentThreshold

	-- How centred across the bay's width, 0-1. Uses the chassis position
	-- rather than the bounding box, because the box grows with cargo and
	-- "centred" should mean the truck, not its load.
	local halfWidth = math.max(spacePart.Size.X / 2, 0.001)
	local lateral = math.abs(spacePart.CFrame:PointToObjectSpace(chassis.Position).X)
	local centering = math.clamp(1 - lateral / halfWidth, 0, 1)

	local squareEnough = alignment >= threshold
	local reversed = squareEnough and facing > 0

	local label
	if not squareEnough then
		label = "Crooked"
	elseif reversed then
		label = "Reverse Park"
	else
		label = "Nose In"
	end

	return {
		Inside = true,
		-- Square enough to be judged at all. A crooked park still delivers -
		-- it just earns nothing above the base rate, which reads as "you made
		-- it, but scruffy" rather than as a failure.
		SquareEnough = squareEnough,
		Reversed = reversed,
		Alignment = alignment,
		Centering = centering,
		Label = label,
	}
end

-- The grade, as money. Kept separate from Evaluate so the geometry can be
-- unit-checked and tuned without dragging the payout table into it, and so a
-- HUD can preview the multiplier before the truck is even stopped.
function ParkGrade.Multiplier(grade)
	local payout = DeliveryConfig.Payout
	if not grade or not grade.Inside then
		return 0
	end
	if not grade.SquareEnough then
		return payout.NoseInMultiplier
	end

	local base = if grade.Reversed then payout.ReverseMultiplier else payout.NoseInMultiplier

	-- Precision is scored from how far PAST the alignment threshold the truck
	-- is, not from the raw dot product: a truck at exactly the threshold has
	-- earned none of this bonus, and one that is dead square has earned all of
	-- it. Scoring the raw dot would hand out most of the bonus for merely
	-- qualifying.
	local threshold = DeliveryConfig.Parking.AlignmentThreshold
	local alignmentScore = math.clamp((grade.Alignment - threshold) / math.max(1 - threshold, 0.001), 0, 1)
	-- Weighted toward alignment: being straight is the hard part in first
	-- person, and being centred largely follows from it.
	local precision = alignmentScore * 0.65 + grade.Centering * 0.35

	return base + payout.PrecisionBonus * precision
end

return ParkGrade

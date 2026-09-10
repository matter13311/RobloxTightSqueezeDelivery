-- The rattle/squeak the suspension makes going over a small bump. Split out
-- from VehicleCrashSounds for the same reason VehicleRunOverSounds is: a
-- squeak isn't a crash or a scrape, it's its own category with its own
-- trigger (see the bump check in VehicleCrashDetector.client.luau), so it
-- gets its own short list rather than being folded into Impact or Scrape.
--
-- Content, not behaviour - everything about WHEN a bump counts as a bump
-- (the threshold, the debounce) lives in VehicleCollision (BumpMinDeltaV,
-- BumpCooldown). This file is only the sounds themselves.
--
-- HOW TO ADD SOUNDS
--
-- Paste ids into the list below. Order does not matter and the list can be
-- any length, including one. An empty list means silence, which is a
-- legitimate way to turn the feature off while you find better sounds.

local VehicleSqueakSounds = {}

VehicleSqueakSounds.Squeak = {
	"rbxassetid://9113389822",
	"rbxassetid://9125465948",
	"rbxassetid://9113389852",
	"rbxassetid://9113389530",
	"rbxassetid://9113969922",
	"rbxassetid://9113970059",
	"rbxassetid://9125465758",
}

-- Returns nil for an empty list, which the caller treats as "play nothing"
-- rather than as an error - same convention as VehicleCrashSounds.Pick.
function VehicleSqueakSounds.Pick(list)
	local count = #list
	if count == 0 then
		return nil
	end
	if count == 1 then
		return list[1]
	end
	return list[math.random(count)]
end

function VehicleSqueakSounds.PickSqueak()
	return VehicleSqueakSounds.Pick(VehicleSqueakSounds.Squeak)
end

return VehicleSqueakSounds

-- Every sound the crash system can play, and the rule for picking one.
--
-- Split out from VehicleCollision (which is physics tuning) because these are
-- content, not behaviour: adding a fifth crunch to the list should never mean
-- opening a file full of impulse thresholds. Everything here is client-side -
-- the server never plays a sound, it only decides what happened.
--
-- HOW TO ADD SOUNDS
--
-- Paste ids into the lists below. Order does not matter and the lists can be
-- any length, including one. An empty list means silence for that category,
-- which is a legitimate way to turn a sound off while you find a better one.
--
-- The ids already here are a starting point and only the impact one has been
-- checked in-game; treat the rest as placeholders until you have heard them.

local VehicleCrashSounds = {}

--=============================================================================
-- Impacts
--=============================================================================

-- Played once per crash, at the point of contact. Volume and pitch are already
-- scaled by how hard the hit was (see VehicleCrashDetector), so these want to
-- be neutral recordings rather than pre-mixed loud and quiet versions - a
-- variety of crunches, not a variety of volumes.
VehicleCrashSounds.Impact = {
	"rbxassetid://101983913427550",
	"rbxassetid://9126155907",
	"rbxassetid://9116673678",
	"rbxassetid://9116673678",
}

--=============================================================================
-- Scrapes
--=============================================================================

-- These LOOP for as long as the truck is grinding along a surface, so they
-- want to be seamless. One is chosen when a scrape starts and kept for the
-- whole scrape - re-rolling per frame would machine-gun the audio, and
-- re-rolling per report would audibly cut every quarter second.
VehicleCrashSounds.Scrape = {
	"rbxassetid://95131309951094",
	"rbxassetid://136913781328946",
	"rbxassetid://122458521275506",
}

--=============================================================================
-- Picking
--=============================================================================

-- Returns nil for an empty list, which every caller treats as "play nothing"
-- rather than as an error - a missing sound should never stop a crash being
-- registered or damage being applied.
function VehicleCrashSounds.Pick(list)
	local count = #list
	if count == 0 then
		return nil
	end
	if count == 1 then
		return list[1]
	end
	return list[math.random(count)]
end

function VehicleCrashSounds.PickImpact()
	return VehicleCrashSounds.Pick(VehicleCrashSounds.Impact)
end

function VehicleCrashSounds.PickScrape()
	return VehicleCrashSounds.Pick(VehicleCrashSounds.Scrape)
end

return VehicleCrashSounds

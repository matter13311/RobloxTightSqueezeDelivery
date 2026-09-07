-- Every sound that can play when a vehicle runs over a player, and the rule
-- for picking one.
--
-- Split out the same way VehicleCrashSounds is (see that file): this is
-- content, not behaviour, so adding a fifth "oof" should never mean opening a
-- file full of knockdown physics. The server never plays a sound, it only
-- decides that a knockdown happened and where - VehiclePlayerImpact.server.luau
-- fires VehicleRunOverSound to every client, and each client picks an id from
-- here and plays it locally as a positioned 3D sound so only players near the
-- hit actually hear it.
--
-- HOW TO ADD SOUNDS
--
-- Paste ids into the list below. Order does not matter and the list can be
-- any length, including one. An empty list means silence, which is a
-- legitimate way to turn this off while you find better sounds.

local VehicleRunOverSounds = {}

--=============================================================================
-- Run-overs
--=============================================================================

-- Played once per knockdown, at the victim's position. One is chosen at
-- random per hit so the same "oof" doesn't repeat every time.
VehicleRunOverSounds.RunOver = {
	"rbxassetid://120386612887769",
	"rbxassetid://137041944943141",
	"rbxassetid://7672649705",
	"rbxassetid://160718677",
}

--=============================================================================
-- Picking
--=============================================================================

-- Returns nil for an empty list, which the caller treats as "play nothing"
-- rather than as an error - a missing sound should never stop a knockdown
-- from registering.
function VehicleRunOverSounds.Pick(list)
	local count = #list
	if count == 0 then
		return nil
	end
	if count == 1 then
		return list[1]
	end
	return list[math.random(count)]
end

function VehicleRunOverSounds.PickRunOver()
	return VehicleRunOverSounds.Pick(VehicleRunOverSounds.RunOver)
end

return VehicleRunOverSounds

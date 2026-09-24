-- Drives the city's clock. The only writer of Lighting in the running game -
-- see ReplicatedStorage.Modules.World.DayNight for the schedule itself and
-- for why the clock is synchronised wall time rather than server uptime.
--
-- SERVER-AUTHORITATIVE, for the same reason the headlight switches are: every
-- Lighting property set here replicates to every client identically, so there
-- is exactly one time of day and nobody can be standing in a different one. A
-- client running its own clock would drift, and two players on a night
-- delivery would disagree about whether the streetlamps were lit.
--
-- UPDATED AT 2Hz, NOT EVERY FRAME. A full cycle turns the sun 360 degrees in
-- 20 minutes, which is 0.3 degrees a second - so a half-second step moves it
-- 0.15 degrees, far below anything the eye can catch, while replicating the
-- Lighting properties 120 times a minute instead of thousands.
--
-- TESTING. Set a number attribute "DayNightOverride" on Lighting to pin the
-- clock there and stop the cycle:
--
--   game:GetService("Lighting"):SetAttribute("DayNightOverride", 23)
--
-- Clear the attribute to hand it back to the schedule. Nothing else reads it,
-- so leaving it set in a published place would freeze time - it's a command
-- bar convenience, not a feature.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DayNight = require(ReplicatedStorage.Modules.World.DayNight)

local OVERRIDE_ATTRIBUTE = "DayNightOverride"
local UPDATE_INTERVAL = 0.5

local function currentClockTime()
	local override = Lighting:GetAttribute(OVERRIDE_ATTRIBUTE)
	if type(override) == "number" and override == override then
		return override % 24
	end
	return DayNight.ClockTimeAt(workspace:GetServerTimeNow())
end

-- Applied once up front rather than waiting out the first interval, so a
-- server that starts at night is never briefly bright for the players who
-- joined first.
DayNight.Apply(Lighting, currentClockTime())

local sinceUpdate = 0
RunService.Heartbeat:Connect(function(deltaTime)
	sinceUpdate += deltaTime
	if sinceUpdate < UPDATE_INTERVAL then
		return
	end
	sinceUpdate = 0
	DayNight.Apply(Lighting, currentClockTime())
end)

-- An override typed into the command bar mid-session should take effect at
-- once, not up to half a second later - and, more importantly, clearing it
-- should hand control straight back rather than leaving time pinned until the
-- next tick happens to notice.
Lighting:GetAttributeChangedSignal(OVERRIDE_ATTRIBUTE):Connect(function()
	DayNight.Apply(Lighting, currentClockTime())
end)

-- The day/night schedule: what time it is, how dark that is, and what the
-- Lighting service should look like at that darkness.
--
-- Pure maths and presets only - no state, no connections. DayNight.server.luau
-- drives it (it owns Lighting), and any client that needs to know whether it's
-- dark asks NightFactor about the already-replicated Lighting.ClockTime rather
-- than running a clock of its own. There is deliberately no "current time"
-- function here that reads a clock itself: one owner, one writer.
--
-- WHY THE CLOCK IS WALL TIME AND NOT SERVER UPTIME. Progress comes from
-- workspace:GetServerTimeNow(), which is synchronised across every server in
-- the game, so every player in every server is at the same point in the same
-- day. A freshly started server drops the player into whatever time it
-- currently is, rather than always restarting at dawn - which also means the
-- city isn't stuck in perpetual daylight for anyone who only ever joins fresh
-- servers.
--
-- NIGHT IS SHORTER IN REAL TIME THAN IT IS IN GAME HOURS. The clock covers 13
-- game-hours of daylight (06:00-19:00) and 11 of darkness, but daylight gets
-- 65% of the real cycle and darkness 35% - so the night hours simply tick past
-- faster. Players still see a full night, it just doesn't outstay its welcome
-- in a game that's about being able to see where you're driving.

local DayNight = {}

-- A full 24-hour clock in this many real seconds.
DayNight.CYCLE_SECONDS = 20 * 60

-- The daylight arc, in clock hours, and the share of the real cycle it gets.
local DAY_START = 6
local DAY_END = 19
local DAY_SHARE = 0.65

local DAY_HOURS = DAY_END - DAY_START -- 13
local NIGHT_HOURS = 24 - DAY_HOURS -- 11

-- Where the light actually changes, in clock hours. These are deliberately
-- inside the DAY_START/DAY_END arc rather than equal to it: the sun is still
-- up at 18:00 but the light has already begun to go, and that overlap is what
-- makes dusk read as dusk instead of a switch being thrown.
local DUSK_FROM, DUSK_TO = 17.5, 19.5
local DAWN_FROM, DAWN_TO = 5.0, 7.0

-- Smoothstep, so dusk eases in and out instead of ramping linearly - a linear
-- fade has visible corners at both ends where the rate of change snaps.
local function smoothstep(edge0, edge1, x)
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Clock hour (0-24) at a given point in the cycle. `seconds` is any
-- continuously increasing clock - it's taken modulo the cycle length, so
-- callers never have to wrap it themselves.
function DayNight.ClockTimeAt(seconds)
	local progress = (seconds % DayNight.CYCLE_SECONDS) / DayNight.CYCLE_SECONDS
	if progress < DAY_SHARE then
		return DAY_START + (progress / DAY_SHARE) * DAY_HOURS
	end
	local nightProgress = (progress - DAY_SHARE) / (1 - DAY_SHARE)
	return (DAY_END + nightProgress * NIGHT_HOURS) % 24
end

-- How dark it is: 0 is full daylight, 1 is the middle of the night. Everything
-- else here is a blend between the two presets on this one number, so the
-- lighting can never disagree with itself about what time it is.
function DayNight.NightFactor(clockTime)
	if clockTime >= DUSK_TO or clockTime <= DAWN_FROM then
		return 1 -- deep night, either side of midnight
	elseif clockTime >= DUSK_FROM then
		return smoothstep(DUSK_FROM, DUSK_TO, clockTime)
	elseif clockTime <= DAWN_TO then
		return 1 - smoothstep(DAWN_FROM, DAWN_TO, clockTime)
	end
	return 0
end

-- Past this, street lamps come on and a car wants its headlights. Set at the
-- point where the fade is clearly under way rather than at 0 (every lamp in
-- the city would pop on the instant the sun started to move) or at 1 (they'd
-- only arrive once it was already too dark to need telling).
DayNight.LAMP_THRESHOLD = 0.35

-- Is it dark enough that a driver would reasonably have the lights on?
function DayNight.IsDark(clockTime)
	return DayNight.NightFactor(clockTime) >= DayNight.LAMP_THRESHOLD
end

-- The two ends of the blend. DAY is the lighting the place file already ships
-- with (see default.project.json and the Atmosphere in Lighting), so midday
-- looks exactly as it did before any of this existed.
--
-- Ambient is 0 in BOTH presets and is not blended. Ambient lifts the shadowed
-- side of everything, indoors included, so raising it at night to make the
-- streets readable would also flood the cabs, the tunnels and the terminal
-- with light that has no source - and the cab lights (VehicleLights'
-- interior rig) exist precisely because those spaces are meant to be dark.
-- Street readability comes from OutdoorAmbient, which only touches what can
-- see the sky.
local DAY = {
	OutdoorAmbient = Color3.fromRGB(70, 70, 70),
	Brightness = 2,
	AtmosphereColor = Color3.fromRGB(199, 199, 199),
	AtmosphereDecay = Color3.fromRGB(106, 112, 125),
	AtmosphereDensity = 0.3,
	AtmosphereHaze = 0,
}

local NIGHT = {
	OutdoorAmbient = Color3.fromRGB(38, 42, 58), -- cool and low: shapes read, detail doesn't
	Brightness = 0.55,
	AtmosphereColor = Color3.fromRGB(30, 34, 50),
	AtmosphereDecay = Color3.fromRGB(18, 22, 38),
	AtmosphereDensity = 0.42,
	AtmosphereHaze = 0.6, -- a little murk so distant lamps glow rather than sit as hard dots
}

-- Writes the whole lighting state for `clockTime` onto the Lighting service.
-- Idempotent and absolute - it never reads the current values and nudges them,
-- so a dropped update, a Studio edit or a rejoining player can't leave the
-- lighting drifted away from what the clock says it should be.
function DayNight.Apply(lighting, clockTime)
	local night = DayNight.NightFactor(clockTime)

	lighting.ClockTime = clockTime
	lighting.OutdoorAmbient = DAY.OutdoorAmbient:Lerp(NIGHT.OutdoorAmbient, night)
	lighting.Brightness = DAY.Brightness + (NIGHT.Brightness - DAY.Brightness) * night

	-- The Atmosphere is authored in the place file and is optional here: a
	-- place stripped of it still gets a working cycle, just a flatter horizon.
	local atmosphere = lighting:FindFirstChildWhichIsA("Atmosphere")
	if atmosphere then
		atmosphere.Color = DAY.AtmosphereColor:Lerp(NIGHT.AtmosphereColor, night)
		atmosphere.Decay = DAY.AtmosphereDecay:Lerp(NIGHT.AtmosphereDecay, night)
		atmosphere.Density = DAY.AtmosphereDensity + (NIGHT.AtmosphereDensity - DAY.AtmosphereDensity) * night
		atmosphere.Haze = DAY.AtmosphereHaze + (NIGHT.AtmosphereHaze - DAY.AtmosphereHaze) * night
	end
end

return DayNight

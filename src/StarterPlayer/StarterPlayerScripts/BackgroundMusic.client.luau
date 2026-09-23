-- Loops a single background music track for the whole session, at the volume
-- the player picked in Settings (GameSettings' "Music volume" slider, under
-- the Audio category). Lives outside SoundService/positional audio - this is
-- ambient music, not a cue tied to any part in the world.
--
-- STARTS SILENT ON PURPOSE. GameSettings' "MusicVolume" reads as its default
-- (20%) until SettingsPersistence's round trip applies the player's real
-- saved value - and unlike the join LoadingScreen's visual cover, sound
-- isn't hidden by anything, so playing at the default and then jumping to
-- the real value is audible even while that cover is still up. Instead the
-- music plays at Volume 0 until BOTH the player's real settings are known
-- (GameSettings.Ready) AND the loading screen has finished (LoadingGate) -
-- whichever comes last - and only then jumps once, straight to the correct
-- volume, with the cover either still fully opaque or already gone.
local SoundService = game:GetService("SoundService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local GameSettings = require(script.Parent:WaitForChild("GameSettings"))
local LoadingGate = require(ReplicatedFirst:WaitForChild("LoadingGate"))

local MUSIC_SOUND_ID = "rbxassetid://1845341094"

local musicSound = Instance.new("Sound")
musicSound.Name = "BackgroundMusic"
musicSound.SoundId = MUSIC_SOUND_ID
musicSound.Looped = true
musicSound.Volume = 0
musicSound.Parent = SoundService
musicSound:Play()

local settingsReady = false
local loadingDone = false

local function applyRealVolume()
	if settingsReady and loadingDone then
		musicSound.Volume = GameSettings.Get("MusicVolume") / 100
	end
end

GameSettings.OnReady(function()
	settingsReady = true
	applyRealVolume()
end)

LoadingGate.OnFinished(function()
	loadingDone = true
	applyRealVolume()
end)

-- Live updates once the player actually opens Settings and drags the
-- slider. Ignored before settingsReady so ApplySaved's own initial fire
-- (still the default, the instant before the real value lands) can't sneak
-- the volume up early.
GameSettings.OnChanged(function(key, value)
	if key == "MusicVolume" and settingsReady then
		musicSound.Volume = value / 100
	end
end)

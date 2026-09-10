-- Loops a single background music track for the whole session, at the volume
-- the player picked in Settings (GameSettings' "Music volume" slider, under
-- the Audio category). Lives outside SoundService/positional audio - this is
-- ambient music, not a cue tied to any part in the world.

local SoundService = game:GetService("SoundService")

local GameSettings = require(script.Parent:WaitForChild("GameSettings"))

local MUSIC_SOUND_ID = "rbxassetid://1845341094"

local musicSound = Instance.new("Sound")
musicSound.Name = "BackgroundMusic"
musicSound.SoundId = MUSIC_SOUND_ID
musicSound.Looped = true
musicSound.Volume = GameSettings.Get("MusicVolume") / 100
musicSound.Parent = SoundService
musicSound:Play()

GameSettings.OnChanged(function(key, value)
	if key == "MusicVolume" then
		musicSound.Volume = value / 100
	end
end)

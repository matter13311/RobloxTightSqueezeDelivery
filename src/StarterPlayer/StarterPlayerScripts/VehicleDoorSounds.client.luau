-- Plays the door open/close cue for whichever player just triggered it
-- (entering or exiting a car) - see VehicleDoors.server.luau, which fires
-- this only to that one player rather than broadcasting it, so nobody else
-- hears a door they didn't touch. Sounds are created here on the client, one
-- per play, and left to clean themselves up - same reasoning as the
-- transient sounds in RayCastSuspension.client.luau.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local ContentProvider = game:GetService("ContentProvider")

local DOOR_OPEN_SOUND_ID = "rbxassetid://139882610901041"
local DOOR_CLOSE_SOUND_ID = "rbxassetid://121381393291287"
local DOOR_SOUND_VOLUME = 0.6
local SOUND_CLEANUP_TIME = 10 -- generous fallback in case SoundId fails to load and Ended never fires

local playDoorSound = ReplicatedStorage:WaitForChild("PlayDoorSound")

-- A Sound's first Play() has to actually stream the asset in before anything
-- is audible, which is what made the door look like it was already
-- mid-swing before you heard it open/close. Preloading here (once, at
-- script start) means by the time a door is actually used, the asset is
-- already cached and Play() is instant.
task.spawn(function()
	ContentProvider:PreloadAsync({ DOOR_OPEN_SOUND_ID, DOOR_CLOSE_SOUND_ID })
end)

-- `at` is whatever the server said the door is: since doors stopped swinging
-- that is an Exit Attachment on the chassis rather than a door part. A Sound
-- parented to an Attachment plays at that attachment's world position, so the
-- cue still comes from the correct side of the truck - and unlike a door
-- panel, an attachment cannot be knocked off in a crash and take the audio
-- with it. BasePart is still accepted so nothing else that fires this needs
-- changing.
playDoorSound.OnClientEvent:Connect(function(at, action)
	if typeof(at) ~= "Instance" or not (at:IsA("BasePart") or at:IsA("Attachment")) then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = if action == "Open" then DOOR_OPEN_SOUND_ID else DOOR_CLOSE_SOUND_ID
	sound.Volume = DOOR_SOUND_VOLUME
	sound.RollOffMaxDistance = 50
	sound.Parent = at
	sound:Play()

	sound.Ended:Once(function()
		sound:Destroy()
	end)
	Debris:AddItem(sound, SOUND_CLEANUP_TIME)
end)

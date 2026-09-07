-- Plays the "somebody just got run over" sound.
--
-- The server (VehiclePlayerImpact.server.luau) only decides that a knockdown
-- happened and where; it fires VehicleRunOverSound to every client, and each
-- client picks its own id from VehicleRunOverSounds and plays it locally as a
-- positioned 3D sound. That's what makes it audible to everyone near the hit
-- and not to the whole server - same split VehicleCrashDetector uses for
-- crash sounds, copied here rather than shared because knocking a pedestrian
-- down has nothing to do with that file's crash-measuring session.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleRunOverSounds = require(ReplicatedStorage.Modules.Vehicles.VehicleRunOverSounds)

local runOverSoundRemote = ReplicatedStorage:WaitForChild("VehicleRunOverSound")

local function playRunOverSound(position)
	local soundId = VehicleRunOverSounds.PickRunOver()
	if not soundId then
		return
	end

	-- A throwaway anchored part to hang the sound on, positioned at the
	-- victim rather than riding along with them or the truck.
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.Position = position
	holder.Parent = workspace

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.RollOffMaxDistance = 100
	sound.Parent = holder
	sound:Play()

	Debris:AddItem(holder, 4)
end

runOverSoundRemote.OnClientEvent:Connect(playRunOverSound)

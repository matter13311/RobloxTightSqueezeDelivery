-- Lets other client scripts hold off on anything a player would notice - most
-- importantly background music volume - until the join LoadingScreen has
-- actually finished covering the screen.
--
-- WHY THIS EXISTS. The loading screen only covers what's on screen; it does
-- nothing to sound. If music starts at its default volume and then jumps to
-- the player's saved volume the moment their settings finish loading, that
-- jump is audible even while the cover is still up, and often lands again
-- right as the cover fades - either way it reads as a glitch. Anything that
-- wants to change abruptly should wait for this gate instead of reacting the
-- instant its data is ready.
--
-- Lives in ReplicatedFirst next to LoadingScreen so it is guaranteed to exist
-- before any StarterPlayerScripts require it.

local LoadingGate = {}
LoadingGate.Finished = false

local signal = Instance.new("BindableEvent")

-- Called once by LoadingScreen.client.luau when the cover is about to lift.
-- Idempotent so a stray second call can't fire listeners twice.
function LoadingGate.MarkFinished()
	if LoadingGate.Finished then
		return
	end
	LoadingGate.Finished = true
	signal:Fire()
end

-- Yields the calling thread until the gate is open. Returns immediately if
-- it already is.
function LoadingGate.WaitForFinish()
	if LoadingGate.Finished then
		return
	end
	signal.Event:Wait()
end

-- Fires callback once, either now (already open) or the moment it opens.
function LoadingGate.OnFinished(callback)
	if LoadingGate.Finished then
		callback()
		return
	end
	local connection
	connection = signal.Event:Connect(function()
		connection:Disconnect()
		callback()
	end)
end

return LoadingGate

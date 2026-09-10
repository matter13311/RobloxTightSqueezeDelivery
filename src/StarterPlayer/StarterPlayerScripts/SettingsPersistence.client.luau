-- Makes GameSettings survive leaving and rejoining.
--
-- On join: fetches the saved table through GetPlotData (the round trip every
-- client already makes - see PlotManager) and applies it. On change: sends the
-- whole value table to the server, debounced, where it rides along with the
-- rest of the save (PlayerDataStore's Settings field).
--
-- NOTHING IS SENT UNTIL THE LOAD HAS ANSWERED. A change made in the first
-- seconds of a session - or the load simply being slow - would otherwise send
-- the defaults up and overwrite the real saved settings with them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameSettings = require(script.Parent:WaitForChild("GameSettings"))

local getPlotDataFunction = ReplicatedStorage:WaitForChild("GetPlotData")
local saveSettingsEvent = ReplicatedStorage:WaitForChild("SaveSettings")

-- Short enough that a player who changes something and leaves straight away is
-- still saved; long enough that dragging a slider sends one update, not fifty.
local SAVE_DEBOUNCE = 1

-- Same retry shape as TutorialGuide's startup fetch: the server answers nil
-- while this player's save is still loading.
local LOAD_RETRY_INTERVAL = 1
local LOAD_TIMEOUT = 30

local loaded = false
local saveToken = 0

local function scheduleSave()
	if not loaded then
		return
	end
	saveToken += 1
	local token = saveToken
	task.delay(SAVE_DEBOUNCE, function()
		if token == saveToken then
			saveSettingsEvent:FireServer(GameSettings.GetSavedValues())
		end
	end)
end

GameSettings.OnChanged(scheduleSave)

task.spawn(function()
	local waited = 0
	while waited < LOAD_TIMEOUT do
		local ok, data = pcall(function()
			return getPlotDataFunction:InvokeServer()
		end)
		if ok and type(data) == "table" then
			GameSettings.ApplySaved(data.Settings)
			loaded = true
			return
		end
		waited += LOAD_RETRY_INTERVAL
		task.wait(LOAD_RETRY_INTERVAL)
	end
	-- Gave up: this session runs on defaults and never saves, so whatever is
	-- stored stays intact for next time.
end)

-- The player is leaving with a save still pending in the debounce: fire it
-- now. Best effort - the client may already be disconnecting.
Players.LocalPlayer.AncestryChanged:Connect(function(_, parent)
	if parent == nil and loaded then
		saveSettingsEvent:FireServer(GameSettings.GetSavedValues())
	end
end)

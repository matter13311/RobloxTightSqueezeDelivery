-- Client-side player settings: the values, their defaults, and the schema the
-- menu builds itself from.
--
-- Adding a setting is meant to be a one-place change: append an entry to
-- DEFINITIONS and the menu grows a row for it automatically, in the right
-- category, with the right control. SettingsMenu never names an individual
-- setting, so it does not need touching. Whatever consumes the value reads it
-- with GameSettings.Get(key).
--
-- These are display/comfort options that only affect what this client draws,
-- so nothing here replicates and nothing needs the server's permission. A
-- setting that changed gameplay would not belong here.
--
-- Values live for the session only. Persisting them across joins needs a
-- DataStore round-trip through the server, which is a bigger change than it
-- looks (the client has no storage of its own) and is deliberately not done
-- here yet.

local GameSettings = {}

-- Type is what control the menu draws:
--   "Toggle"  a checkbox. Default is a boolean.
--   "Slider"  a dragged bar. Needs Min, Max and Step; Default is a number.
--
-- Format is optional and only cosmetic - it turns the raw value into the text
-- shown beside the control. Without it the number is shown bare.
local DEFINITIONS = {
	{
		Category = "Mirrors",
		Key = "MirrorsEnabled",
		Label = "Enable mirrors",
		Description = "Turn the live side and rear-view mirrors off entirely. The single biggest thing you can do for framerate on a weak machine.",
		Type = "Toggle",
		Default = true,
	},
	{
		Category = "Mirrors",
		Key = "MirrorRenderDistance",
		Label = "Render distance",
		Description = "How far behind the car the mirrors LOOK for things to show. This only sets the search radius - if Detail below is already full, raising this alone changes nothing, because the nearest objects still win the slots.",
		Type = "Slider",
		Min = 80,
		Max = 600,
		Step = 20,
		Default = 320,
		Format = function(value)
			return string.format("%d studs", value)
		end,
	},
	{
		Category = "Mirrors",
		Key = "MirrorDetail",
		Label = "Detail",
		Description = "How many objects each mirror may show at once, nearest first. The main performance control, and the one to raise if things are missing from the mirror at a distance you can already see.",
		Type = "Slider",
		Min = 60,
		Max = 400,
		Step = 20,
		Default = 260,
		Format = function(value)
			return string.format("%d objects", value)
		end,
	},
	{
		Category = "Mirrors",
		Key = "MirrorRefreshRate",
		Label = "Refresh rate",
		Description = "How often each mirror re-checks what is behind you. This is NOT the frame rate of the mirror - what is already in view moves every frame regardless. Lower only makes things appear and disappear slightly later.",
		Type = "Slider",
		Min = 1,
		Max = 15,
		Step = 1,
		Default = 5,
		Format = function(value)
			return string.format("%d / sec", value)
		end,
	},
}

-- Category order in the menu. Anything not listed is appended alphabetically,
-- so a new category still shows up without being registered here.
local CATEGORY_ORDER = { "Mirrors" }

local values = {}
local byKey = {}
for _, definition in DEFINITIONS do
	values[definition.Key] = definition.Default
	byKey[definition.Key] = definition
end

local listeners = {}

local function clampToDefinition(definition, value)
	if definition.Type == "Toggle" then
		return value and true or false
	end
	local number = tonumber(value)
	if not number then
		return definition.Default
	end
	if definition.Step and definition.Step > 0 then
		number = math.round(number / definition.Step) * definition.Step
	end
	return math.clamp(number, definition.Min, definition.Max)
end

function GameSettings.GetDefinitions()
	return DEFINITIONS
end

function GameSettings.GetCategoryOrder()
	return CATEGORY_ORDER
end

function GameSettings.Get(key)
	return values[key]
end

-- Silently ignores an unknown key rather than erroring: a setting being removed
-- should not break whatever was still reading it.
function GameSettings.Set(key, value)
	local definition = byKey[key]
	if not definition then
		return
	end
	local clamped = clampToDefinition(definition, value)
	if values[key] == clamped then
		return
	end
	values[key] = clamped
	for _, listener in listeners do
		listener(key, clamped)
	end
end

-- Returns a function that disconnects. Called as listener(key, value) for
-- every change, so a consumer that cares about one setting checks the key.
function GameSettings.OnChanged(listener)
	table.insert(listeners, listener)
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

return GameSettings

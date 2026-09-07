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
--   "Action"  a button. Has no value at all - see the ACTIONS note below.
--
-- Format is optional and only cosmetic - it turns the raw value into the text
-- shown beside the control. Without it the number is shown bare.
--
-- ACTIONS are the odd one out and worth a paragraph. Everything else in this
-- file is a VALUE the menu reads and writes; an action is a button that DOES
-- something, once, somewhere else in the game. It is here rather than
-- hand-built into SettingsMenu (which is what the admin money button does)
-- because the menu's whole design rule is that it never names an individual
-- setting - and the moment a second hand-built row appears, that rule is gone
-- and the menu is back to being a list of special cases.
--
-- An action carries a ButtonText and nothing else. Whoever owns the behaviour
-- registers it with GameSettings.OnAction(key, handler); the menu just fires
-- the key. Neither side knows about the other, which is how the tutorial can
-- own its own replay button without SettingsMenu importing anything from it.
local DEFINITIONS = {
	{
		Category = "Tutorial",
		Key = "ReplayTutorial",
		Label = "Replay the tutorial",
		Description = "Walks you through claiming a garage, picking up cargo at the depot and making a delivery. Handy for showing a friend.",
		Type = "Action",
		ButtonText = "Start",
	},
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
		Key = "MirrorOcclusionCulling",
		Label = "Hide what's behind walls",
		Description = "Stop the mirrors drawing objects a wall is in front of - the furniture inside a closed building, for example. Costs a little CPU to work out, and spends the Detail budget above on things you can actually see instead.",
		Type = "Toggle",
		Default = true,
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
-- Tutorial first: it is the only row here that a lost player is looking for,
-- and every other category is a comfort option they can find at leisure.
local CATEGORY_ORDER = { "Tutorial", "Mirrors" }

local values = {}
local byKey = {}
for _, definition in DEFINITIONS do
	-- An Action has no Default, so this leaves no entry for it - which is
	-- exactly right: Get returns nil for a key that is not a value, and Set
	-- refuses it below.
	values[definition.Key] = definition.Default
	byKey[definition.Key] = definition
end

local listeners = {}
-- [key] = handler, for Action definitions. One handler per key, last
-- registration wins - an action is a single button and two things claiming it
-- would be a bug, not a feature.
local actionHandlers = {}

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
	if not definition or definition.Type == "Action" then
		return -- an action is a button, not a value; there is nothing to set
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

-- Registers what an "Action" row's button actually does. Returns a function
-- that unregisters it.
--
-- Deliberately tolerant of an unknown key, like Set is, and for the same
-- reason: a setting being removed should not break whatever was still wired to
-- it. The row simply never appears and the handler is never called.
function GameSettings.OnAction(key, handler)
	actionHandlers[key] = handler
	return function()
		if actionHandlers[key] == handler then
			actionHandlers[key] = nil
		end
	end
end

-- Called by the menu when an action's button is pressed. Returns whether
-- anything was actually listening, so the menu can decline to close itself
-- over a button that did nothing.
function GameSettings.FireAction(key)
	local handler = actionHandlers[key]
	if not handler then
		return false
	end
	handler()
	return true
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

-- The Induction Upgrade: the turbo ladder, bought per car with in-game money.
--
-- ONE FILE, BOTH SIDES, same as UpgradePasses and VehiclePaint. The terminal
-- draws the ladder from Stages; PlotManager validates a purchase against the
-- same table and writes the bought stage onto the spawned car as an Attribute;
-- InductionEffects (client) reads that Attribute and decides what to play and
-- how much boost to hand the physics. Nothing here is a security boundary -
-- PlotManager re-checks every purchase - but all three have to agree on what
-- "stage 3" means or the player hears one thing and pays for another.
--
-- WHY IT IS NOT CALLED "TURBO". Stage 1 is a turbo. Stage 2 adds a blow-off
-- valve, stage 3 anti-lag, stage 4 a two-step launch - none of which are the
-- turbo itself, and a ladder whose name only describes its first rung reads as
-- a bug by the time you reach the top of it. "Induction" is the word that
-- covers the whole realm, and the stage names underneath it are the ones a
-- child actually learns.
--
-- NO CAR HAS ANY OF THIS BY DEFAULT. Three of the templates were built in
-- Studio with a Sound named "Turbo" already in their Engine folder; that sound
-- is now adopted by stage 1 rather than being what grants it, so a Straight
-- Truck with no Induction Upgrade is as silent as the Starter Vehicle. Every
-- car can buy every stage - see InductionEffects for how a car with no
-- authored Turbo sound gets one at runtime.
--
-- EVERYONE HEARS IT. Every sound and particle in this feature is built by each
-- CLIENT on the car itself, from state that is already replicated (the stage
-- Attribute, NetRpm, NetThrottle, NetBraking, NetShiftCount, NetTwoStep), so a
-- bystander runs the same state machine off the same numbers and hears the
-- same bang at the same moment. That is the whole point: a pop nobody else
-- hears is not worth buying.

local VehicleInduction = {}

-- Written on the car MODEL (not the Chassis, unlike the tuning stats) by
-- PlotManager, so it replicates to every client and a bystander's
-- InductionEffects can read it with one GetAttribute. 0/nil = stock.
VehicleInduction.ATTRIBUTE = "InductionStage"

VehicleInduction.DisplayName = "Induction Upgrade"

-- THE MIXING DESK. Every sound this feature plays, with its level and how far
-- it carries - this is the one place to turn the blow-off valve down or make
-- the bangs reach further. Volume is the Sound's own 0-1 level; MaxDistance is
-- RollOffMaxDistance in studs, on an InverseTapered rolloff from 15 studs out.
--
-- These are relative to each other and to the engine loop, which sits at 0.5.
--
-- TWO SHAPES. A single-id entry (Whistle, BlowOff) is one sound that always
-- plays. A POOL entry has SoundIds, and one is picked at random every time it
-- fires - which is most of why anti-lag stopped sounding like the same event on
-- a loop. InductionEffects plays pools through a rotating bank of voices, so
-- each firing also gets its own pitch and its own level without cutting off the
-- one before it.
--
-- SAMPLE LENGTH IS THE WHOLE GAME with these. A burst is meant to read as a
-- rapid stutter of separate cracks, and a sample longer than the gap between
-- firings smears into the next one until the burst is just noise. The pools are
-- split by length for exactly that reason and the lengths are noted per id -
-- if you swap an id in, check its length first and put it in the right pool.
--
-- ONE EXCEPTION, and it catches people out: a car built in Studio with its own
-- Sound named "Turbo" under Engine/ keeps THAT sound's authored Volume, because
-- InductionEffects adopts the instance rather than replacing it. Whistle.Volume
-- below is only used for the cars that have no authored one. As of now that
-- means StraightTruck, ArticTruck and AmericanHitchTruck are mixed in Studio
-- (at 0.3) and every other car is mixed here.
VehicleInduction.Sounds = {
	-- The whistle the Straight Truck and American Hitch Truck already shipped
	-- with, promoted to the id every car uses. Looped, and faded in and out by
	-- spool, so this is its level at FULL boost and never a constant.
	Whistle = { SoundId = "rbxassetid://10185333704", Volume = 0.3, MaxDistance = 300 },

	-- Played from the exhaust, so it comes from the tailpipe rather than from
	-- under the bonnet. One sound, because a blow-off valve IS one event.
	BlowOff = { SoundId = "rbxassetid://107658438602417", Volume = 1.2, MaxDistance = 350 },

	-- THE CRACKLE POOL: the short stuff, and the backbone of a burst. Nothing
	-- here is longer than a third of a second, so a dozen of them 30ms apart
	-- stay countable as separate cracks instead of merging into a drone.
	Crackle = {
		Volume = 0.55,
		MaxDistance = 380,
		SoundIds = {
			"rbxassetid://17651322809", -- 0.09s, the original subtle pop
			"rbxassetid://138924952728704", -- 0.28s
			"rbxassetid://140725059135838", -- 0.22s
			"rbxassetid://72845095527361", 
			"rbxassetid://17651322643", 
		},
	},

	-- THE CRACK POOL: middleweight, sprinkled through a burst so it is not all
	-- one texture. Half a second each - long enough to have some body, short
	-- enough not to swallow the crackles either side of it.
	Crack = {
		Volume = 0.7,
		MaxDistance = 450,
		SoundIds = {
			"rbxassetid://132331652249520", -- 0.47s
			"rbxassetid://18633134773", -- 2.37s
			"rbxassetid://18633131180", -- 1.81s
			"rbxassetid://17651322246", -- 1.81s
			"rbxassetid://17651322371", -- 1.81s
		},
	},

	-- THE BANG POOL: the big ones, ~2 seconds each, and the reason they are
	-- used SPARINGLY. A two-second sample fired on every lift-off was the whole
	-- of the old anti-lag, and it read as one loud noise that never varied
	-- because that is exactly what it was. Now a bang only ever opens a burst,
	-- only at high boost, and only some of the time - so it lands as the
	-- occasional big one with a stutter of crackles running out behind it.
	Bang = {
		Volume = 0.85,
		MaxDistance = 600,
		SoundIds = {
			"rbxassetid://112720519011313", -- 0.44s
		},
	},
}

-- THE BURST RECIPES: what each anti-lag EVENT actually sounds and looks like.
--
-- The pools above are categorised by LENGTH. This table categorises by EVENT,
-- and it is the half that was missing: lift-off and upshift used to draw from
-- the same pools with only a volume difference, which is why an upshift got
-- handed half-second samples inside a gearshift that is only ShiftTime (0.35s)
-- long - they were still sounding when the shift ended, and cut off abruptly.
--
-- WHAT IS ACTUALLY HAPPENING IN THE ENGINE, because the two events are not the
-- same thing and should not sound the same:
--
--   LiftOff  The throttle shuts on a spinning turbo and the exhaust is full of
--            unburnt fuel with nowhere to go. This is the long, loose, burbling
--            one - the crackle-and-grumble people buy exhausts for - and it can
--            carry a genuine bang and real flame.
--   Upshift  The ignition is cut for a fraction of a second to make the shift
--            at full throttle. Deliberately reduced to ONE small crackle and
--            nothing else - no bang, no flame - because it fires several times
--            per pull and anything bigger stops being punctuation and starts
--            being the thing you hear instead of the engine. Popping, banging
--            and fire belong to lifting off; this is only a blip.
--   TwoStep  A limiter bouncing the engine off a rev ceiling, over and over.
--            Rapid and small, because it repeats several times a second.
--   Launch   The moment the brake comes off with everything spooled. The one
--            event that is allowed to be as big as it likes.
--
-- Count     Min plus a random 0..Spread*intensity, so a harder event stutters
--           for longer.
-- Pools     Weighted pick per crack. Upshift draws ONLY from Crackle, which is
--           what keeps it inside the shift window.
-- Bang      nil = never. Otherwise it may OPEN the burst, above MinIntensity
--           and only Chance of the time.
-- Volume    Scale on the pool's own level, for the whole burst.
-- Flames    Weighted per crack. nil means the event NEVER shows anything at
--           the exhaust - not "almost never", which is what a heavily weighted
--           "None" gives you and which still throws the odd spark out on a
--           gearchange. Fire is a lift-off thing; nil is how an event opts out
--           of it completely.
--
-- To silence an event entirely, give it Volume = 0 and Flames = None only;
-- to stop upshifts popping at all, delete the Upshift entry (a missing recipe
-- is simply skipped - see InductionEffects).
VehicleInduction.Bursts = {
	LiftOff = {
		Count = { Min = 3, Spread = 7 },
		Pools = { { Pool = "Crackle", Weight = 72 }, { Pool = "Crack", Weight = 28 } },
		Bang = { MinIntensity = 0.6, Chance = 0.45 },
		Volume = 1,
		Pitch = { Min = 0.82, Max = 1.38 },
		Flames = {
			{ Style = "None", Weight = 46 },
			{ Style = "Spark", Weight = 30 },
			{ Style = "Flash", Weight = 18 },
			{ Style = "Torch", Weight = 6 },
		},
	},

	-- ONE small crackle, quiet, and nothing visible. Every value here is
	-- deliberately meaner than LiftOff's, because this fires several times per
	-- pull whether the player wanted it to or not - and a noise that frequent
	-- has to sit under the engine rather than on top of it.
	--
	-- Count is exactly 1 (Spread 0): a stutter is what an overrun does, and
	-- stuttering on the way UP made the truck sound like it was misfiring
	-- rather than shifting.
	Upshift = {
		Count = { Min = 1, Spread = 0 },
		-- Crackle only. The longest sample in that pool is 0.32s, which fits
		-- inside the 0.35s ignition cut - so the blip is over before the engine
		-- picks back up instead of being interrupted by it.
		Pools = { { Pool = "Crackle", Weight = 100 } },
		Bang = nil, -- never: bangs belong to lifting off
		Volume = 0.3,
		-- Tighter and higher than LiftOff. A shift blip is a crack, not a
		-- burble, and the low end of the pitch range is what sounds burbly.
		Pitch = { Min = 1.05, Max = 1.35 },
		Flames = nil, -- never: no fire, no sparks, nothing at the pipe
	},

	TwoStep = {
		Count = { Min = 2, Spread = 2 },
		Pools = { { Pool = "Crackle", Weight = 85 }, { Pool = "Crack", Weight = 15 } },
		Bang = nil, -- it repeats ~4x a second; a big sample here is just mud
		Volume = 0.8,
		Pitch = { Min = 0.95, Max = 1.3 },
		Flames = {
			{ Style = "None", Weight = 35 },
			{ Style = "Spark", Weight = 35 },
			{ Style = "Flash", Weight = 30 },
		},
	},

	Launch = {
		Count = { Min = 5, Spread = 6 },
		Pools = { { Pool = "Crackle", Weight = 60 }, { Pool = "Crack", Weight = 40 } },
		Bang = { MinIntensity = 0, Chance = 0.9 },
		Volume = 1,
		Pitch = { Min = 0.85, Max = 1.3 },
		Flames = {
			{ Style = "Spark", Weight = 20 },
			{ Style = "Flash", Weight = 40 },
			{ Style = "Torch", Weight = 40 },
		},
	},
}

-- !! TESTING PRICES ARE ACTIVE !! Every Price below is $1 so the whole ladder
-- can be walked in one sitting. The real figure is on each line after
-- `--default`, the same convention VehicleCatalog uses for its own temporarily
-- cheap vehicles. RESTORE THESE BEFORE SHIPPING - at $1 the ladder is not an
-- upgrade path, it is four free sound effects.
--
-- THE LADDER. Level is the saved number (0 = none). Price is in-game money and
-- is paid once per car - the same shape as a vehicle's own price, not the
-- compounding BaseCost/CostGrowth the stat upgrades use, because there are
-- four rungs here and each one is a distinct named thing rather than another
-- notch of the same slider.
--
-- Boost is how much extra torque a FULLY spooled turbo hands the drive force,
-- as a fraction (0.2 == +20%). It scales with spool, so it is only ever there
-- once the revs are up - which is what makes it feel like boost rather than
-- like the Torque upgrade being bought twice. Top speed is untouched: this is
-- acceleration only.
VehicleInduction.Stages = {
	{
		Level = 1,
		Id = "Turbo",
		DisplayName = "Turbo",
		Price = 1, --default 4,000
		Blurb = "A turbo that spools up as you rev. Hear it whistle, feel it pull harder.",
		Boost = 0.18,
	},
	{
		Level = 2,
		Id = "BlowOff",
		DisplayName = "Blow-Off Valve",
		Price = 1, --default 9,000
		-- The sound is the product. Say exactly when it happens, because "lift
		-- off the gas while it's spooled" is a thing a player has to DO, and a
		-- feature you can't work out how to trigger reads as broken.
		Blurb = "Lift off the gas while the turbo is spooled and it lets the boost out with a chirp.",
		Boost = 0.26,
	},
	{
		Level = 3,
		Id = "AntiLag",
		DisplayName = "Anti-Lag",
		Price = 1, --default 20,000
		Blurb = "Pops and bangs out of the exhaust, with flames. The turbo stays spooled between gears.",
		Boost = 0.34,
	},
	{
		Level = 4,
		Id = "TwoStep",
		DisplayName = "Two-Step Launch",
		Price = 1, --default 45,000
		-- Names the exact key combination, for the same reason as stage 2.
		Blurb = "Hold the brake and the gas together at a standstill to build boost, then let go of the brake and launch.",
		Boost = 0.40,
	},
}

VehicleInduction.StagesByLevel = {}
for _, stage in VehicleInduction.Stages do
	VehicleInduction.StagesByLevel[stage.Level] = stage
end

-- What each stage TURNS ON, as a level threshold. Written as data rather than
-- as `level >= 3` scattered through InductionEffects, so adding a stage in the
-- middle later is one number here instead of a hunt through the effects code.
VehicleInduction.Features = {
	Whistle = 1, -- the looping spool whistle, and the boost that comes with it
	BlowOff = 2, -- chirp on lifting off the gas while spooled
	AntiLag = 3, -- pops/bangs and exhaust flame on lift-off and between gears
	TwoStep = 4, -- brake-and-gas launch control
}

function VehicleInduction.MaxStage()
	return #VehicleInduction.Stages
end

function VehicleInduction.ClampStage(level)
	if type(level) ~= "number" or level ~= level then
		return 0
	end
	return math.clamp(math.floor(level), 0, VehicleInduction.MaxStage())
end

function VehicleInduction.Get(level)
	return VehicleInduction.StagesByLevel[VehicleInduction.ClampStage(level)]
end

-- The stage a player at `level` would buy next, or nil at the top of the
-- ladder. The one place both the terminal's buy button and PlotManager's
-- purchase handler ask "what comes next and what does it cost".
function VehicleInduction.NextStage(level)
	return VehicleInduction.StagesByLevel[VehicleInduction.ClampStage(level) + 1]
end

function VehicleInduction.Has(level, featureName)
	local required = VehicleInduction.Features[featureName]
	return required ~= nil and VehicleInduction.ClampStage(level) >= required
end

-- Extra torque, as a multiplier, for a car at `level` whose turbo is `spool`
-- (0-1) full. 1 for a stock car, so callers can multiply unconditionally.
function VehicleInduction.TorqueMultiplier(level, spool)
	local stage = VehicleInduction.Get(level)
	if not stage then
		return 1
	end
	return 1 + stage.Boost * math.clamp(spool or 0, 0, 1)
end

-- What the garage shows as the car's current state.
function VehicleInduction.DisplayNameFor(level)
	local stage = VehicleInduction.Get(level)
	return if stage then stage.DisplayName else "Stock"
end

return VehicleInduction

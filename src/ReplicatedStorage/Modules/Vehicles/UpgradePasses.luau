-- Which upgrades come free with the car, and which need a Robux game pass.
--
-- ONE FILE, BOTH SIDES. The garage terminal reads this to decide what to draw
-- gold and padlocked; PlotManager reads it to decide what to refuse. Neither
-- trusts the other, but they have to agree on WHAT the rule is or the UI shows
-- a button the server will silently reject.
--
-- HOW THE SPLIT WAS PICKED. The audience is nine years old. Four stats are the
-- ones a child understands without being taught - how hard it pulls, how sharply
-- it turns, how much it carries, how well it survives a crash - and all four are
-- free, forever, on every car. That is the whole game: a player who never
-- spends a Robux still upgrades, still earns more per run, still feels the car
-- get better. Nothing here gates progression.
--
-- The pass buys the OTHER six: top speed plus five handling knobs (brakes,
-- grip, and the three suspension stats). Top speed is
-- deliberately on the paid side and is the reason the pass sells at all - it
-- is the one gated stat a child reads instantly and wants, while being the one
-- that blocks nothing, since deliveries are won by parking carefully and not by
-- arriving fast. The five handling stats are the volume that justifies the
-- price; on their own they would read as a bag of jargon nobody wants.
--
-- Torque stays free on purpose even though it is the most fun upgrade in the
-- game - especially because it is. It is the taste of what upgrading feels
-- like, and a player who has never felt it has no reason to buy anything.
local UpgradePasses = {}

-- [vehicleId] = the game pass that unlocks that car's gated stats. Per-CAR,
-- not per-account: owning the Starter's pass does nothing for the Pickup. A
-- vehicle absent from this table has no pass, which means every stat on it is
-- free - that is the safe default for a car added later and forgotten about
-- here, since the failure mode is "player got something for nothing" rather
-- than "player paid and got nothing".
UpgradePasses.PassIdByVehicleId = {
	StarterVehicle = 1969611825,
	PickupTruck = 1967959980,
	BoxTruck = 1976756745,
}

-- The gated stats, by config key. Same set for every car - a stat that is
-- jargon on one vehicle is jargon on all of them, and a split that changed
-- per car would be a second rule for a player to learn at the exact moment
-- they are deciding whether to spend money.
UpgradePasses.GatedStats = {
	MaxSpeed = true,
	BrakeFriction = true,
	TractionSlipThreshold = true,
	Stiffness = true,
	Damper = true,
	SuspensionMaxLength = true,
}

-- What the pass is called wherever it is sold. Kept here rather than in the
-- terminal so the server's rejection message and the client's gold banner
-- cannot drift apart.
UpgradePasses.DisplayName = "Pro Tuning Pass"

-- TESTING ONLY - flip to true to see the panel the way a player without the
-- pass sees it, then flip it back.
--
-- Roblox treats a place's creator as already owning every pass created for that
-- place, so UserOwnsGamePassAsync is permanently true for you in your own game
-- and there is otherwise NO way to look at the locked cards, the gold banner or
-- the UNLOCK buttons - which are most of what this feature is. This is the
-- switch that makes them visible.
--
-- Read on the SERVER only (see PlotManager's ownsUpgradePass), so it lies about
-- ownership consistently in one place: the terminal draws locked, and buying a
-- gated upgrade is genuinely refused, exactly as it would be for a real player.
-- Pressing UNLOCK while this is on still opens Roblox's purchase prompt, which
-- will say you already own the pass - that part cannot be faked.
--
-- MUST be false when shipping. Left true, every paying customer sees the wall
-- they already paid to remove.
UpgradePasses.DebugForceUnowned = false

function UpgradePasses.PassIdFor(vehicleId)
	return UpgradePasses.PassIdByVehicleId[vehicleId]
end

function UpgradePasses.IsGated(statName)
	return UpgradePasses.GatedStats[statName] == true
end

-- The one predicate both sides ask, so "locked" means exactly one thing.
--
-- `ownedLevel` is what the player has ALREADY bought in this stat with in-game
-- money, and a non-zero one keeps the stat tunable without the pass. That is
-- grandfathering, and it exists for the players who bought these levels before
-- the pass existed: taking away something already paid for is the one thing
-- worse than never offering it. It does NOT let them buy MORE - see
-- CanBuy below - so it grants nothing to a player starting today, who has
-- zero levels in every gated stat by definition.
function UpgradePasses.CanTune(statName, ownsPass, ownedLevel)
	if not UpgradePasses.IsGated(statName) then
		return true
	end
	return ownsPass or (ownedLevel or 0) > 0
end

function UpgradePasses.CanBuy(statName, ownsPass)
	if not UpgradePasses.IsGated(statName) then
		return true
	end
	return ownsPass
end

return UpgradePasses

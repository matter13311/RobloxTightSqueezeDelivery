-- Every word the tutorial says, and every number it is tuned by, in one file.
--
-- Split out from TutorialGuide.client.luau for the same reason GameSettings is
-- split from SettingsMenu: rewording a step, reordering the steps or adding one
-- is a content change, and it should not mean reading a state machine. The
-- runner names steps only by the Id strings below.
--
-- WRITING THE TEXT. The audience is a nine-year-old who has never played this
-- game and is already trying to drive. Everything here is held to three rules:
--
--   Say the verb first. "Hold F on the terminal", not "In order to claim a
--   plot, you will need to...". The first two words have to be the action.
--
--   Name the key, every time, even when it was named in the step before. A
--   player who missed it once will miss it twice, and there is no cost to
--   repeating it.
--
--   Say WHY once, in the step where it matters. The depot step is the whole
--   reason this tutorial exists - in playtesting, children drove straight past
--   it and spent the session ramming each other - so it is the one step that
--   gets a sentence of motivation rather than only an instruction.
--
-- Body text is deliberately one or two short lines. The banner sits at the
-- bottom of the screen while the player is driving; anything longer is a
-- paragraph nobody reads at 40 studs a second.

local TutorialConfig = {}

--=============================================================================
-- Steps
--=============================================================================

-- Id is what the runner switches on - the ONE string shared between this file
-- and TutorialGuide.client.luau. Order here is the order they run in.
--
-- Hint is optional and shown INSTEAD of Body while the step's precondition is
-- not met (the player is out of their car, the car is not in the bay). It
-- is not a second step: the same goal is still being worked toward, and adding
-- a step for "get back in the car" would make the counter jump around
-- whenever a player wandered off.
TutorialConfig.Steps = {
	{
		Id = "ClaimPlot",
		Title = "Claim your garage",
		Body = "Walk up to a free garage terminal and HOLD F to claim it.",
	},
	{
		Id = "SpawnVehicle",
		Title = "Spawn your car",
		Body = "Press F at your terminal, then click SPAWN VEHICLE.",
	},
	{
		Id = "DriveToDepot",
		Title = "Drive and Park at the depot",
		-- The sentence this whole tutorial was written for. It leads with the
		-- consequence, not the instruction, because the instruction alone
		-- ("drive to the depot") is what playtesters ignored.
		Body = "Park at the depot",
		Hint = "Press F by the door to get into your car.",
	},
	{
		Id = "ChooseCargo",
		Title = "Pick up a load",
		Body = "Click a job on the list to load it onto your car.",
		Hint = "Park fully inside the depot bay and stop - the job list opens by itself.",
	},
	{
		Id = "Deliver",
		Title = "Make the delivery",
		Body = "Follow the beam and park in the marked space to get paid.",
		Hint = "Press F by the door to get back into your car.",
	},
}

-- Shown for a few seconds after the last step, then the banner goes away for
-- good. A tutorial that simply stops leaves the player wondering whether it
-- broke.
TutorialConfig.Finish = {
	Title = "You're a delivery driver!",
	Body = "Head back to the depot for your next job. Press M for settings any time.",
	Seconds = 8,
}

-- Shown once, right after Finish, before the banner goes away for good - see
-- TutorialGuide's finish(). Nothing in the five steps above ever sends the
-- player back to their garage terminal once they have spawned a car, so a
-- first-time player has no reason to ever learn upgrades exist there. This is
-- the one nudge toward it, timed for the moment they are standing right next
-- to it and about to drive off for the rest of the session.
TutorialConfig.GarageReminder = {
	Title = "Don't forget your garage!",
	Body = "Go to your garage terminal any time to browse and upgrade your vehicle.",
	Seconds = 8,
}

--=============================================================================
-- Look
--=============================================================================

-- The same green the delivery HUD uses for "this is the good outcome" (its
-- ACCENT, and the depot guide's IN). One colour means one thing across the
-- game: a second tutorial-only colour would be a fourth thing to learn on a
-- screen that already teaches three.
TutorialConfig.Color = Color3.fromRGB(86, 200, 128)

-- The banner's edge flashes to this and fades back to Color whenever its
-- words change, so a new instruction is noticed from the corner of the eye.
TutorialConfig.FlashColor = Color3.fromRGB(255, 255, 255)

-- How many times the edge pulses white when a NEW step appears. A step only
-- swapping between its Body and Hint pulses once.
TutorialConfig.NewStepFlashes = 4

--=============================================================================
-- Sound
--=============================================================================

-- Played each time the banner moves on to a new step, including the finish
-- and garage-tip banners - but not when a step merely swaps between its Body
-- and its Hint. An "rbxassetid://..." string; left empty, nothing plays.
TutorialConfig.StepSoundId = ""

--=============================================================================
-- Tuning
--=============================================================================

-- How often the runner re-checks whether the current step is done and where
-- its target is. Everything it checks is cheap (an attribute, a distance, one
-- ParkGrade call on a handful of bay parts) but none of it is worth doing every
-- frame - the marker interpolates smoothly on its own between polls, exactly
-- the way the depot guides do.
--
-- There is deliberately no separate retry interval for finding the depot and
-- the destinations, which is what DeliveryHud and DepotGuides both need one
-- for. Those two look the world up once and cache it, so they need their own
-- clock to retry on while it is missing; the tutorial re-resolves every target
-- on this same poll anyway, so a depot that appears, moves or is renamed
-- mid-session is simply picked up on the next quarter second for free.
TutorialConfig.PollInterval = 0.25

return TutorialConfig

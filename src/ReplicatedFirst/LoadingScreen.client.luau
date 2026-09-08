-- A full-screen cover shown from the first instant a player joins, held up
-- until assets have preloaded, the character has spawned, and a short settle
-- beat has let lighting/streaming catch up - see READY GATE below for why
-- each of those is on the list.
--
-- THE PROBLEM THIS FIXES. Without it, a joining character spawns with full
-- walk speed the moment the default Roblox loading screen fades, and the
-- tutorial (TutorialGuide.client.luau) does not appear for a few seconds
-- after that - it waits on its own RemoteFunction round trip before it ever
-- shows a banner. In that gap the player is free to wander off, and by the
-- time the tutorial catches up they are somewhere else, wondering why the
-- game only just noticed them. This screen closes that gap: nothing moves,
-- and nothing after it can render underneath, until it says so.
--
-- WHY IT LIVES IN ReplicatedFirst rather than StarterPlayerScripts. This is
-- the one place Roblox guarantees runs before anything else, including
-- Roblox's own default loading screen. Anywhere else and there is a visible
-- gap - the default screen fades, the world is visible and walkable, and
-- only THEN does this script's first line run. RemoveDefaultLoadingScreen
-- only makes sense called from here, before that screen has had any chance
-- to fade on its own.
--
-- WHY IT FREEZES THE CHARACTER. A loading screen that only covers the
-- screen still lets WASD move the character underneath it - the player just
-- can't see it happen until the cover lifts and they are already somewhere
-- else. Zeroing WalkSpeed/JumpPower/JumpHeight for the duration and
-- restoring the character's actual values on hide keeps "the screen goes
-- away" and "you can move now" the exact same moment, regardless of how long
-- asset preload or the tutorial's own startup round trip takes.
--
-- WHY THE DisplayOrder IS SO HIGH. TutorialGui sits at 6 and the settings
-- menu at 100 (see TutorialGuide.client.luau and SettingsMenu.client.luau).
-- The tutorial can start counting down and rendering its banner while this
-- screen is still running its own readiness checks - its startup does a
-- RemoteFunction round trip on a completely independent clock - so this has
-- to outrank not just those two but anything else that could ever be on
-- screen at join. It is destroyed outright on hide rather than merely
-- disabled, so there is no leftover high-DisplayOrder instance left behind
-- for some future gui to have to out-rank.
--
-- READY GATE, three checks, in order:
--   1. game:IsLoaded()      the initial join replication has finished.
--      Usually already true by the time a LocalScript runs at all, but it
--      costs nothing to make sure rather than assume it.
--   2. ContentProvider      every asset the place currently references is
--      preloaded, batched so the bar on screen reflects real progress
--      instead of sitting at 0% and then jumping to 100%.
--   3. The character        Humanoid and HumanoidRootPart both exist, which
--      is also the earliest point movement can be frozen.
-- After all three, one short fixed pause lets voxel lighting and streamed
-- terrain settle before the reveal. Roblox has no "lighting has finished
-- recomputing" signal to wait on instead - see LIGHTING_SETTLE_SECONDS.

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

-- Matches TutorialGuide's palette (its ACCENT is TutorialConfig.Color) so this
-- reads as the first frame of the same UI rather than a different app.
local PANEL = Color3.fromRGB(18, 20, 25)
local ACCENT = Color3.fromRGB(86, 200, 128)
local DIM_TEXT = Color3.fromRGB(120, 130, 148)
local TRACK = Color3.fromRGB(40, 44, 54)

-- Empirically chosen, not measured off a signal - see the READY GATE note
-- above. Long enough that voxel lighting has caught up on a typical join,
-- short enough that it reads as part of the same beat as the asset preload
-- rather than a stall bolted on after it.
local LIGHTING_SETTLE_SECONDS = 0.6
local FADE_SECONDS = 0.4
local PRELOAD_BATCH_SIZE = 50

--=============================================================================
-- The cover
--=============================================================================

-- Higher than every other DisplayOrder in the game on purpose - see the
-- header. Built and parented before RemoveDefaultLoadingScreen runs so there
-- is no frame where neither screen is up.
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LoadingScreen"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 1000
screenGui.Parent = player:WaitForChild("PlayerGui")

local cover = Instance.new("Frame")
cover.Name = "Cover"
cover.Size = UDim2.fromScale(1, 1)
cover.BackgroundColor3 = PANEL
cover.BorderSizePixel = 0
cover.Active = true
cover.Parent = screenGui

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.new(0.5, 0, 0.5, -34)
title.Size = UDim2.new(0.8, 0, 0, 44)
title.Font = Enum.Font.LuckiestGuy
title.TextSize = 34
title.TextColor3 = Color3.fromRGB(236, 240, 247)
title.Text = "TIGHT SQUEEZE DELIVERY"
title.TextWrapped = true
title.Parent = cover

local subtitle = Instance.new("TextLabel")
subtitle.Name = "Subtitle"
subtitle.BackgroundTransparency = 1
subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
subtitle.Position = UDim2.new(0.5, 0, 0.5, 4)
subtitle.Size = UDim2.new(0.8, 0, 0, 20)
subtitle.Font = Enum.Font.GothamMedium
subtitle.TextSize = 14
subtitle.TextColor3 = DIM_TEXT
subtitle.Text = "Loading..."
subtitle.Parent = cover

local barTrack = Instance.new("Frame")
barTrack.Name = "BarTrack"
barTrack.AnchorPoint = Vector2.new(0.5, 0.5)
barTrack.Position = UDim2.new(0.5, 0, 0.5, 40)
barTrack.Size = UDim2.new(0, 320, 0, 8)
barTrack.BackgroundColor3 = TRACK
barTrack.BorderSizePixel = 0
barTrack.Parent = cover
Instance.new("UICorner", barTrack).CornerRadius = UDim.new(1, 0)

local barFill = Instance.new("Frame")
barFill.Name = "BarFill"
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = ACCENT
barFill.BorderSizePixel = 0
barFill.Parent = barTrack
Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

local function setProgress(fraction)
	fraction = math.clamp(fraction, 0, 1)
	barFill.Size = UDim2.new(fraction, 0, 1, 0)
end

-- Up now, so there is never a frame where the default screen is gone and
-- this one is not up yet in its place.
ReplicatedFirst:RemoveDefaultLoadingScreen()

--=============================================================================
-- Freezing movement
--=============================================================================

-- Restored to whatever the character's Humanoid actually had, not a
-- hardcoded 16/50, so this stays correct if StarterPlayer's defaults or a
-- gameplay system ever change them.
local frozenHumanoid = nil
local originalWalkSpeed = nil
local originalJumpPower = nil
local originalJumpHeight = nil

local function freezeCharacter(humanoid)
	frozenHumanoid = humanoid
	originalWalkSpeed = humanoid.WalkSpeed
	originalJumpPower = humanoid.JumpPower
	originalJumpHeight = humanoid.JumpHeight
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
end

local function unfreezeCharacter()
	if frozenHumanoid and frozenHumanoid.Parent then
		frozenHumanoid.WalkSpeed = originalWalkSpeed
		frozenHumanoid.JumpPower = originalJumpPower
		frozenHumanoid.JumpHeight = originalJumpHeight
	end
	frozenHumanoid = nil
end

--=============================================================================
-- The ready gate
--=============================================================================

local function waitForCharacter()
	local character = player.Character or player.CharacterAdded:Wait()
	local humanoid = character:WaitForChild("Humanoid")
	character:WaitForChild("HumanoidRootPart")
	return humanoid
end

-- Batched rather than one call over game:GetDescendants(), so the bar climbs
-- with real progress instead of sitting at 0% and jumping straight to 100%
-- once everything happens to be cached.
local function preloadAssets()
	local assets = game:GetDescendants()
	local total = #assets
	if total == 0 then
		setProgress(1)
		return
	end

	local batch = table.create(PRELOAD_BATCH_SIZE)
	local doneCount = 0
	for _, asset in assets do
		table.insert(batch, asset)
		if #batch >= PRELOAD_BATCH_SIZE then
			pcall(ContentProvider.PreloadAsync, ContentProvider, batch)
			doneCount += #batch
			setProgress(doneCount / total)
			table.clear(batch)
		end
	end
	if #batch > 0 then
		pcall(ContentProvider.PreloadAsync, ContentProvider, batch)
		doneCount += #batch
		setProgress(doneCount / total)
	end
end

local function reveal()
	unfreezeCharacter()

	local fade = TweenInfo.new(FADE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(cover, fade, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(title, fade, { TextTransparency = 1 }):Play()
	TweenService:Create(subtitle, fade, { TextTransparency = 1 }):Play()
	TweenService:Create(barTrack, fade, { BackgroundTransparency = 1 }):Play()
	TweenService:Create(barFill, fade, { BackgroundTransparency = 1 }):Play()

	task.wait(FADE_SECONDS)
	screenGui:Destroy()
end

task.spawn(function()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end

	-- Frozen as early as possible - before the (potentially slower) asset
	-- preload runs - so there is no window after the character exists where
	-- it could still move while this cover is up.
	local humanoid = waitForCharacter()
	freezeCharacter(humanoid)

	subtitle.Text = "Loading assets..."
	preloadAssets()

	subtitle.Text = "Loading..."
	task.wait(LIGHTING_SETTLE_SECONDS)

	reveal()
end)

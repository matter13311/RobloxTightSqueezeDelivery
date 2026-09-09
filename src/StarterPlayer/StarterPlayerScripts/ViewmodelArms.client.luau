-- First-person driving arms. Welded directly to the DriverSeat (not the
-- camera) so they stay gripping the wheel no matter how the player rotates
-- the camera - the camera has nothing to do with where these arms sit.
-- WeldConstraint does the actual work: set once on entry, physics keeps it
-- attached from then on, so nothing here costs a frame to POSITION them. What
-- the per-frame connections below do is pose them (steering) and decide
-- whether they belong on screen at all (first person only - see setArmsHidden).
--
-- Client-only: nobody else needs to see your own driving hands, same as an
-- FPS game never replicates its viewmodel to other players.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local VehicleViewMode = require(script.Parent.VehicleViewMode)

local player = Players.LocalPlayer
local template = ReplicatedStorage:WaitForChild("ViewmodelArms")

-- 0s = full left lock, 0.5s = center, 1s = full right lock (see the grip
-- animation itself for the actual posing). NetSteer is -1..1 (full left to
-- full right - see VehicleNetworkState.server.luau's toSteer), so it maps
-- directly onto that timeline once shifted into 0..1.
local GRIP_ANIMATION = Instance.new("Animation")
GRIP_ANIMATION.AnimationId = "rbxassetid://125237886074445"

-- Where the Main reference part should sit relative to the DriverSeat. Main
-- is a separate, free-floating part (not PrimaryPart - that has to stay
-- HumanoidRootPart for the Animation Editor to work), so the offset between
-- it and the arms is controlled by where Main sits inside the model itself -
-- same trick as the original toolbox rig. Keep this at zero and do the
-- positioning by moving Main in Studio instead.
local SEAT_OFFSET = CFrame.new(0, 0, 0)

local currentArms = nil
local currentSteerConnection = nil
local currentVisibilityConnection = nil
local armsHidden = false

-- These are a VIEWMODEL: a prop that only makes sense from inside the driver's
-- head. From any third person view they are a second pair of hands floating at
-- the wheel next to the real avatar's, which is exactly what the player sees
-- when they zoom out - two bodies driving one truck.
--
-- Hidden rather than destroyed, because the player can zoom back in at any
-- moment and rebuilding the rig (clone, weld, reload the animation) on every
-- flick of the scroll wheel would be far more work than a few transparency
-- writes.
--
-- LocalTransparencyModifier layers on top of each part's own Transparency
-- instead of replacing it, so restoring means writing 0 rather than
-- remembering what every part was built with - which matters here because the
-- rig's Torso is deliberately built fully transparent and must STAY invisible
-- when the arms come back.
local function setArmsHidden(hidden)
	if not currentArms then
		return
	end
	local modifier = if hidden then 1 else 0
	for _, part in currentArms:GetDescendants() do
		if part:IsA("BasePart") or part:IsA("Decal") then
			part.LocalTransparencyModifier = modifier
		end
	end
	armsHidden = hidden
end

local function removeArms()
	if currentSteerConnection then
		currentSteerConnection:Disconnect()
		currentSteerConnection = nil
	end
	if currentVisibilityConnection then
		currentVisibilityConnection:Disconnect()
		currentVisibilityConnection = nil
	end
	if currentArms then
		currentArms:Destroy()
		currentArms = nil
	end
	armsHidden = false
end

local function attachArms(carModel)
	removeArms()

	local driverSeat = VehicleSeats.GetDriverSeat(carModel)
	if not driverSeat then
		return
	end

	local arms = template:Clone()
	arms.Name = "ViewmodelArms"
	-- PrimaryPart stays whatever it's set to in the model (HumanoidRootPart -
	-- required for the Animation Editor to treat this as an animatable rig).
	-- Main is a separate part we use purely as a positioning reference.
	local mainPart = arms:FindFirstChild("Main")
	if not mainPart then
		arms:Destroy()
		return
	end

	-- The rig keeps a Humanoid only so the Animation Editor recognizes
	-- HumanoidRootPart as a valid rig root while editing the template in
	-- ReplicatedStorage. At runtime it's pure baggage: once this clone is
	-- welded into the car's physics assembly, a live Humanoid's own state
	-- machine (trying to stay upright, walk, etc.) fights the car's raycast
	-- suspension for control of that assembly - which is exactly what was
	-- causing cars to mysteriously grind to a halt a second or two after
	-- getting in. Playback goes through AnimationController/Animator, not
	-- the Humanoid, so it's safe to just remove it here.
	local humanoid = arms:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end

	for _, part in arms:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			-- Massless: this rig is a visual prop, not part of the car's
			-- weight - without this it would quietly change the chassis'
			-- mass and throw off handling every time someone gets in.
			part.Massless = true
		end
	end

	-- Main itself is just a reference point, never meant to be seen (Torso is
	-- hidden separately, by hand, in the model).
	mainPart.Transparency = 1

	-- Figure out the rigid transform that brings Main to its target spot over
	-- the seat, then apply that SAME transform to the model's actual pivot
	-- (HumanoidRootPart). This positions the rig based on Main's placement
	-- without needing Main to be PrimaryPart. Has to happen before welding -
	-- WeldConstraint locks in whatever relative CFrame the two parts have at
	-- the moment it's created.
	local targetMainCFrame = driverSeat.CFrame * SEAT_OFFSET
	local delta = targetMainCFrame * mainPart.CFrame:Inverse()
	arms:PivotTo(delta * arms:GetPivot())

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = driverSeat
	weld.Part1 = mainPart
	weld.Parent = mainPart

	arms.Parent = workspace
	currentArms = arms

	-- Its own connection rather than a few lines inside the steering one
	-- below, which only exists when the grip animation loaded. Whether the
	-- hands should be on screen at all does not depend on whether they are
	-- posed correctly.
	currentVisibilityConnection = RunService.RenderStepped:Connect(function()
		local hide = not VehicleViewMode.IsFirstPerson()
		if hide ~= armsHidden then
			setArmsHidden(hide)
		end
	end)

	local animationController = arms:FindFirstChildOfClass("AnimationController")
	local animator = animationController and animationController:FindFirstChildOfClass("Animator")
	if animator then
		local track = animator:LoadAnimation(GRIP_ANIMATION)
		-- Looped: a non-looping track that reaches TimePosition == Length is
		-- treated by Roblox as "finished" and stops applying the pose at all
		-- (reverting to default) - which was exactly why full-right steering
		-- made the arms flop to a default pose while full-left (TimePosition
		-- 0, not a boundary Roblox treats as "the end") was fine. Looping
		-- keeps the track alive at any TimePosition.
		track.Looped = true
		-- Speed 0: this track is never "played" in the normal sense - its
		-- TimePosition is scrubbed directly from steering input every frame
		-- below, so nothing should advance it on its own.
		track:Play(0)
		track:AdjustSpeed(0)

		currentSteerConnection = RunService.RenderStepped:Connect(function()
			-- Read fresh every frame rather than once outside the loop -
			-- Length can briefly report 0 right after LoadAnimation, before
			-- the animation asset has actually finished loading.
			local length = track.Length
			-- Kept a hair below the true end so scrubbing never lands
			-- exactly on the boundary Roblox treats as "finished",
			-- belt-and-suspenders with Looped above.
			local maxTimePosition = math.max(length - 0.01, 0)

			-- LocalSmoothSteer (set by RayCastSuspension every frame, purely
			-- local, no network round-trip) is the driver's own frame-perfect
			-- steer value - the same one the actual wheel prop turns with.
			-- NetSteer is only a fallback for the first frame or so, before
			-- that script has run yet; using it as the steady-state source
			-- was what made the animation look choppy, since it only updates
			-- on a network tick instead of every frame.
			local netSteer = carModel:GetAttribute("LocalSmoothSteer") or carModel:GetAttribute("NetSteer") or 0
			local normalizedSteer = (netSteer + 1) / 2 -- -1..1 -> 0..1
			track.TimePosition = math.clamp(normalizedSteer * length, 0, maxTimePosition)
		end)
	end
end

local function onSeated(isSeated, seatPart)
	if not isSeated or not seatPart then
		removeArms()
		return
	end

	local carModel = seatPart.Parent
	if not carModel or VehicleSeats.GetDriverSeat(carModel) ~= seatPart then
		removeArms()
		return
	end

	attachArms(carModel)
end

local function bindCharacter(character)
	local humanoid = character:WaitForChild("Humanoid")
	humanoid.Seated:Connect(onSeated)
	humanoid.Died:Connect(removeArms)
end

if player.Character then
	bindCharacter(player.Character)
end
player.CharacterAdded:Connect(bindCharacter)

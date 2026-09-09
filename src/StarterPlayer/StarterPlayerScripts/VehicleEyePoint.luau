-- Where a player's eyes are while they are sitting in a car, decided by the
-- CAR rather than by their avatar.
--
-- THE PROBLEM
--
-- Roblox's camera follows the character: in first person it sits on the head,
-- and how high the head is depends entirely on which avatar the player turned
-- up in. A short-torso bundle is a driver whose eyeline is below the
-- dashboard and who is looking at the steering wheel instead of the road; a
-- tall one looks through the roof lining. Same truck, same gap, different
-- game - and this is a game scored on judging gaps, so that is not a cosmetic
-- difference, it is the difficulty changing with what somebody is wearing.
--
-- Note it is TORSO, not total height, that decides this. Legs are irrelevant:
-- the seat weld puts the root part in the same place whatever length they are,
-- so an avatar with normal proportions and stubby legs already sits correctly,
-- and only the torso/neck/head stack above the seat actually moves the eye.
--
-- WHY NOT JUST FORCE EVERY AVATAR TO ONE HEIGHT
--
-- It looks like the smaller fix and isn't:
--   * It doesn't fix this. Forcing total height leaves PROPORTION free, and
--     proportion is the half that matters - the short-torso rig above is
--     exactly the case that survives a height clamp.
--   * A bigger rig is a HEAVIER rig, and a seated character is welded into the
--     car's assembly - so forcing everyone tall makes the seated-mass problem
--     (see VehicleDoors.server.luau) worse, not better. Mass goes with volume,
--     so it is the CUBE of whatever scale is forced.
--   * It throws away the avatar the player chose, which is the one thing in
--     the game that is theirs.
--
-- Pinning the eye instead fixes the actual complaint and leaves avatars alone.
-- It is the same principle the seated-mass fix is built on: how a car drives,
-- and what you can see out of it, are properties of the car.
--
-- HOW, AND WHY NOT Humanoid.CameraOffset
--
-- CameraOffset is the obvious lever and it does not work: Roblox ignores it in
-- first person. Measured in this game, with the camera in first person,
-- Camera.Focus tracked the HEAD exactly while CameraOffset was driven past 300
-- studs with no effect whatsoever. It moves the camera in third person only,
-- which is the view that did not need fixing.
--
-- So the eye is a real point in the world instead: a tiny invisible seat held
-- at the configured spot in the cab, made the camera's CameraSubject. Roblox
-- follows a BasePart subject exactly - no rig-derived head offset of its own -
-- so the eye lands precisely where the config says, for every avatar.
--
-- WHY THE EYE IS A VehicleSeat AND NOT A PLAIN PART
--
-- Because sitting in a VehicleSeat is what turns Roblox's camera with the
-- vehicle, and it decides that from the CameraSubject's CLASS. Roblox sets the
-- subject to the VehicleSeat you sit in, and its vehicle camera - the thing
-- that keeps your view pointing where the truck is pointing as you steer -
-- runs only while the subject is one. An earlier version of this module
-- pointed the subject at a plain Part, which silently switched that off and
-- turned driving into a two-handed job: steer with one hand, drag the mouse
-- back towards the windshield with the other. It fails SILENTLY and it fails
-- at a distance from its cause, so if the camera ever stops turning with the
-- car again, this is the first thing to check.
--
-- Making the eye a (disabled, unoccupiable, invisible) VehicleSeat satisfies
-- both requirements at once: Roblox reads its CLASS and turns the camera with
-- the car, and reads its POSITION and puts the eye exactly where the config
-- says. Nobody can sit in it - Disabled is set - and with no occupant it
-- applies no forces of its own.
--
-- It is WELDED to the real seat rather than anchored and moved each frame,
-- because Roblox's vehicle camera reads the subject's assembly motion to work
-- out how the vehicle is turning. An anchored part reports no motion at all,
-- which is the same as telling that camera the truck never turns. Welded it
-- reports the car's, because it IS the car's - and Massless, so a camera prop
-- cannot change what the suspension is holding up. Exactly the arrangement
-- ViewmodelArms.client.luau already uses for the driving hands.
--
-- THE PRICE, AND IT IS PAID BELOW
--
-- Roblox's first-person character hiding (TransparencyController) works out
-- whose body to hide from the CameraSubject: for a VehicleSeat it hides the
-- seat's OCCUPANT, and the eye seat deliberately has none. So it hides nothing
-- and the driver ends up looking at the inside of their own head. This module
-- hides the local character itself instead - see updateCharacterVisibility.
-- (Making the eye seat occupied is not an option; it would mean unseating the
-- player from the seat that actually drives the car.)
--
-- One consequence worth knowing: the arms and the eye now agree with each
-- other for everybody. ViewmodelArms.client.luau always welded the driving
-- hands to the seat, so before this the hands sat in a fixed spot in the cab
-- while the head they were viewed from wandered by avatar.
--
-- Lifecycle (attach on sitting down, detach on standing up, dying or
-- respawning) lives in VehicleEyeLevel.client.luau.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local player = Players.LocalPlayer

local VehicleEyePoint = {}

-- An Attachment of this name on a seat overrides the config height outright.
-- The height is the knob for "a bit higher/lower in this cab"; this is for
-- when the eye wants placing properly - forward or back off the seat's centre
-- as well as up - which is far easier done by dragging an attachment around
-- the cab in Studio than by guessing numbers in a config file.
local EYE_ATTACHMENT_NAME = "EyePoint"

-- Just BEFORE the default camera's own update (which runs at
-- RenderPriority.Camera), so a CameraSubject put back this frame is in place
-- by the time that camera reads it. The eye's POSITION needs nothing here -
-- it is welded to the seat, so physics carries it.
local RENDER_NAME = "VehicleEyePoint"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value - 1

-- Roblox exposes no "am I in first person" flag, so it is measured as the
-- distance between the camera and what it is looking at - the zoom distance.
-- Generous enough to cover the small standoff the camera keeps in first
-- person, far below the closest third person zoom the default controller
-- allows.
local FIRST_PERSON_DISTANCE = 1.5

local activeSeat = nil
local eyePart = nil
local characterHidden = false

-- Where the eye belongs, as a transform in the SEAT's own space. Resolved once
-- on entry, which is all that is needed: the eye seat is welded to the real
-- one, so this offset is what the weld freezes and nothing has to recompute it
-- per frame.
--
-- An EyePoint Attachment's CFrame is already relative to the seat it is
-- parented to, so both routes come out in the same space and the caller has
-- only one case to handle.
local function seatEyeOffset(seat)
	local attachment = seat:FindFirstChild(EYE_ATTACHMENT_NAME)
	if attachment and attachment:IsA("Attachment") then
		return attachment.CFrame
	end

	-- Falls back to the shared default if there is no chassis to read a config
	-- off, rather than to zero - an eye at the seat's own centre is inside the
	-- seat back, which is worse than a slightly wrong height.
	local carModel = seat.Parent
	local chassis = carModel and carModel.PrimaryPart
	local height = VehiclePhysics.Defaults.SeatEyeHeight
	if chassis then
		height = VehiclePhysics.GetConfig(chassis).SeatEyeHeight or height
	end

	-- Up the SEAT's own axis, not the world's, so the eye rolls and pitches
	-- with the car exactly as a real driver's head would.
	return CFrame.new(0, height, 0)
end

-- The point the player is actually looking FROM, whatever they are doing: the
-- pinned eye while seated, the head while on foot. Callers that used to read
-- the head directly should read this instead - the head stopped being the
-- answer the moment the camera was pinned somewhere else.
--
-- Returns nil only when there is nothing to measure at all - no character, or
-- one still streaming in - so callers keep their existing "no head yet" branch
-- rather than being handed a plausible-looking wrong position.
function VehicleEyePoint.GetViewOrigin()
	if eyePart then
		return eyePart.Position
	end
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	return head and head.Position or nil
end

-- The geometric half of "am I in first person", owned here because this module
-- owns the point being measured against. VehicleViewMode wraps it with the
-- separate question of whether the player is ALLOWED third person; call that
-- one unless a require cycle is in the way.
function VehicleEyePoint.IsFirstPerson()
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return true
	end
	local camera = workspace.CurrentCamera
	if not camera then
		-- Nothing to measure - assume the locked-down state rather than the
		-- more permissive one.
		return true
	end

	-- Camera against its own Focus, NOT against the eye, and this is load
	-- bearing. CFrame and Focus are written by the same camera update, so they
	-- are always a matched pair however stale the pair itself is. Measuring the
	-- camera against the eye instead mixes two different instants: this runs
	-- before the camera has updated, so the camera position is a frame old
	-- while the eye - welded to the car, moved by physics - is current. A truck
	-- at 60 studs/s covers a stud between frames, which was enough to push a
	-- genuinely first-person driver over the threshold on any given frame and
	-- flash their own avatar across the screen.
	--
	-- It is also what Roblox's own TransparencyController measures, for the
	-- same reason.
	return (camera.CFrame.Position - camera.Focus.Position).Magnitude <= FIRST_PERSON_DISTANCE
end

-- Roblox's own first-person hiding is out of action while the CameraSubject is
-- the unoccupied eye seat (see the header - it hides a VehicleSeat's OCCUPANT,
-- and this one deliberately has none), so it is done here instead. Decals as
-- well as parts: a face is a Decal, and a Decal on a fully transparent part
-- still renders, which would leave a pair of eyes hanging in front of the
-- camera.
--
-- LocalTransparencyModifier rather than Transparency, for the same reason
-- Roblox uses it: it is client-only and non-replicating, and it layers on top
-- of whatever transparency a part was built with instead of overwriting a
-- value we would then have to remember and put back.
local function setCharacterHidden(hidden)
	local character = player.Character
	if not character then
		return
	end
	local modifier = if hidden then 1 else 0
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") then
			descendant.LocalTransparencyModifier = modifier
		end
	end
	characterHidden = hidden
end

local function updateCharacterVisibility()
	if VehicleEyePoint.IsFirstPerson() then
		-- Re-applied every frame while hidden rather than only on the
		-- transition into it, so an accessory added mid-drive cannot end up
		-- stuck in front of the camera. A few dozen property writes - Roblox's
		-- own controller does exactly the same thing.
		setCharacterHidden(true)
	elseif characterHidden then
		setCharacterHidden(false)
	end
end

local function step()
	if not eyePart or not activeSeat or not activeSeat.Parent then
		return
	end

	-- Re-asserted rather than set once: Roblox assigns the CameraSubject
	-- itself when a humanoid sits in a VehicleSeat, and that can land after
	-- this module has already attached (entering is a scripted sequence, not
	-- one atomic moment - see tryEnter in VehicleDoors.server.luau). Losing
	-- the subject means silently losing the eye height, with nothing to show
	-- for it but a driver who cannot see out, so it is checked every frame -
	-- a property comparison, and a write only on the frame it actually moved.
	local camera = workspace.CurrentCamera
	if camera and camera.CameraSubject ~= eyePart then
		camera.CameraSubject = eyePart
	end

	updateCharacterVisibility()
end

function VehicleEyePoint.Detach()
	if not activeSeat then
		return -- nothing bound, and nothing to put back
	end
	RunService:UnbindFromRenderStep(RENDER_NAME)

	if characterHidden then
		setCharacterHidden(false)
	end
	if eyePart then
		eyePart:Destroy()
		eyePart = nil
	end
	activeSeat = nil

	-- Back to the Humanoid, which is what Roblox sets on spawn and what every
	-- on-foot camera behaviour expects - including the first-person hiding this
	-- module has been standing in for. Re-read from the live character rather
	-- than remembered from Attach: by the time this runs the player may have
	-- respawned, and restoring a subject inside a destroyed character strands
	-- the camera over the old body.
	local camera = workspace.CurrentCamera
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if camera and humanoid then
		camera.CameraSubject = humanoid
	end
end

function VehicleEyePoint.Attach(seat)
	VehicleEyePoint.Detach()

	local camera = workspace.CurrentCamera
	if not camera or not seat or not seat.Parent then
		return
	end

	activeSeat = seat

	-- A VehicleSeat, not a Part - see the header. Everything below exists to
	-- make it a camera reference and nothing else.
	local part = Instance.new("VehicleSeat")
	part.Name = "VehicleEyePoint"
	part.Size = Vector3.one * 0.1 -- it only has to be a BasePart to be a CameraSubject; the size is never seen
	part.Transparency = 1
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false -- so it can never be what a mirror's occlusion ray or an exit clearance check hits
	part.Locked = true
	part.Massless = true -- welded into the car's assembly; a camera prop must not change what the suspension holds up
	part.Disabled = true -- nobody can sit in it, so it can never steal the driver off the seat that drives the car
	part.HeadsUpDisplay = false -- it would never have an occupant to draw one for, but this is the same call Raycast.server.luau makes on the real seat

	-- Parented to workspace rather than into the car, so nothing that walks a
	-- car's descendants (damage, lights, the mirror renderer) has to learn to
	-- skip it. Client-only, like the viewmodel arms - the server never sees it.
	--
	-- Placed AFTER parenting and welded immediately afterwards, in that order:
	-- a WeldConstraint freezes whatever relative CFrame the two parts have when
	-- it activates, so the position has to be the current one rather than one
	-- read before the car had a chance to move.
	part.Parent = workspace
	part.CFrame = seat.CFrame * seatEyeOffset(seat)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = seat
	weld.Part1 = part
	weld.Parent = part

	eyePart = part
	camera.CameraSubject = part

	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, step)
end

return VehicleEyePoint

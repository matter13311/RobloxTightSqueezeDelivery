-- Getting in and out of a car. The player is teleported onto the seat (and
-- back out again) with the door open/close cue played over the top - there is
-- no physical door swing any more.
--
-- WHY THE HINGES WENT
--
-- A swinging door has to be its own physics assembly, because that is what a
-- HingeConstraint is for. That made every car three assemblies instead of one,
-- and any hull box overlapping a door was two separate bodies fighting over
-- the same space - the truck shook itself apart until the doors were moved
-- into their own collision group. The enter/exit sequences also had to be
-- async around the swing (open, wait, seat, wait, close), which is where most
-- of their state and most of their bugs lived.
--
-- Doors are now plain welded panels in the Body folder, which means they are
-- one assembly with the chassis, and - as a bonus - they are cosmetic damage
-- parts like any other, so a hard enough crash knocks one clean off.
--
-- Server-authoritative for the same reason VehicleLightSwitches is: a client
-- can fire the enter/exit remotes, but never seat anyone by itself. The "Enter"
-- UI is a custom BillboardGui (VehicleDoorPrompts.client.luau) which decides
-- WHEN to offer the prompt; distance is still re-checked here rather than
-- trusted from the client.
--
-- WHERE "THE DOOR" IS, NOW THAT THERE ISN'T ONE
--
-- The Exit# attachments on the Chassis (see VehicleExits) - ground level, just
-- outside each door. They already existed to decide where a player steps out,
-- they are on the chassis so nothing can knock them off, and they are exactly
-- the "you are standing at a door" reference the prompt and the range check
-- need. That is why there is no door rig module any more.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VehicleCollision = require(ReplicatedStorage.Modules.Vehicles.VehicleCollision)
local VehicleExits = require(ReplicatedStorage.Modules.Vehicles.VehicleExits)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local VehicleFolder = workspace.Vehicles

-- Deliberately looser than the client's own prompt-visibility range (see
-- MAX_PROMPT_DISTANCE in VehicleDoorPrompts.client.luau) - this exists to catch
-- a cheated/forged request from way outside the car, not to be the source of
-- truth for how close is "close enough". Keep it comfortably above that
-- number: measured from the same exit attachments, but a player who was
-- legitimately in range when they pressed F can still have walked or been
-- shoved a little way off by the time the request lands here.
local MAX_ENTER_DISTANCE = 12

-- The beat between the door-open cue and the door-close cue. With no swing to
-- wait for, this is purely how long the two sounds are held apart so it reads
-- as "door opens, you get in, door shuts" rather than as one noise. Short
-- enough that entering still feels instant.
local DOOR_SOUND_GAP = 0.35

-- Extra pause on the way out before the close cue, so the client's own
-- teleport-out (a frame or two after it gets the go-ahead) has visibly
-- happened before the door is heard shutting.
local EXIT_CLEAR_TIME = 0.3

-- How far above the seat's own centre the character's pivot (its
-- HumanoidRootPart) is placed just before being welded in - see tryEnter. Only
-- has to be close enough that the seat weld has no meaningful error left to
-- resolve; the weld itself decides the exact final position.
local SEAT_PIVOT_HEIGHT = 2

--=============================================================================
-- Leaving a seat without colliding with the car you just got out of
--=============================================================================
--
-- The scripted exit above (tryExit / performExit in RayCastSuspension) always
-- lands the player at a clear Exit# attachment, well outside the car's own
-- geometry, so it never actually needs this. But a passenger seat is a plain
-- Seat, and Roblox's own character controller unseats a sitting Humanoid the
-- instant Jump is pressed - with no attachment, no clearance check, and no
-- say from this script at all. That drops the player wherever the seat
-- happened to be, which is inside or hard against the car's hull, and the
-- Vehicle and Attached collision groups both collide with a standing player
-- (see VehicleCollisionSetup.server.luau) - so the frame the Humanoid
-- controller lets go of the seat weld, the solver finds a body freshly
-- overlapping the chassis and shoves the two apart, which reads as being
-- flung out of the car and can shunt the car itself.
--
-- The seat weld's own no-collide only ever covered the seat-to-character
-- pair while seated; it says nothing about the rest of the car, and it's
-- gone the instant the weld is. So this is not redundant with anything
-- Roblox already does - it is the piece Roblox's built-in seat-exit doesn't
-- cover.
--
-- The fix: whenever ANY seat's Occupant clears - jump-exit or our own
-- scripted one, no need to tell them apart - put that character in a
-- collision group that can't touch the car for a short grace window, then
-- put it back. Harmless for the scripted exit (they're already clear of the
-- car by the time this would matter); it's the only thing standing between a
-- jumping passenger and a shove.
local EXIT_GRACE_GROUP = VehicleCollision.Groups.ExitGrace
local EXIT_COLLISION_GRACE_TIME = 0.75 -- seconds; comfortably longer than the single frame performExit waits on, enough for a jump-exit to clear the hull on foot

local function ensureGroup(name)
	-- RegisterCollisionGroup throws if the group already exists - another
	-- car's setup, or a hot-reload in Studio. Existing is the desired end
	-- state either way; same pattern as VehicleCollisionSetup.server.luau and
	-- RagdollUtility.
	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
end

ensureGroup(EXIT_GRACE_GROUP)
for _, group in { VehicleCollision.Groups.Vehicle, VehicleCollision.Groups.Attached, VehicleCollision.Groups.Cosmetic } do
	-- May not exist yet - VehicleCollisionSetup is a separate script and the
	-- two can run in either order, so these are registered here too rather
	-- than assumed present.
	ensureGroup(group)
	PhysicsService:CollisionGroupSetCollidable(EXIT_GRACE_GROUP, group, false)
end

--=============================================================================
-- A seated character is part of the car, and must not weigh or catch on anything
--=============================================================================
--
-- Seat:Sit() welds the occupant's HumanoidRootPart to the seat, and a weld
-- makes ONE assembly. From that moment the character is not somebody the car
-- is carrying - it is bodywork. Every limb and every accessory Handle is part
-- of the same rigid body as the chassis, with two consequences that both land
-- squarely on the suspension:
--
--   MASS   The character's mass is added to the car's, AT THE SEAT, which is
--          off the centreline. VehiclePhysics.Step divides its impulses by
--          `carPrim.AssemblyMass / 4` - one corner's share, on the assumption
--          that the four corners share the load evenly. A body bolted to one
--          side breaks that in both directions at once: the car is heavier
--          than the Stiffness/Damper numbers were tuned against, AND the extra
--          weight is all on one side, so that side rides low and its two
--          wheels carry a grip load the other two don't. That is the "the car
--          leans towards the driver and won't pull away" report, and it scales
--          with the CUBE of avatar height - a tall bundle is several times the
--          mass of a default rig, hung off one corner.
--
--   SHAPE  A character's parts collide with the world independently of the
--          hulls. The car's real shape is meant to be the Collision folder and
--          nothing else (see VehicleCollision's header); a head poking through
--          the cab roof gives the car a second, invisible shape that catches
--          on things the hulls were built to clear, which in a game about
--          threading gaps is the difference between a route working and not.
--          It also lets one player's elbow shove another player standing
--          beside the truck.
--
-- Both are fixed here, for the same reason: how a car drives is a property of
-- the CAR. Two players in the same truck get the same handling and the same
-- clearances whatever avatar they turned up in - which is also why the eye
-- height they drive from is configured per vehicle rather than taken from
-- their head (see VehicleEyePoint.luau on the client). If driver weight is
-- ever wanted as a mechanic it belongs in a config number like
-- CargoMassFractionPerUnit, chosen on purpose, not inherited from whatever
-- bundle somebody is wearing.
--
-- Applied off the Occupant signal in setupCar rather than inside tryEnter
-- because Roblox seats and unseats characters without this script's say-so (a
-- passenger pressing Jump), and that signal catches every path in and out -
-- exactly the reason the exit grace above hangs off it too.
local SEATED_GROUP = VehicleCollision.Groups.Seated

-- [character] = { [part] = that part's own Massless before we touched it }, so
-- release puts back what was there instead of assuming false. Only populated
-- between sitting down and standing up.
--
-- Weak-keyed: destroying a character clears Seat.Occupant, so the release path
-- normally empties this on its own - but a car despawned out from under an
-- occupant is a route where that is not guaranteed, and a strong key here
-- would pin a dead character (and every part of it) in memory for the life of
-- the server.
local seatedMassless = setmetatable({}, { __mode = "k" })

local function applySeatedPhysics(character)
	if not character or not character.Parent or seatedMassless[character] then
		return
	end

	local previous = {}
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			previous[part] = part.Massless
			part.Massless = true
			-- Only Default is claimed, for the same reason the exit grace
			-- above only claims Default: a character that is mid-grace or
			-- ragdolled has its group owned by that feature, and taking it
			-- here would leave that feature restoring a group we have since
			-- released out from under it.
			if part.CollisionGroup == "Default" then
				part.CollisionGroup = SEATED_GROUP
			end
		end
	end
	seatedMassless[character] = previous
end

local function releaseSeatedPhysics(character)
	local previous = seatedMassless[character]
	if not previous then
		return
	end
	seatedMassless[character] = nil
	if not character.Parent then
		return
	end

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			-- Parts added while seated (an accessory equipped mid-drive) are
			-- absent from `previous` and get the ordinary standing default,
			-- which is what they would have had anyway.
			part.Massless = previous[part] or false
			if part.CollisionGroup == SEATED_GROUP then
				part.CollisionGroup = "Default"
			end
		end
	end
end

ensureGroup(SEATED_GROUP)
-- Collides with nothing that exists in this game, by design - see SHAPE above.
-- Default is in that list because Default is what the WORLD is: the buildings
-- and kerbs a seated body must not catch on, and the pedestrians it must not
-- shove. The one pairing deliberately left at a new group's default of
-- "collides" is PlotBarrier, whose walls are meant to stop a car - and an
-- occupant riding in it - at the mouth of somebody else's plot.
for _, group in {
	VehicleCollision.Groups.Vehicle,
	VehicleCollision.Groups.Attached,
	VehicleCollision.Groups.Cosmetic,
	VehicleCollision.Groups.Debris,
	EXIT_GRACE_GROUP,
	SEATED_GROUP,
	"Default",
} do
	ensureGroup(group) -- may not exist yet; the scripts that own these run in no guaranteed order
	PhysicsService:CollisionGroupSetCollidable(SEATED_GROUP, group, false)
end

-- [character] = generation number, so a character that jumps out, gets back
-- in, and jumps out again doesn't have an earlier grace period's timer put
-- its collision back to Default out from under the newer one.
local exitGraceGeneration = {}

local function applyExitCollisionGrace(character)
	if not character or not character.Parent then
		return
	end

	local generation = (exitGraceGeneration[character] or 0) + 1
	exitGraceGeneration[character] = generation

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") and part.CollisionGroup == "Default" then
			part.CollisionGroup = EXIT_GRACE_GROUP
		end
	end

	task.delay(EXIT_COLLISION_GRACE_TIME, function()
		-- Only restore if nothing else has claimed this character's collision
		-- group since - a later jump-exit's own grace period, or the
		-- character having been ragdolled (RagdollUtility owns that group
		-- while it applies and already restores to Default on its own).
		if exitGraceGeneration[character] ~= generation then
			return
		end
		exitGraceGeneration[character] = nil
		if not character.Parent then
			return
		end
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") and part.CollisionGroup == EXIT_GRACE_GROUP then
				part.CollisionGroup = "Default"
			end
		end
	end)
end

local doorSoundEvent = Instance.new("RemoteEvent")
doorSoundEvent.Name = "PlayDoorSound"
doorSoundEvent.Parent = ReplicatedStorage

local enterVehicleEvent = Instance.new("RemoteEvent")
enterVehicleEvent.Name = "EnterVehicle"
enterVehicleEvent.Parent = ReplicatedStorage

local exitVehicleEvent = Instance.new("RemoteEvent")
exitVehicleEvent.Name = "ExitVehicle"
exitVehicleEvent.Parent = ReplicatedStorage

-- [carModel] = { CarModel, Seats = { [seatInstance] = { Seat, IsDriverSeat, Busy } } }
local carsData = {}

-- Authoritative ownership gate. The rule itself lives in VehicleOwnership so
-- the client's "Enter" prompt can ask the same question and never offer a car
-- that would be refused here - but this is the copy that decides, and it runs
-- on a request the client cannot forge past.
--
-- Only gates the DriverSeat. Passenger seats are open to anyone - riding
-- along doesn't grant control of the car, so ownership has nothing to protect
-- there, and VehicleDoorPrompts.client.luau's own ShouldShow already agrees.
local function playerCanEnter(player, carModel, seatData)
	if not seatData.IsDriverSeat then
		return true
	end
	return VehicleOwnership.CanEnter(player, carModel)
end

local function attachmentPosition(exit)
	return if exit:IsA("Attachment") then exit.WorldPosition else exit.Position
end

-- Nearest exit attachment to a world position, and how far away it is. Shared
-- by entering (nearest to where the player is actually standing) and by the
-- sound cue (so the door you hear is the one you are next to).
local function nearestExitToPosition(carModel, referencePosition)
	local best, bestDistance = nil, math.huge
	for _, exit in VehicleExits.GetExits(carModel) do
		local distance = (attachmentPosition(exit) - referencePosition).Magnitude
		if distance < bestDistance then
			best, bestDistance = exit, distance
		end
	end
	return best, bestDistance
end

-- Only fires to a player who's still actually connected - a player who left
-- mid-sequence has a dead Instance that FireClient would otherwise error on.
--
-- `at` is an Exit Attachment rather than a door part: a Sound parented to an
-- Attachment plays at that attachment's world position, so the cue still comes
-- from the right side of the truck without a door existing to hang it on.
local function fireDoorSound(player, at, action)
	if player.Parent and at then
		doorSoundEvent:FireClient(player, at, action)
	end
end

local function tryEnter(carData, seatData, exit, player)
	if seatData.Busy or seatData.Seat.Occupant then
		return
	end
	if not playerCanEnter(player, carData.CarModel, seatData) then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.SeatPart then
		return -- already sitting somewhere (this car or another) - can't be entering a second one
	end

	seatData.Busy = true

	local ok, err = pcall(function()
		fireDoorSound(player, exit, "Open")

		-- Put the character ON the seat, facing the way the seat faces, BEFORE
		-- welding them to it. Seat:Sit() creates a rigid weld and leaves the
		-- solver to resolve whatever error is left between the two ends - and
		-- an anchored car cannot resolve anything, because an anchored assembly
		-- does not simulate at all. So the entire error was still sitting there
		-- unresolved at the moment the car was unanchored, at which point both
		-- ends were dynamic and the solver split the correction between them by
		-- mass: instead of the character being pulled into the seat, the CAR
		-- swung round to line up with whichever way the character happened to
		-- be facing when they pressed F. Landing them on the seat first leaves
		-- the weld with essentially no error to resolve, so there is nothing
		-- left to swing the car with.
		local seatPivot = seatData.Seat.CFrame * CFrame.new(0, SEAT_PIVOT_HEIGHT, 0)
		character:PivotTo(seatPivot)
		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			-- They were running a moment ago. Once welded that momentum becomes
			-- the whole car's momentum.
			rootPart.AssemblyLinearVelocity = Vector3.zero
			rootPart.AssemblyAngularVelocity = Vector3.zero
		end

		seatData.Seat:Sit(humanoid)
		seatData.Busy = false -- committed - Seat.Occupant now guards re-entry on its own

		task.wait(DOOR_SOUND_GAP)
		fireDoorSound(player, exit, "Close")
	end)

	-- Safety net: if the sequence above errored before reaching its own release
	-- point, don't leave this seat permanently unusable.
	seatData.Busy = false
	if not ok then
		warn("VehicleDoors: enter sequence errored for " .. carData.CarModel:GetFullName() .. ": " .. tostring(err))
	end
end

local function tryExit(carData, seatData, player)
	if seatData.Busy or not seatData.Seat.Occupant then
		return
	end
	local occupantCharacter = seatData.Seat.Occupant.Parent
	local occupantPlayer = Players:GetPlayerFromCharacter(occupantCharacter)
	if occupantPlayer ~= player then
		return
	end

	seatData.Busy = true

	local ok, err = pcall(function()
		-- The seat's preferred exit if it's clear, otherwise the nearest other
		-- one that is - see VehicleExits.ChooseExit. The same attachment is
		-- used for the sound and sent to the client, so what you hear and where
		-- you land always agree.
		local chosenExit = VehicleExits.ChooseExit(carData.CarModel, seatData.Seat, occupantCharacter)
		fireDoorSound(player, chosenExit, "Open")

		-- Go-ahead: the driving client does its own unseat + step-out (see
		-- tryExitVehicle in RayCastSuspension.client.luau) once it gets this.
		if player.Parent then
			exitVehicleEvent:FireClient(player, chosenExit)
		end
		seatData.Busy = false -- released as soon as the client's been told to go

		task.wait(EXIT_CLEAR_TIME)
		fireDoorSound(player, chosenExit, "Close")
	end)

	seatData.Busy = false
	if not ok then
		warn("VehicleDoors: exit sequence errored for " .. carData.CarModel:GetFullName() .. ": " .. tostring(err))
	end
end

local function setupCar(carModel)
	local driverSeat = VehicleSeats.GetDriverSeat(carModel)
	if not driverSeat then
		warn("VehicleDoors: " .. carModel:GetFullName() .. " has no DriverSeat - skipping")
		return
	end
	if #VehicleExits.GetExits(carModel) == 0 then
		warn(
			"VehicleDoors: "
				.. carModel:GetFullName()
				.. " has no Exit# attachments on its Chassis - nobody will be able to get in or out. See VehicleExits."
		)
		return
	end

	local seats = {}
	for _, seat in VehicleSeats.GetAllSeats(carModel) do
		-- Walking into the seat would otherwise sit the player instantly,
		-- bypassing the prompt entirely - Seat:Sit(humanoid) (used by tryEnter
		-- above) still works fine on a Disabled seat, so this only blocks the
		-- automatic touch-to-sit path, not our own scripted one.
		seat.Disabled = true
		seats[seat] = { Seat = seat, IsDriverSeat = seat == driverSeat, Busy = false }

		-- Catches every way a seat FILLS and every way it empties out, not
		-- just our own tryEnter/tryExit - most importantly, a passenger
		-- hitting Jump, which Roblox unseats on its own without ever going
		-- through this script. See the two collision sections above for why
		-- each end needs handling at all.
		local lastCharacter = nil
		seat:GetPropertyChangedSignal("Occupant"):Connect(function()
			local occupant = seat.Occupant
			if occupant then
				lastCharacter = occupant.Parent
				applySeatedPhysics(lastCharacter)
			elseif lastCharacter then
				-- Order matters: the release puts these parts back to Default,
				-- and Default is the only group the exit grace will claim.
				releaseSeatedPhysics(lastCharacter)
				applyExitCollisionGrace(lastCharacter)
				lastCharacter = nil
			end
		end)
	end

	carsData[carModel] = { CarModel = carModel, Seats = seats }
end

local function trySetupCar(carModel)
	local ok, err = pcall(setupCar, carModel)
	if not ok then
		warn("VehicleDoors: failed to set up " .. carModel:GetFullName() .. ": " .. tostring(err))
	end
end

-- The client-side prompts (see VehicleDoorPrompts.client.luau) only decide
-- WHEN to show each seat's "Enter"/"Ride Along" UI and fire this with the seat
-- they're attached to - which door that resolves to is decided here, from the
-- player's actual position, rather than trusted from the client. The seat
-- itself IS trusted only as far as "is this actually one of this car's seats"
-- - a forged seat gets rejected by the carData.Seats lookup, and playerCanEnter
-- (inside tryEnter) still re-checks ownership for the DriverSeat regardless of
-- what the client claims.
enterVehicleEvent.OnServerEvent:Connect(function(player, carModel, seat)
	local carData = typeof(carModel) == "Instance" and carsData[carModel]
	local seatData = carData and typeof(seat) == "Instance" and carData.Seats[seat]
	if not seatData then
		return
	end

	local character = player.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local exit, distance = nearestExitToPosition(carModel, rootPart.Position)
	if not exit or distance > MAX_ENTER_DISTANCE then
		return
	end

	tryEnter(carData, seatData, exit, player)
end)

-- One shared remote for every car, so the handler has to work out which car
-- and seat (if any) the requesting player is actually seated in rather than
-- assuming.
exitVehicleEvent.OnServerEvent:Connect(function(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seatPart = humanoid and humanoid.SeatPart
	local carData = seatPart and carsData[seatPart.Parent]
	local seatData = carData and carData.Seats[seatPart]
	if seatData then
		tryExit(carData, seatData, player)
	end
end)

for _, carModel in VehicleFolder:GetChildren() do
	trySetupCar(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetupCar)
VehicleFolder.ChildRemoved:Connect(function(carModel)
	carsData[carModel] = nil
end)

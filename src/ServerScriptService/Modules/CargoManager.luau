-- The authority on what is actually loaded on a truck: builds the crates and
-- the ballast that gives them weight, and turns crashes into ruined goods.
--
-- A module rather than a *.server.luau script, matching PlayerDataStore: the
-- loading dock and (later) DeliveryManager both need to call into it, and
-- routing server-to-server calls through a RemoteEvent would be silly. The one
-- thing it does not own is impact validation - VehicleDamage.server.luau
-- already validates every crash report (driver check, rate limit, magnitude
-- clamp, distance check) and calls ApplyImpact below with the result, so there
-- is exactly one implementation of that and no way for the two to drift.
--
-- STATE LIVES IN THE DATA MODEL, not in a table in here. What is loaded is
-- four attributes on the car Model (see CargoLoad.Attributes), and the crates
-- themselves live in a "Cargo" folder inside the car. That is deliberate:
-- a vehicle that is destroyed, despawned or re-spawned takes its entire cargo
-- state with it, so there is no per-model table to clean up and no way to leak
-- one. It also means a rejoining client can see a loaded truck with no
-- replication code of our own.
--
-- See docs/CargoDesign.md for why cargo is built this way - in particular why
-- the crates are Massless and all the weight is in one hidden ballast part,
-- and why nothing loose is ever added to the assembly.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
local CargoTypes = require(ReplicatedStorage.Modules.Delivery.CargoTypes)
local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local CargoManager = {}

local CARGO_FOLDER_NAME = "Cargo"
local BALLAST_NAME = "CargoBallast"

--=============================================================================
-- Layout
--=============================================================================

-- The crate grid itself lives in CargoLoad.Layout / CargoLoad.CrateOffset, so
-- the contract board's preview stacks crates exactly the way this does. See
-- the comment there.

-- Whether crates are part of the truck's collision silhouette.
--
-- TRUE is the interesting answer for this game: a tall load genuinely will not
-- fit under a low bridge, and a wide one will not fit down the alley an empty
-- truck sails through. That is the "tight squeeze" premise applied to the
-- thing the player chose to carry.
--
-- The risk is that crates are added AFTER VehicleCollisionSetup.server.luau
-- has run over the vehicle, so they are not in its collision group by default.
-- buildCrate copies the chassis's group to fix that. If loaded trucks start
-- behaving strangely - shoving themselves, catching on their own bodywork -
-- set this false first; that isolates the collision group as the cause in one
-- step, at the cost of loads no longer blocking anything.
local CRATES_COLLIDE = true

-- The invisible part that carries the entire load's weight. Fixed size, with
-- density solved to hit the target mass, because one part with one number is
-- something you can reason about and verify; mass spread across the visible
-- crates would shift the centre of mass differently for every crate count.
--
-- 4x4x4 = 64 studs^3, and Roblox caps density at 100, so this can represent up
-- to 6400 mass units. Well past anything a truck in this game should weigh; if
-- it ever clamps, applyBallast warns rather than silently under-loading.
local BALLAST_SIZE = Vector3.new(4, 4, 4)
local BALLAST_MAX_DENSITY = 100

--=============================================================================
-- Finding the bed
--=============================================================================

-- The bed's origin and orientation. LookVector runs along the bed toward the
-- tailgate, RightVector across it, UpVector out of it - so crate layout is
-- just offsets in that frame and works on any vehicle regardless of which way
-- its chassis part happens to be modelled.
--
-- Falls back to the rear half of the model's bounding box if the attachment is
-- missing, so cargo works on a vehicle nobody has prepared yet. That fallback
-- is a guess about where the bed is and says so loudly - it is meant to keep
-- you moving, not to be relied on.
local function getBedCFrame(carModel, chassis, config)
	local attachmentName = config.CargoBedAttachmentName or "CargoBed"
	local attachment = chassis:FindFirstChild(attachmentName)
	if attachment and attachment:IsA("Attachment") then
		return attachment.WorldCFrame
	end

	warn(
		string.format(
			"CargoManager: %s has no '%s' Attachment on its Chassis - guessing the bed from the model's bounding "
				.. "box. Add the attachment (see docs/CargoDesign.md section 4.1) to place crates properly.",
			carModel:GetFullName(),
			attachmentName
		)
	)

	local modelCFrame, modelSize = carModel:GetBoundingBox()
	-- Behind the middle and above the roofline of the lower half: roughly where
	-- a pickup bed floor is on most models, and visibly wrong on the ones it
	-- isn't, which is the point of the warning above.
	return modelCFrame * CFrame.new(0, modelSize.Y * 0.15, modelSize.Z * 0.2)
end

--=============================================================================
-- Building
--=============================================================================

local function getCargoFolder(carModel, create)
	local folder = carModel:FindFirstChild(CARGO_FOLDER_NAME)
	if not folder and create then
		folder = Instance.new("Folder")
		folder.Name = CARGO_FOLDER_NAME
		folder.Parent = carModel
	end
	return folder
end

-- Crates are built from CargoTypes numbers rather than cloned from a Studio
-- model so that cargo works with nothing placed by hand. Give a type a
-- TemplateName and clone that here instead once real models exist.
local function buildCrate(cargoType, chassis, index)
	local crate = Instance.new("Part")
	crate.Name = "Crate"
	crate.Size = cargoType.CrateSize
	-- Per-crate rather than the type's flat Color, so a full bed does not read
	-- as one solid slab. Derived from the index so the board's preview matches
	-- crate for crate - see CargoTypes.CrateColor.
	crate.Color = CargoTypes.CrateColor(cargoType, index)
	crate.Material = cargoType.Material
	crate.Anchored = false
	crate.CanCollide = CRATES_COLLIDE
	crate.CanQuery = false -- suspension rays already exclude the whole car, but a crate should never answer anyone else's raycast either
	-- The convention VehicleCollisionSetup established for bodywork: visible
	-- parts weigh nothing, all the mass lives in one place. Here that place is
	-- the ballast.
	crate.Massless = true
	crate.CollisionGroup = chassis.CollisionGroup
	crate.TopSurface = Enum.SurfaceType.Smooth
	crate.BottomSurface = Enum.SurfaceType.Smooth
	return crate
end

local function weldTo(part, chassis)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = chassis
	weld.Part1 = part
	weld.Parent = part
	return weld
end

-- Sets the load's weight, creating the ballast on first use and afterwards
-- only re-solving its density.
--
-- REUSED RATHER THAN REBUILT, because crates now go on one at a time and this
-- is called once per crate. Destroying and re-welding a massive part six times
-- in two seconds would break the assembly apart and put it back together on
-- each step, which a client-owned chassis sitting on a raycast suspension
-- feels as a lurch. Changing CustomPhysicalProperties on a part that is
-- already welded updates AssemblyMass in place and moves nothing.
--
-- Its CFrame is therefore set exactly once, when it is created. That is also
-- why it must not be moved later: it is welded, so writing its CFrame would
-- drag the whole truck with it.
local function applyBallast(carModel, chassis, folder, bedCFrame, mass)
	local existing = folder:FindFirstChild(BALLAST_NAME)
	if mass <= 0 then
		if existing then
			existing:Destroy()
		end
		return
	end

	local volume = BALLAST_SIZE.X * BALLAST_SIZE.Y * BALLAST_SIZE.Z
	local density = mass / volume
	if density > BALLAST_MAX_DENSITY then
		warn(
			string.format(
				"CargoManager: %s needs a ballast density of %.1f to weigh %.0f, above Roblox's cap of %d. The load "
					.. "will be lighter than configured - lower CargoMassFractionPerUnit or enlarge BALLAST_SIZE.",
				carModel:GetFullName(),
				density,
				mass,
				BALLAST_MAX_DENSITY
			)
		)
		density = BALLAST_MAX_DENSITY
	end

	if existing then
		existing.CustomPhysicalProperties = PhysicalProperties.new(density, 0, 0, 1, 100)
		return
	end

	local ballast = Instance.new("Part")
	ballast.Name = BALLAST_NAME
	ballast.Size = BALLAST_SIZE
	ballast.Transparency = 1
	ballast.CanCollide = false
	ballast.CanQuery = false
	ballast.CanTouch = false
	ballast.Anchored = false
	ballast.Massless = false -- the whole point of it
	ballast.CustomPhysicalProperties = PhysicalProperties.new(density, 0, 0, 1, 100)
	-- Sat at bed height rather than at the chassis centre, ON PURPOSE: this is
	-- what raises the centre of mass, and the raised centre of mass is what
	-- makes a full truck lean into corners and feel like it wants to keep
	-- going straight. VehiclePhysics applies tire forces at the contact patch
	-- specifically so the body can roll about it (see its tireForcePosition
	-- comment), so this costs nothing and is real physics rather than a fudge.
	ballast.CFrame = bedCFrame * CFrame.new(0, BALLAST_SIZE.Y / 2, 0)
	ballast.Parent = folder
	weldTo(ballast, chassis)
end

--=============================================================================
-- Public API
--=============================================================================

-- Everything about a truck's load, in one table. Safe on any Model, loaded or
-- not - an empty truck reports zero units rather than nil, so callers never
-- have to nil-check their way through a payout calculation.
function CargoManager.GetLoad(carModel)
	local attributes = CargoLoad.Attributes
	local units = carModel:GetAttribute(attributes.Units)
	local condition = carModel:GetAttribute(attributes.Condition)
	return {
		Units = type(units) == "number" and units or 0,
		TypeId = carModel:GetAttribute(attributes.TypeId) or CargoTypes.DefaultTypeId,
		Condition = type(condition) == "number" and condition or 1,
	}
end

-- The vehicle's mass with nothing aboard, measured once and cached - once the
-- ballast is welded on you can no longer ask for it, and re-deriving it by
-- subtracting what we think we added would compound any error.
local function getEmptyMass(carModel, chassis)
	local cached = carModel:GetAttribute(CargoLoad.Attributes.EmptyMass)
	if type(cached) == "number" and cached > 0 then
		return cached
	end
	local mass = chassis.AssemblyMass
	carModel:SetAttribute(CargoLoad.Attributes.EmptyMass, mass)
	return mass
end

-- Loading takes TIME now (see DeliveryConfig.Loading for why), so there has to
-- be a way to cancel a sequence that is still running - a second Load, an
-- Unload, or the truck being despawned underneath it.
--
-- A counter on the Model rather than a table in this module, for the reason in
-- this file's header: a token that lives on the instance cannot outlive it, so
-- there is no cleanup to forget and no way to leak one. Every Load and every
-- Unload bumps it; a running sequence carries the value it started with and
-- stops the moment the two stop matching.
local function bumpSequence(carModel)
	local current = carModel:GetAttribute(CargoLoad.Attributes.LoadSequence)
	local nextValue = (type(current) == "number" and current or 0) + 1
	carModel:SetAttribute(CargoLoad.Attributes.LoadSequence, nextValue)
	return nextValue
end

-- One crate landing. Parented to the crate itself so it is positioned at the
-- bed - a player standing outside hears the load going on where it is going
-- on - and handed to Debris so a Sound instance never outlives its noise.
--
-- Played on the SERVER, like the horn (see VehicleControls' header): the
-- driver is not the only one who should hear this, and doing it here means one
-- implementation rather than one for the driver and another for everyone else.
local function playCrateSound(crate)
	local loading = DeliveryConfig.Loading
	local ids = loading.SoundIds
	if #ids == 0 then
		return
	end

	local sound = Instance.new("Sound")
	sound.Name = "CrateLoadSound"
	-- Random per crate, so a six-crate load is six thuds rather than the same
	-- sample stuttering. With one id in the list this is simply that id.
	sound.SoundId = ids[math.random(#ids)]
	sound.Volume = loading.SoundVolume
	sound.RollOffMaxDistance = loading.SoundRollOffMaxDistance
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.Parent = crate
	sound:Play()
	Debris:AddItem(sound, 10)
end

-- Places crate number `index` (0-based) and brings the truck's weight up to
-- what `index + 1` crates are worth.
--
-- The bed CFrame is re-read per crate rather than captured once: the truck is
-- immobilised while this runs, but it still bobs on its springs - by design,
-- since each crate landing is meant to make it dip - and a stale frame would
-- weld the later crates in mid-air relative to the bed.
local function placeCrate(carModel, chassis, folder, config, cargoType, emptyMass, index)
	local bedCFrame = getBedCFrame(carModel, chassis, config)

	local crate = buildCrate(cargoType, chassis, index)
	crate.CFrame = bedCFrame * CFrame.new(CargoLoad.CrateOffset(index, cargoType.CrateSize))
	crate.Parent = folder
	weldTo(crate, chassis)
	playCrateSound(crate)

	local placed = index + 1
	applyBallast(carModel, chassis, folder, bedCFrame, CargoLoad.AddedMass(config, emptyMass, placed, cargoType.Id))

	-- Set LAST, and after the ballast, for the same reason it used to be
	-- written last for the load as a whole: it is what the driving client's
	-- physics loop reads, so writing it once the mass is already in the
	-- assembly means there is no frame where the truck handles like it is
	-- laden but weighs nothing. Now it simply walks up one step per crate, and
	-- VehiclePhysics lerps toward it per frame, so the handling penalty
	-- arrives with the weight rather than ahead of it.
	carModel:SetAttribute(CargoLoad.Attributes.LoadFraction, CargoLoad.LoadFraction(config, placed))
	carModel:SetAttribute(CargoLoad.Attributes.LoadingPlaced, placed)
end

-- Replaces whatever is aboard with `units` crates of `typeId`. Returns the
-- number of crates actually loaded, which is `units` clamped to the vehicle's
-- capacity - callers should show that number rather than what they asked for.
--
-- Loading always resets condition to pristine: a load is a fresh set of goods,
-- and carrying over the damage from the last run would punish a player twice
-- for one crash.
--
-- THIS FUNCTION STILL DOES NOT YIELD. The crates go on over the next couple of
-- seconds, but everything a caller can observe - the return value, Units,
-- TypeId, Condition - is committed before it returns, and the placing runs on
-- its own thread. DeliveryManager depends on exactly that: it loads and then
-- takes the contract off the board, and its comment there says in as many
-- words that nothing may slip in between the two.
function CargoManager.Load(carModel, typeId, units)
	local chassis = carModel.PrimaryPart
	if not chassis then
		warn("CargoManager: " .. carModel:GetFullName() .. " has no PrimaryPart, cannot load it")
		return 0
	end

	local config = VehiclePhysics.GetConfig(chassis)
	local cargoType = CargoTypes.GetOrDefault(typeId)
	local loadedUnits = CargoLoad.ClampUnits(config, units)

	-- Also cancels any sequence still running on this truck.
	CargoManager.Unload(carModel)
	if loadedUnits <= 0 then
		return 0
	end

	-- Measured before any ballast exists, which is the only time it can be.
	local emptyMass = getEmptyMass(carModel, chassis)
	local folder = getCargoFolder(carModel, true)

	local attributes = CargoLoad.Attributes
	-- Units is the FINAL count, written up front rather than counted up as
	-- crates arrive: it is the contract the player accepted, and every consumer
	-- of it - the payout, the HUD's "6 x Parcels", the total the loading
	-- overlay draws progress against - wants the load that is coming, not the
	-- part of it that has landed so far. LoadingPlaced is the one that counts.
	carModel:SetAttribute(attributes.TypeId, cargoType.Id)
	carModel:SetAttribute(attributes.Units, loadedUnits)
	carModel:SetAttribute(attributes.Condition, 1)
	carModel:SetAttribute(attributes.LoadFraction, 0)
	carModel:SetAttribute(attributes.LoadingPlaced, 0)

	local sequence = bumpSequence(carModel)
	local loading = DeliveryConfig.Loading
	local interval = math.min(loading.SecondsPerCrate, loading.MaxTotalSeconds / loadedUnits)

	task.spawn(function()
		for index = 0, loadedUnits - 1 do
			task.wait(interval)
			-- Re-checked every step rather than once: between two crates the
			-- truck can have been unloaded, reloaded with something else, or
			-- destroyed outright, and any of those makes the rest of this
			-- sequence wrong to finish.
			if
				carModel:GetAttribute(attributes.LoadSequence) ~= sequence
				or carModel.Parent == nil
				or chassis.Parent == nil
			then
				return
			end
			placeCrate(carModel, chassis, folder, config, cargoType, emptyMass, index)
		end

		-- Deliberately NOT cleared on the same frame the last crate lands: see
		-- CompleteHoldSeconds. The truck is fully loaded and fully weighted by
		-- now - this beat costs the player nothing and buys the overlay a
		-- moment to say so.
		task.wait(loading.CompleteHoldSeconds)
		if carModel:GetAttribute(attributes.LoadSequence) ~= sequence or carModel.Parent == nil then
			return
		end

		-- Removed, not set to false: absence is what CargoLoad.IsLoading tests,
		-- and it is what releases the driving client's immobiliser and closes
		-- the loading overlay.
		carModel:SetAttribute(attributes.LoadingPlaced, nil)
	end)

	return loadedUnits
end

-- Takes everything off and returns what was there, so a caller delivering a
-- load can pay out on the same call that empties the bed.
function CargoManager.Unload(carModel)
	local previous = CargoManager.GetLoad(carModel)

	local folder = getCargoFolder(carModel, false)
	if folder then
		folder:Destroy()
	end

	local attributes = CargoLoad.Attributes
	-- Before anything else: this is what stops a load sequence that is still
	-- placing crates from carrying on into a bed we are about to empty.
	bumpSequence(carModel)
	carModel:SetAttribute(attributes.LoadingPlaced, nil)
	-- LoadFraction first, for the mirror of the reason it is written last in
	-- Load: the weight is about to disappear, so the handling penalty should
	-- go first rather than linger for a frame on an empty truck.
	carModel:SetAttribute(attributes.LoadFraction, 0)
	carModel:SetAttribute(attributes.Units, 0)
	carModel:SetAttribute(attributes.Condition, 1)
	carModel:SetAttribute(attributes.TypeId, nil)
	-- EmptyMass is deliberately kept: it describes the vehicle, not the load.

	return previous
end

--=============================================================================
-- Damage
--=============================================================================

-- Throws one crate off the back, cosmetically. Modelled on
-- VehicleDamage.server.luau's spawnLoosePanel, and for the same reasons:
-- unwelded, given real mass so it falls convincingly, moved out of the car so
-- nothing that scans the vehicle sees it, and handed to Debris so it cannot
-- accumulate.
--
-- The crate is gone for good. It is NOT recoverable, and nothing about the
-- payout depends on where it lands - see the note on ApplyImpact below.
local function ejectCrate(crate, debrisFolder)
	for _, joint in crate:GetChildren() do
		if joint:IsA("WeldConstraint") then
			joint:Destroy()
		end
	end

	crate.Massless = false
	crate.CanCollide = true
	crate.Parent = debrisFolder

	-- Up and backward, roughly out of the bed, plus some spin. The random
	-- component is what stops six crates from a single big hit flying off in
	-- one identical arc.
	local away = Vector3.new(math.random() - 0.5, 1, math.random() - 0.5).Unit
	crate:ApplyImpulse(away * crate.AssemblyMass * (14 + math.random() * 10))
	crate:ApplyAngularImpulse(
		Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * crate.AssemblyMass * 6
	)

	Debris:AddItem(crate, 12)
end

-- A validated crash, applied to the goods. `severity` is 0-1.
--
-- Called from VehicleDamage.server.luau's impact handler, AFTER its validate()
-- has passed - this function trusts its inputs precisely because that one does
-- not.
--
-- Condition is the single source of truth for what the load is worth.
-- Ejected crates are the VISUAL EXPRESSION of a low condition, never a second
-- penalty on top of it: payout uses the units that were loaded multiplied by
-- the condition factor, so a player is never charged twice for one crash. That
-- is also why the Units attribute is not decremented when a crate flies off.
function CargoManager.ApplyImpact(carModel, severity)
	-- Nothing lands on a load that is still being put on. The truck is
	-- immobilised in the bay while this is true, so any impact reaching us here
	-- was somebody else driving into a parked vehicle - which should not cost
	-- its driver a penny - and the eject-crates half below cannot work anyway
	-- while the crate count is still climbing.
	if CargoLoad.IsLoading(carModel) then
		return
	end

	local load = CargoManager.GetLoad(carModel)
	if load.Units <= 0 then
		return
	end

	local condition = CargoLoad.ConditionAfterImpact(load.Condition, severity, load.TypeId)
	if condition >= load.Condition then
		return -- a hit too small to register on this cargo type
	end
	carModel:SetAttribute(CargoLoad.Attributes.Condition, condition)

	local folder = getCargoFolder(carModel, false)
	if not folder then
		return
	end

	local crates = {}
	for _, child in folder:GetChildren() do
		if child.Name == "Crate" then
			table.insert(crates, child)
		end
	end

	-- How many crates a load in this condition should still be showing.
	-- ceil, so a load is never visually empty while it is still worth
	-- something - the last crate leaves only at condition 0.
	local shouldRemain = math.ceil(load.Units * condition)
	local debrisFolder = workspace:FindFirstChild("VehicleDebris") or workspace

	for index = #crates, shouldRemain + 1, -1 do
		ejectCrate(crates[index], debrisFolder)
	end
end

return CargoManager

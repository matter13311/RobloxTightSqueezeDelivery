-- Which model carries the load, which bays it may use, and what has to be
-- inside one - the three questions that have a different answer for a tractor
-- pulling a trailer than for every other vehicle in the game.
--
--                     ordinary truck          tractor (has a Hitch)
--   carries the load  the truck               its hitched trailer
--   loads at          Depot.LoadingBay        Depot.FreightBay
--   parks in          any "Space*" part       RigBay spaces only
--   what must fit     the truck               the TRAILER
--
-- Shared for the reason ParkGrade is: the server decides, but the HUD, the bay
-- guides and the tutorial all have to give the same answer it does or the
-- player is shown a board the server then refuses. Everything that used to ask
-- "is the car in a Space" asks here instead, so an ordinary truck gets exactly
-- the answers it always did and a rig gets its own without a second copy of
-- each caller.
--
-- A BOBTAIL TRACTOR (nothing hitched) CARRIES NOTHING AND PARKS NOWHERE. Its
-- Carrier and ParkModel are nil, so no board opens for it and no bay goes green
-- - which is the honest answer, and what stops a player loading "cargo" onto a
-- truck with no bed. The hitch prompt is what tells them why.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local ParkGrade = require(ReplicatedStorage.Modules.Delivery.ParkGrade)
local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)

local Haulage = {}

local world = DeliveryConfig.World

function Haulage.IsTractor(carModel)
	return carModel ~= nil and TrailerHitch.CanTow(carModel)
end

-- The trailer on the back of this tractor, or nil. Checked for a PrimaryPart
-- because every caller is about to measure or load it.
function Haulage.Trailer(carModel)
	local trailer = carModel and TrailerHitch.GetHitchedTrailer(carModel)
	return if trailer and trailer.Parent and trailer.PrimaryPart then trailer else nil
end

-- The model the cargo goes ON. nil for a bobtail tractor.
function Haulage.Carrier(carModel)
	if Haulage.IsTractor(carModel) then
		return Haulage.Trailer(carModel)
	end
	return carModel
end

-- The model that has to be inside a bay for it to count. The same model as the
-- carrier, and for the same reason: the dock is unloading the trailer, so it is
-- the trailer that has to be on the mark. The tractor is free to sit at an
-- angle in front of it, which is how a real rig ends up after backing in.
Haulage.ParkModel = Haulage.Carrier

--=============================================================================
-- Spaces
--=============================================================================

function Haulage.IsRigSpace(instance)
	return instance:IsA("BasePart") and instance:GetAttribute(world.RigBayAttribute) == true
end

-- Any parking space at all, of either kind. For code that draws every bay
-- (the corner-post guides) rather than deciding which one applies.
function Haulage.IsSpace(instance)
	return instance:IsA("BasePart")
		and (instance.Name:sub(1, #world.SpacePrefix) == world.SpacePrefix or Haulage.IsRigSpace(instance))
end

-- The spaces inside `container` that a vehicle of this kind may use. An
-- ordinary truck keeps every "Space*" part, rig bays included - it always could
-- park in the long bay, and taking that away would be a rule nobody asked for.
function Haulage.SpacesIn(container, rig)
	local spaces = {}
	if not container then
		return spaces
	end
	for _, descendant in container:GetDescendants() do
		if descendant:IsA("BasePart") then
			local usable
			if rig then
				usable = Haulage.IsRigSpace(descendant)
			else
				usable = descendant.Name:sub(1, #world.SpacePrefix) == world.SpacePrefix
			end
			if usable then
				table.insert(spaces, descendant)
			end
		end
	end
	return spaces
end

-- Where this kind of vehicle takes a job: the freight building for a rig, the
-- loading bay for everything else.
function Haulage.DepotBay(rig)
	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	local depotFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DepotFolderName)
	return depotFolder and depotFolder:FindFirstChild(if rig then world.FreightBayName else world.LoadingBayName)
end

function Haulage.DepotSpaces(rig)
	return Haulage.SpacesIn(Haulage.DepotBay(rig), rig)
end

--=============================================================================
-- Parking
--=============================================================================

-- ParkGrade.Evaluate, against whichever model has to be in the bay.
function Haulage.Evaluate(carModel, space)
	local parkModel = Haulage.ParkModel(carModel)
	if not parkModel then
		return { Inside = false }
	end
	return ParkGrade.Evaluate(parkModel, space)
end

-- ParkGrade.Approach, likewise - 1 exactly when Evaluate says Inside.
function Haulage.Approach(carModel, space)
	local parkModel = Haulage.ParkModel(carModel)
	if not parkModel then
		return 0
	end
	return ParkGrade.Approach(parkModel, space)
end

-- Which of `spaces` this vehicle is parked in, plus its grade, or nil.
-- Geometry only: being STOPPED is asked separately, of the driven chassis
-- (ParkGrade.IsStopped), because that is the body the player is controlling.
function Haulage.FindParkedSpace(carModel, spaces)
	local parkModel = Haulage.ParkModel(carModel)
	if not parkModel then
		return nil, nil
	end
	for _, space in spaces do
		local grade = ParkGrade.Evaluate(parkModel, space)
		if grade.Inside then
			return space, grade
		end
	end
	return nil, nil
end

return Haulage

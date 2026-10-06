-- "The depot is over there." A standing GuideMarker on the depot for whenever
-- the player has no job, so finishing a delivery on the far side of the map
-- never leaves them wondering which way to drive for the next one.
--
-- WHAT IT POINTS AT - the depot SIGN, not the building, for the same reason
-- TutorialGuide's placeTarget gives: an AlwaysOnTop outline around a whole
-- warehouse fills the windscreen. The beam does the "where" at range, the
-- screen arrow the "which way", and the outline on the sign the "that one".
--
-- WHEN IT IS ON - no active contract, and every one of:
--   * the tutorial is not running. It already points at the depot during its
--     own steps, and two markers on one place read as two places.
--   * the player is not already at the depot. Inside ShowWithinStuds the bay's
--     corner posts light up (DepotGuides.client.luau) and take over; a beam out
--     of the sign over the bay you are reversing into is just in the way.
--
-- On foot as well as driving: a player who has just walked away from their
-- truck still wants to know where the depot is.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeliveryConfig = require(ReplicatedStorage.Modules.Delivery.DeliveryConfig)
local GuideMarker = require(ReplicatedStorage.Modules.UI.GuideMarker)
local Haulage = require(ReplicatedStorage.Modules.Delivery.Haulage)
local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local VehicleFolder = workspace:WaitForChild("Vehicles")

local world = DeliveryConfig.World

-- The depot sign's own hazard yellow (DepotGuides.client.luau), so the marker
-- and the sign it lands on read as the same thing - and so it can never be
-- mistaken for the tutorial's colour or the destination waypoint's.
local DEPOT_COLOR = Color3.fromRGB(250, 204, 48)

-- Matches TutorialGuide's attribute (TUTORIAL_ACTIVE_ATTRIBUTE there).
local TUTORIAL_ACTIVE_ATTRIBUTE = "TutorialActive"

-- The same range the bay's corner posts light up at, so one takes over exactly
-- as the other goes dark.
local AT_DEPOT_STUDS = DeliveryConfig.Guides.ShowWithinStuds

local POLL_SECONDS = 0.25

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DepotMarkerGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
-- Below the HUD and the tutorial, so the arrow can never sit over a button.
screenGui.DisplayOrder = 0
screenGui.Parent = playerGui

local marker = GuideMarker.new({
	Parent = screenGui,
	Color = DEPOT_COLOR,
	Name = "DepotMarker",
})

--=============================================================================
-- World lookup
--=============================================================================

-- Lazy and re-resolved while missing, like every other depot lookup: the depot
-- is hand-built and streams in, so it may not exist yet when this runs.
local function findLoadingBay()
	local deliveryRoot = workspace:FindFirstChild(world.RootFolderName)
	local depotFolder = deliveryRoot and deliveryRoot:FindFirstChild(world.DepotFolderName)
	return depotFolder and depotFolder:FindFirstChild(world.LoadingBayName)
end

local cachedTarget = nil
local cachedSpaces = {}

-- Sign first, then a bay space, then anything markable - the same order as
-- TutorialGuide's placeTarget. The spaces are kept too, for the at-the-depot
-- check.
local function resolveDepot()
	if cachedTarget and cachedTarget:IsDescendantOf(workspace) then
		return cachedTarget, cachedSpaces
	end

	local loadingBay = findLoadingBay()
	if not loadingBay then
		return nil, cachedSpaces
	end

	local sign, spaces = nil, {}
	for _, descendant in loadingBay:GetDescendants() do
		if descendant:IsA("BasePart") then
			if not sign and descendant.Name:sub(1, #world.SignPrefix) == world.SignPrefix then
				sign = descendant
			elseif descendant.Name:sub(1, #world.SpacePrefix) == world.SpacePrefix then
				table.insert(spaces, descendant)
			end
		end
	end

	local target = sign
		or spaces[1]
		or (if loadingBay:IsA("Model") or loadingBay:IsA("BasePart") then loadingBay else nil)
		or loadingBay:FindFirstChildWhichIsA("BasePart", true)

	-- Only cached once a sign turned up: while the depot is still streaming in,
	-- a space picked now would stick even after the sign arrives.
	if sign then
		cachedTarget = sign
	end
	cachedSpaces = spaces
	return target, spaces
end

--=============================================================================
-- State
--=============================================================================

-- Straight off the RemoteEvent, the same way DepotGuides and TutorialGuide do.
local activeContract = nil
ReplicatedStorage:WaitForChild("DeliveryUpdate").OnClientEvent:Connect(function(update)
	if type(update) == "table" then
		activeContract = update.Active
	end
end)

-- Riding in a truck that is carrying a job counts as having one: the HUD is
-- showing that job's destination, and a second marker pointing back at the
-- depot would be arguing with it.
local rideAlongContract = nil
ReplicatedStorage:WaitForChild("RideAlongUpdate").OnClientEvent:Connect(function(update)
	if type(update) == "table" then
		rideAlongContract = update.Active
	end
end)

-- Measured from the truck when driving (that is what has to get there), and
-- from the character otherwise.
local function playerPosition()
	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	if carModel and carModel.PrimaryPart then
		return carModel.PrimaryPart.Position
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root and root.Position or nil
end

local function isAtDepot(target, spaces, radius)
	local position = playerPosition()
	if not position then
		return false
	end
	for _, space in spaces do
		if (space.Position - position).Magnitude <= radius then
			return true
		end
	end
	return (target:GetPivot().Position - position).Magnitude <= radius
end

-- A trailer has no bay posts to hand over to, so its marker stays on until the
-- truck is close enough for the hitch prompt to be doing the talking instead.
local AT_TRAILER_STUDS = 45

--=============================================================================
-- A tractor's "depot"
--=============================================================================

-- A tractor does not load at the depot, so pointing it there is the bug this
-- section exists for: players drove a hitch truck into the loading bay and
-- waited for a job list that could never open. What it needs next depends on
-- whether it has its trailer:
--
--   nothing hitched  ->  the player's own trailer, wherever it is standing
--                        (or the stalls, if it is not in the world yet)
--   trailer on       ->  the freight building, where the trailer is loaded
--
-- Returns target, spaces, label - the same shape resolveDepot feeds the loop.
local function resolveRigTarget(carModel)
	if Haulage.Trailer(carModel) then
		local freightBay = Haulage.DepotBay(true)
		if not freightBay then
			return nil, {}, nil
		end
		-- The board over the dock doors, for the reason the depot's SIGN is
		-- the target rather than the building.
		return freightBay:FindFirstChild("FreightBoard") or freightBay, Haulage.SpacesIn(freightBay, true), "FREIGHT"
	end

	local trailer = TrailerHitch.FindOwnedTrailer(workspace:FindFirstChild(TrailerHitch.WorkspaceFolderName), player.UserId)
	if trailer then
		return trailer, {}, "YOUR TRAILER"
	end
	return TrailerHitch.FindStalls(), {}, "TRAILER STALLS"
end

task.spawn(function()
	while true do
		local target, spaces = resolveDepot()
		local label = "DEPOT"
		local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
		local rig = Haulage.IsTractor(carModel)
		if rig then
			target, spaces, label = resolveRigTarget(carModel)
		end

		-- When the player has ARRIVED, and the marker steps aside.
		--
		-- For the depot that is a wide radius: the bay's corner posts take
		-- over there. A rig cannot use the same rule, because the trailer
		-- stalls are inside that radius of the freight building - so the
		-- marker went dark at the very moment the trailer was hooked up, which
		-- is exactly when the player first needs to be told where to take it.
		-- For a rig the marker stays on the building until the trailer is
		-- actually standing in one of its bays (the test that opens the job
		-- list), and on a trailer until the truck is right beside it.
		local arrived = false
		if target then
			if not rig then
				arrived = isAtDepot(target, spaces, AT_DEPOT_STUDS)
			elseif #spaces > 0 then
				arrived = Haulage.FindParkedSpace(carModel, spaces) ~= nil
			else
				arrived = isAtDepot(target, spaces, AT_TRAILER_STUDS)
			end
		end

		local show = target ~= nil
			and activeContract == nil
			and rideAlongContract == nil
			and player:GetAttribute(TUTORIAL_ACTIVE_ATTRIBUTE) ~= true
			and not arrived

		-- SetTarget is idempotent, so calling it every poll is fine.
		if show then
			marker:SetTarget(target, { Label = label })
		else
			marker:SetTarget(nil)
		end
		task.wait(POLL_SECONDS)
	end
end)

-- The server half of "you can't park in, or drive through, somebody else's
-- plot". The half that makes it FEEL like a wall lives on each client
-- (PlotBarriers.client.luau); the reasoning for that split is in
-- Modules/Plots/PlotBarrier.luau and is worth reading before changing
-- anything here.
--
-- What's left for the server is only what a client-side wall can't do:
--
--   1. NORMALISE every CollisionBox, so a box ticked CanCollide in Studio
--      can't reintroduce the old server-vs-client shoving match.
--   2. EJECT anyone already standing or parked in a plot at the instant it
--      gets claimed. A client's wall deliberately refuses to close around
--      somebody, so without this a bystander in the bay would simply hold it
--      open for themselves.
--   3. SWEEP, slowly, for anything DEEPLY inside a plot it has no business
--      being in. An honest client is now stopped at the surface, so this can
--      only fire on somebody who has removed their barrier - it is an
--      exploit backstop, nothing more.
--
-- Note what is deliberately gone: the per-Heartbeat overlap check that ejected
-- anything so much as touching a box. That is what produced the ragdolling
-- and the "car stuck in an invisible wall taking crash damage" - it corrected
-- a client that was still authoritatively simulating its own body, every
-- frame, forever. The sweep below uses BACKSTOP_INSET so it cannot trigger on
-- a body that is merely leaning on the wall, and runs at BACKSTOP_INTERVAL so
-- it cannot turn into a per-frame fight even when it does fire.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlotBarrier = require(ReplicatedStorage.Modules.Plots.PlotBarrier)
local PlotOwnership = require(ReplicatedStorage.Modules.Plots.PlotOwnership)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)

local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")
local VehicleFolder = workspace:WaitForChild("Vehicles")

-- Registering the group and its pairings is a server-side operation, and the
-- resulting registry replicates - which is the only reason a client can put
-- its local wall in this group without touching PhysicsService itself. Done
-- here rather than at require time in the module so the client can share the
-- module without tripping over it.
PlotBarrier.RegisterGroup()

-- [plotModel] = CollisionBox
local boxes = {}

--=============================================================================
-- Ejecting
--=============================================================================

-- How long the server keeps physics authority over a vehicle it just moved,
-- before handing ownership back to whoever is driving. Long enough to cover a
-- client->server->client round trip on a bad connection; short enough that a
-- driver never notices their car went briefly unresponsive.
local OWNERSHIP_HOLD = 0.5

-- [Model] = os.clock() at which physics authority goes back to automatic.
local heldVehicles = {}

-- Takes physics authority away from the driving client for a moment.
--
-- A driven car's assembly is network-owned by that client - it is their
-- RayCastSuspension loop applying every impulse, and their CFrame that wins.
-- So a bare server-side PivotTo on an occupied car is a suggestion, not a
-- move: the owning client's next replicated frame overwrites it. Pulling
-- ownership to the server makes the teleport authoritative, and holding it
-- for a beat afterwards stops a CFrame that was already in flight from
-- putting the car back where it was.
--
-- This is still the right tool for the two remaining callers (a claim-time
-- eject and an exploit sweep, both one-shot events). It was the WRONG tool
-- for a per-frame guard, where it meant taking and returning ownership sixty
-- times a second.
local function holdAuthority(model, referencePart)
	if referencePart.Anchored then
		return -- an anchored part has no network owner to take
	end
	-- SetNetworkOwner throws on a part that isn't in a simulated assembly, and
	-- there is nothing useful to do about it if it does - the teleport below
	-- still runs, it just isn't protected from the client for this one frame.
	pcall(function()
		referencePart:SetNetworkOwner(nil)
	end)
	heldVehicles[model] = os.clock() + OWNERSHIP_HOLD
end

local function releaseExpiredAuthority()
	local now = os.clock()
	for model, releaseAt in heldVehicles do
		local referencePart = model.Parent and model.PrimaryPart
		if not referencePart then
			heldVehicles[model] = nil -- car was despawned while held
		elseif now >= releaseAt then
			heldVehicles[model] = nil
			if not referencePart.Anchored then
				pcall(function()
					referencePart:SetNetworkOwnershipAuto()
				end)
			end
		end
	end
end

-- Moves `model` so `referencePart` lands just outside `box`, keeping the
-- model's current rotation, and kills whatever velocity it had - otherwise a
-- car moving at speed would be put outside only to carry straight back in.
--
-- `takeAuthority` is for vehicles only. A player's character is always
-- network-owned by that player and the server cannot take it, so there is
-- nothing to hold; characters rely on Roblox snapping them to a server-set
-- CFrame, which it does reliably enough for the walking-pace cases this is
-- now limited to.
local function ejectFromBox(model, referencePart, box, takeAuthority)
	if takeAuthority then
		holdAuthority(model, referencePart)
	end
	local newPosition = PlotBarrier.NearestOutsidePoint(box, referencePart.Position)
	local pivot = model:GetPivot()
	model:PivotTo(pivot - pivot.Position + newPosition)
	referencePart.AssemblyLinearVelocity = Vector3.zero
	referencePart.AssemblyAngularVelocity = Vector3.zero
end

--=============================================================================
-- Who is where
--=============================================================================

-- Every (model, referencePart, userId) the plot rules care about: characters,
-- and vehicles standing in for their owner. Built by walking the two folders
-- rather than by a spatial query, because at a handful of players and cars
-- that is cheaper than an overlap test per plot, and it gives the caller the
-- owning user id directly instead of making it climb the tree to find one.
local function candidates()
	local list = {}

	for _, plr in Players:GetPlayers() do
		local character = plr.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		-- A seated player is welded into the car's assembly, so moving the
		-- character would tear them out of the car they are riding in. The car
		-- is the half that carries them, and it is in the list below, so a
		-- seated character is simply not a candidate.
		if root and humanoid and not humanoid.SeatPart then
			table.insert(list, { Model = character, Reference = root, UserId = plr.UserId, IsVehicle = false })
		end
	end

	for _, carModel in VehicleFolder:GetChildren() do
		local chassis = carModel:IsA("Model") and carModel.PrimaryPart
		if chassis then
			table.insert(list, {
				Model = carModel,
				Reference = chassis,
				-- An unowned car (one placed by hand in Studio) has no user id
				-- and so is closed out of every claimed plot. That is the
				-- right default: nobody can be griefed by a car nobody owns.
				UserId = VehicleOwnership.GetOwnerUserId(carModel),
				IsVehicle = true,
			})
		end
	end

	return list
end

--=============================================================================
-- 2. Eject on claim
--=============================================================================

-- Anyone in the bay when the plot changes hands. Uses the box's real extents
-- (margin 0), because at this moment the wall does not exist for them yet -
-- there is no surface to be leaning on, only "in the bay" or "not".
local function clearPlot(plotModel, box)
	local ownerUserId = PlotOwnership.GetOwnerUserId(plotModel)
	if not ownerUserId then
		return
	end
	for _, candidate in candidates() do
		if candidate.UserId ~= ownerUserId and PlotBarrier.IsPositionInside(box, candidate.Reference.Position, 0) then
			ejectFromBox(candidate.Model, candidate.Reference, box, candidate.IsVehicle)
		end
	end
end

--=============================================================================
-- 3. The exploit sweep
--=============================================================================

local sweepAccumulator = 0

local function sweep()
	local list = candidates()
	for plotModel, box in boxes do
		local ownerUserId = PlotOwnership.GetOwnerUserId(plotModel)
		if ownerUserId then
			for _, candidate in list do
				if candidate.UserId ~= ownerUserId
					-- Note the NEGATIVE margin: the box is shrunk before the
					-- test, so only something well past the wall's surface
					-- counts. Nothing an honest client simulates can get here.
					and PlotBarrier.IsPositionInside(box, candidate.Reference.Position, -PlotBarrier.BACKSTOP_INSET)
				then
					ejectFromBox(candidate.Model, candidate.Reference, box, candidate.IsVehicle)
				end
			end
		end
	end
end

--=============================================================================
-- 1. Plot discovery + box normalisation
--=============================================================================

local function trySetupPlot(plotModel)
	local box = plotModel:FindFirstChild(PlotBarrier.BOX_NAME)
	if not (box and box:IsA("BasePart")) then
		return -- PlotManager already warns about a plot missing its box
	end
	PlotBarrier.NormaliseBox(box)
	boxes[plotModel] = box

	-- Fires on claim AND on release; clearPlot is a no-op on release because
	-- an unowned plot has nobody to be closed to.
	plotModel:GetAttributeChangedSignal(PlotOwnership.OWNER_USERID_ATTRIBUTE):Connect(function()
		local ok, err = pcall(clearPlot, plotModel, box)
		if not ok then
			warn("PlotCollisionGuard: failed to clear " .. plotModel:GetFullName() .. ": " .. tostring(err))
		end
	end)
end

for _, plotModel in VehiclePlotsFolder:GetChildren() do
	trySetupPlot(plotModel)
end
VehiclePlotsFolder.ChildAdded:Connect(trySetupPlot)
VehiclePlotsFolder.ChildRemoved:Connect(function(plotModel)
	boxes[plotModel] = nil
end)

RunService.Heartbeat:Connect(function(deltaTime)
	releaseExpiredAuthority()

	sweepAccumulator += deltaTime
	if sweepAccumulator < PlotBarrier.BACKSTOP_INTERVAL then
		return
	end
	sweepAccumulator = 0

	local ok, err = pcall(sweep)
	if not ok then
		warn("PlotCollisionGuard: sweep failed: " .. tostring(err))
	end
end)

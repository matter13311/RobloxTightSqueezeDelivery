-- Builds this client's own solid copy of every plot CollisionBox it is not
-- allowed into, so a claimed plot feels like an anchored wall instead of a
-- teleport correction. The reasoning for doing it here rather than on the
-- server is in Modules/Plots/PlotBarrier.luau - read that first.
--
-- The short version: this client simulates its own character and whatever car
-- it is sitting in, so a part that exists ONLY here is the only thing that can
-- stop either of them at the surface. Nothing created by this script
-- replicates, and it never touches the real CollisionBox, so no other player,
-- and nothing on the server, sees any of it.
--
-- The one thing this script guarantees above everything else: a wall never
-- closes AROUND you. It only ever turns solid while you are clear of it (see
-- ARM_CLEARANCE), and it goes soft again the moment it finds you inside it
-- (see DISARM_INSET). That invariant is what makes "trapped in an invisible
-- box, respawn to escape" unreachable rather than merely unlikely.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlotBarrier = require(ReplicatedStorage.Modules.Plots.PlotBarrier)

local player = Players.LocalPlayer

local VehiclePlotsFolder = workspace:WaitForChild("Spawn"):WaitForChild("VehiclePlots")
local VehicleFolder = workspace:WaitForChild("Vehicles")

-- Local-only, so it is never confused with anything replicated. Parented to
-- workspace because that is where physics happens - a part in Camera or in a
-- ScreenGui renders but does not collide.
local barrierFolder = Instance.new("Folder")
barrierFolder.Name = "LocalPlotBarriers"
barrierFolder.Parent = workspace

-- [plotModel] = { Box = BasePart, Part = BasePart, Solid = boolean, Alpha = number }
-- Alpha is the CURRENT fade, 0 = invisible, 1 = at VISIBLE_TRANSPARENCY, kept
-- separate from the part's Transparency so the fade can be eased per frame.
local barriers = {}

local function createBarrierPart(box)
	local part = Instance.new("Part")
	part.Name = "Barrier"
	part.Anchored = true
	part.CanCollide = false -- armed later, and only once we're clear of it
	part.CanQuery = false -- must never answer a suspension ray or the camera
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = PlotBarrier.COLOR
	part.Transparency = 1
	-- The group is registered by the server and replicated, so assigning it
	-- can only fail in the narrow window before that replication lands.
	-- Falling back to Default is very nearly the same wall - Default already
	-- passes through Cosmetic, and the only real difference is that loose
	-- debris would stack against it - so this is not worth blocking on.
	pcall(function()
		part.CollisionGroup = PlotBarrier.GROUP
	end)
	part.Size = box.Size
	part.CFrame = box.CFrame
	part.Parent = barrierFolder
	return part
end

local function trackPlot(plotModel)
	if barriers[plotModel] then
		return
	end
	local box = plotModel:FindFirstChild(PlotBarrier.BOX_NAME)
	if not (box and box:IsA("BasePart")) then
		return -- PlotManager already warns about a plot missing its box
	end
	barriers[plotModel] = {
		PlotModel = plotModel,
		Box = box,
		Part = createBarrierPart(box),
		Solid = false,
		Alpha = 0,
	}
end

local function untrackPlot(plotModel)
	local entry = barriers[plotModel]
	if entry then
		entry.Part:Destroy()
		barriers[plotModel] = nil
	end
end

for _, plotModel in VehiclePlotsFolder:GetChildren() do
	trackPlot(plotModel)
end
VehiclePlotsFolder.ChildAdded:Connect(trackPlot)
VehiclePlotsFolder.ChildRemoved:Connect(untrackPlot)

-- Everything on this machine whose physics THIS client resolves, and which
-- therefore must be clear of a wall before that wall may turn solid:
--
--   * the character - always simulated by its own client, and the reason the
--     old server-side guard could never do better than a teleport;
--   * the car the player is SITTING IN - driver or passenger. A seated
--     character is welded into the car's assembly, so the two are one body
--     and the car is the half that matters. Driving is the obvious case;
--     riding shotgun matters too, because a passenger arming a wall around
--     the car they are inside would trap the driver, who is a different
--     player entirely and may well be the plot's owner.
--
-- A car the player OWNS but is not in is deliberately absent: it is simulated
-- by the server, so a part that exists only here cannot touch it.
-- Returns the models to test whole (for arming) and the single point that
-- stands in for each of them (for disarming) - see the two callers for why
-- those want different shapes of the same question.
local function localBodies()
	local models, points = {}, {}
	local character = player.Character
	if not character then
		return models, points
	end

	table.insert(models, character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		table.insert(points, root.Position)
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	local carModel = seat and seat:FindFirstAncestorWhichIsA("Model")
	if carModel and carModel.Parent == VehicleFolder then
		table.insert(models, carModel)
		if carModel.PrimaryPart then
			table.insert(points, carModel.PrimaryPart.Position)
		end
	end

	return models, points
end

-- ARMING test: does any part of us reach into the box grown by `margin`?
-- Whole-body and deliberately generous, because arming early is the one thing
-- that can trap somebody. Bounds rather than exact geometry - a character is a
-- handful of boxes and a car a handful of hulls, so the looseness is a stud or
-- so, and it errs towards arming late.
local function anyBodyNear(box, models, margin)
	if #models == 0 then
		return false
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = models
	params.RespectCanCollide = false -- some car parts are non-colliding and still count as "us"

	local grown = Vector3.new(margin, 0, margin) * 2
	local size = box.Size + grown
	local hits = workspace:GetPartBoundsInBox(box.CFrame, size, params)
	return #hits > 0
end

-- DISARMING test: is our CENTRE well inside the box? Centres rather than
-- bodies on purpose. Leaning on the wall puts a shoulder, a bumper or a
-- bounding box's corner fractionally past the surface every single frame -
-- that is what a solver contact IS - and treating that as "trapped" would
-- switch the wall off exactly when it is doing its job, dropping the player
-- into the bay they were being held out of. A centre only ends up inside if
-- something skipped the surface entirely: a respawn, a teleport, or tunnelling
-- through at speed.
local function anyCentreInside(box, points, inset)
	for _, point in points do
		if PlotBarrier.IsPositionInside(box, point, -inset) then
			return true
		end
	end
	return false
end

-- The closest this client's own body gets to a box's side faces, in studs
-- (negative if inside). Drives the fade only.
local function distanceToBox(box)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return math.huge
	end
	return PlotBarrier.HorizontalDistanceToSurface(box, root.Position)
end

local function updateSolidity(entry)
	local closed = PlotBarrier.IsClosedTo(entry.PlotModel, player.UserId)
	if not closed then
		-- Open to us: the wall simply isn't there. Covers an unclaimed plot,
		-- our own plot, and the instant a plot is released.
		entry.Solid = false
		entry.Part.CanCollide = false
		return
	end

	local models, points = localBodies()
	if entry.Solid then
		-- Already solid. The only thing that takes that away is finding
		-- ourselves inside it, which an honest frame can't produce - but a
		-- respawn, a teleport or tunnelling at speed can, and being stuck is
		-- the one outcome this feature must never have.
		if anyCentreInside(entry.Box, points, PlotBarrier.DISARM_INSET) then
			entry.Solid = false
			entry.Part.CanCollide = false
		end
	elseif not anyBodyNear(entry.Box, models, PlotBarrier.ARM_CLEARANCE) then
		-- Clear of it, so the wall can close without catching us. If we're
		-- standing in the bay, it stays open until we walk out - which is
		-- also what gives someone caught inside at claim time a way out,
		-- alongside the server's eject.
		entry.Solid = true
		entry.Part.CanCollide = true
	end
end

local function updateAppearance(entry, deltaTime)
	local target = 0
	if entry.Solid then
		local distance = distanceToBox(entry.Box)
		if distance < PlotBarrier.VISIBLE_DISTANCE then
			-- Full strength at the surface, gone by VISIBLE_DISTANCE away.
			target = math.clamp(1 - distance / PlotBarrier.VISIBLE_DISTANCE, 0, 1)
		end
	end

	local step = PlotBarrier.FADE_SPEED * deltaTime
	entry.Alpha += math.clamp(target - entry.Alpha, -step, step)
	entry.Part.Transparency = 1 - entry.Alpha * (1 - PlotBarrier.VISIBLE_TRANSPARENCY)
end

RunService.Heartbeat:Connect(function(deltaTime)
	for _, entry in barriers do
		-- Plots don't move, but a builder nudging one in Studio during a
		-- playtest shouldn't leave a wall behind where the bay used to be.
		if entry.Part.CFrame ~= entry.Box.CFrame or entry.Part.Size ~= entry.Box.Size then
			entry.Part.CFrame = entry.Box.CFrame
			entry.Part.Size = entry.Box.Size
		end
		updateSolidity(entry)
		updateAppearance(entry, deltaTime)
	end
end)

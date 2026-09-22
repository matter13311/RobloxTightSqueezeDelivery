-- The garage "stage": a live, local-only copy of a vehicle parked in the
-- player's own bay, with the camera flown over to look at it. Replaces the old
-- terminal's thumbnail photos - the car on screen IS the car, so a repaint
-- shows up on it immediately and a new vehicle needs no image rendering.
--
-- CLIENT-ONLY ON PURPOSE. Clicking through the vehicle list builds and throws
-- away cars as fast as the player can click. Done on the server that would be
-- a clone and a destroy replicated to every player in the game for each click;
-- here it is nothing anyone else ever sees. Other players see only the
-- "In Garage" marker over this player's head (GarageIndicators.client.luau),
-- and the real, repainted car once it is spawned.
--
-- WHAT THIS DOES WHILE OPEN:
--   * clones ReplicatedStorage.VehiclePreviews.<Template> (published by
--     VehiclePreviews.server.luau) into a local folder in workspace, parked on
--     the plot's VehicleSpawn at the height the real car settles to;
--   * hides the player's own real car if it is parked in the bay (the preview
--     stands exactly where it is), and hides the player's own character, which
--     is standing at the terminal right in the shot;
--   * takes the camera (Scriptable) and orbits it around the preview: drag to
--     turn, scroll/pinch to zoom, pulled in short of walls so it never ends up
--     looking at the back of a bay divider;
--   * disables character movement, so WASD cannot walk the (hidden) player
--     away from the terminal mid-purchase.
-- Close puts every one of those back.
--
-- Previews are cached per template once built, so switching back to a car
-- already looked at is a reparent, not a clone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local VehicleCatalog = require(ReplicatedStorage.Modules.Vehicles.VehicleCatalog)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehiclePaint = require(ReplicatedStorage.Modules.Vehicles.VehiclePaint)

local player = Players.LocalPlayer

local GarageStage = {}

--============================================================================
-- Tuning
--============================================================================

-- Front-left three-quarter view, the classic "car on a showroom floor" angle.
-- Yaw is measured from straight ahead of the car, positive to the car's LEFT.
local DEFAULT_YAW = math.rad(32)
local DEFAULT_PITCH = math.rad(13)
local MIN_PITCH = math.rad(2)
local MAX_PITCH = math.rad(55)

-- Narrower than Roblox's default 70: less fish-eye on a big truck up close,
-- which reads as "photo" rather than "game camera".
local FIELD_OF_VIEW = 50

-- Multiples of the distance that just fits the whole car in frame.
local DEFAULT_ZOOM = 1
local MIN_ZOOM = 0.55
local MAX_ZOOM = 1.5

local DRAG_YAW_PER_PIXEL = 0.008
local DRAG_PITCH_PER_PIXEL = 0.005
local WHEEL_ZOOM_STEP = 0.1

-- How quickly the camera catches up with where it is aimed. Also what makes
-- the fly-in from the player's own view smooth, since opening just starts the
-- camera where it already was.
local CAMERA_SHARPNESS = 10

-- Kept this far off any wall the pull-in ray hits.
local CAMERA_WALL_MARGIN = 0.8
local CAMERA_PROBE_RADIUS = 0.6

-- How near the bay a real car has to be for this to treat it as "parked
-- where the preview is" and hide it.
local HIDE_REAL_CAR_RADIUS = 40

local RENDER_STEP = "GarageStageCamera"

--============================================================================
-- State
--============================================================================

local previewFolder = nil -- local-only Folder in workspace while open
local previewCache = {} -- [templateName] = { Model, RestOffset }
local current = nil -- { VehicleId, Model, Focus, Radius }
local pendingVehicleId = nil -- the most recent ShowVehicle request

local isOpen = false
local plotModel = nil
local spawnCFrame = CFrame.new()

local yaw, pitch, zoom = DEFAULT_YAW, DEFAULT_PITCH, DEFAULT_ZOOM
-- Set by the first drag. Until then each car opens on its own clearest angle
-- (pickOpeningYaw); after it, switching cars keeps the angle the player chose.
local userOrbited = false
local cameraCFrame = nil
local savedCamera = nil -- { CameraType, FieldOfView }

local hiddenParts = {} -- [BasePart/Decal] = true, restored on close
local controls = nil
local connections = {}

--============================================================================
-- Helpers
--============================================================================

-- Roblox's PlayerModule, if this place has one. Looked up without waiting:
-- this game's PlayerScripts does not always carry it, and blocking on it here
-- would stall opening the garage forever.
local function getControls()
	if controls == nil then
		local playerScripts = player:FindFirstChild("PlayerScripts")
		local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
		local ok, result = false, nil
		if playerModule then
			ok, result = pcall(function()
				return require(playerModule):GetControls()
			end)
		end
		controls = if ok and result then result else false
	end
	return controls or nil
end

-- Movement lock. The PlayerModule's controls when there are some; otherwise
-- the Humanoid's own speed and jump, which stops keyboard, gamepad and touch
-- alike.
local savedMovement = nil

local function lockMovement()
	local playerControls = getControls()
	if playerControls then
		playerControls:Disable()
		return
	end
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		savedMovement = {
			Humanoid = humanoid,
			WalkSpeed = humanoid.WalkSpeed,
			JumpPower = humanoid.JumpPower,
			JumpHeight = humanoid.JumpHeight,
		}
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
	end
end

local function unlockMovement()
	local playerControls = getControls()
	if playerControls then
		playerControls:Enable()
	end
	if savedMovement and savedMovement.Humanoid.Parent then
		savedMovement.Humanoid.WalkSpeed = savedMovement.WalkSpeed
		savedMovement.Humanoid.JumpPower = savedMovement.JumpPower
		savedMovement.Humanoid.JumpHeight = savedMovement.JumpHeight
	end
	savedMovement = nil
end

local function getSpawnCFrame(plot)
	local marker = plot:FindFirstChild("VehicleSpawn")
	if marker and marker:IsA("BasePart") then
		return marker.CFrame
	elseif marker and marker:IsA("Attachment") then
		return marker.WorldCFrame
	end
	local box = plot:FindFirstChild("CollisionBox")
	return if box then box.CFrame else plot:GetPivot()
end

-- Everything the camera ray and the floor ray should look straight through:
-- the preview itself, every character, every real car, and this plot's own
-- CollisionBox (an invisible volume the whole bay sits inside).
local function makeRayParams()
	local ignore = { workspace:FindFirstChild("Vehicles") }
	if previewFolder then
		table.insert(ignore, previewFolder)
	end
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(ignore, other.Character)
		end
	end
	local box = plotModel and plotModel:FindFirstChild("CollisionBox")
	if box then
		table.insert(ignore, box)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	return params
end

--============================================================================
-- Building a preview
--============================================================================

local function massOf(model)
	local total = 0
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and not part.Massless then
			total += part:GetMass()
		end
	end
	return total
end

-- Rebuilds the wheels the way Raycast.server.luau does for a real car (they
-- are not part of the templates - they are cloned from ReplicatedStorage.Wheels
-- at spawn), but posed at the suspension's resting length instead of animated.
-- Returns how far below its wheel-mount attachments the car's wheels sit, which
-- is what placing the car on the floor needs.
local function addWheels(model, chassis)
	local wheelsFolder = ReplicatedStorage:FindFirstChild("Wheels")
	if not wheelsFolder then
		return 0
	end
	local config = VehiclePhysics.GetConfig(chassis)
	local attachments = VehiclePhysics.GetWheelAttachments(chassis)
	local defaultWheel = wheelsFolder:FindFirstChild("StarterVehicleWheel")

	local wheelFolder = Instance.new("Folder")
	wheelFolder.Name = "Wheels"
	wheelFolder.Parent = model

	local cosmeticMass = 0
	local built = {}
	for _, wheel in attachments.VisualWheels do
		local modelName = VehiclePhysics.GetVisualWheelModelName(config, wheel)
		local source = (modelName and wheelsFolder:FindFirstChild(modelName)) or defaultWheel
		if source then
			local clone = source:Clone()
			clone.Name = wheel.Name
			local parts = if clone:IsA("Model") then clone:GetDescendants() else { clone }
			for _, part in parts do
				if part:IsA("BasePart") then
					if wheel.IsCosmetic and not part.Massless then
						cosmeticMass += part:GetMass()
					end
					part.Anchored = true
					part.CanCollide = false
					part.CanTouch = false
					part.CanQuery = false
				elseif part:IsA("LuaSourceContainer") or part:IsA("JointInstance") or part:IsA("WeldConstraint") then
					part:Destroy()
				end
			end
			clone.Parent = wheelFolder
			table.insert(built, { Instance = clone, Wheel = wheel })
		end
	end

	-- The suspension's resting length, from the same formula the physics step
	-- settles to (VehiclePhysics.Step's restCompression): each corner carries a
	-- quarter of the car's weight against the spring. The car's mass is summed
	-- by hand rather than read off AssemblyMass because nothing here is welded
	-- into an assembly.
	-- Cosmetic wheels are Massless on a real car (see Raycast.server), so they
	-- come back out of the total here.
	local mass = massOf(model) - cosmeticMass
	local springRate = config.Stiffness * 60
	local restCompression = math.clamp((mass / 4) * workspace.Gravity / springRate, 0, config.SuspensionMaxLength)
	local restLength = config.SuspensionMaxLength - restCompression

	local maxDrop = 0
	for _, entry in built do
		local attachment = entry.Wheel.Attachment
		local offset = CFrame.new(attachment.Position - Vector3.new(0, restLength, 0))
		if attachment.Position.X > 0 then
			offset *= CFrame.Angles(0, math.rad(180), 0)
		end
		local target = chassis.CFrame * offset
		local instance = entry.Instance
		if instance:IsA("Model") then
			local primary = VehiclePhysics.GetWheelPrimaryPart(instance)
			instance:PivotTo(target * primary.CFrame:ToObjectSpace(instance:GetPivot()))
		else
			instance.CFrame = target
		end
		if not entry.Wheel.IsCosmetic then
			local radius = VehiclePhysics.GetVisualWheelRadius(config, entry.Wheel)
			maxDrop = math.max(maxDrop, restLength + radius - attachment.Position.Y)
		end
	end
	return maxDrop
end

-- Returns the cache entry, building it on first use. RestOffset is the
-- distance from the model's pivot down to the bottom of its tyres, in the
-- pivot's own frame, so parking it is one subtraction.
local function getPreview(templateName)
	local cached = previewCache[templateName]
	if cached then
		return cached
	end
	local folder = ReplicatedStorage:WaitForChild("VehiclePreviews", 10)
	local source = folder and folder:WaitForChild(templateName, 5)
	if not source then
		warn("GarageStage: no preview model for " .. templateName .. " in ReplicatedStorage.VehiclePreviews")
		return nil
	end

	local model = source:Clone()
	local chassis = model.PrimaryPart
	local wheelDrop = 0
	if chassis then
		local ok, result = pcall(addWheels, model, chassis)
		if ok then
			wheelDrop = result
		else
			warn("GarageStage: could not build wheels for " .. templateName .. ": " .. tostring(result))
		end
	end

	-- Chassis-relative height of the tyre bottoms, re-expressed relative to
	-- the model's pivot (which is what PivotTo places).
	local pivot = model:GetPivot()
	local restOffset = 0
	if chassis then
		local tyreBottom = chassis.CFrame * Vector3.new(0, -wheelDrop, 0)
		restOffset = pivot:PointToObjectSpace(tyreBottom).Y
	end

	cached = { Model = model, RestOffset = restOffset }
	previewCache[templateName] = cached
	return cached
end

--============================================================================
-- Hiding what is in the way
--============================================================================

local function hideInstance(instance)
	if instance:IsA("BasePart") or instance:IsA("Decal") then
		if instance.LocalTransparencyModifier < 1 then
			hiddenParts[instance] = true
			instance.LocalTransparencyModifier = 1
		end
	end
end

local function hideRealCar()
	local vehicles = workspace:FindFirstChild("Vehicles")
	if not vehicles then
		return
	end
	for _, car in vehicles:GetChildren() do
		if car:IsA("Model") and VehicleOwnership.GetOwnerUserId(car) == player.UserId then
			local ok, pivot = pcall(car.GetPivot, car)
			if ok and (pivot.Position - spawnCFrame.Position).Magnitude < HIDE_REAL_CAR_RADIUS then
				for _, descendant in car:GetDescendants() do
					hideInstance(descendant)
				end
			end
		end
	end
end

-- Every frame, not once: in first person Roblox's camera scripts rewrite the
-- character's LocalTransparencyModifier on their own schedule.
local function hideCharacter()
	local character = player.Character
	if not character then
		return
	end
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") or descendant:IsA("Decal") then
			descendant.LocalTransparencyModifier = 1
		end
	end
end

local function restoreHidden()
	for instance in hiddenParts do
		if instance.Parent then
			instance.LocalTransparencyModifier = 0
		end
	end
	table.clear(hiddenParts)
	local character = player.Character
	if character then
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") or descendant:IsA("Decal") then
				descendant.LocalTransparencyModifier = 0
			end
		end
	end
end

--============================================================================
-- Camera
--============================================================================

local function fitDistance()
	return current.Radius / math.tan(math.rad(FIELD_OF_VIEW / 2)) * 0.95
end

local function orbitDirection(atYaw, atPitch)
	local localDirection = Vector3.new(-math.sin(atYaw) * math.cos(atPitch), math.sin(atPitch), -math.cos(atYaw) * math.cos(atPitch))
	return spawnCFrame:VectorToWorldSpace(localDirection)
end

-- How far the camera can actually get along a direction before something is
-- in the way. A spherecast rather than a ray, so the lens itself stays clear
-- of the wall instead of just its centre.
local function clearDistance(direction, wanted, params)
	local hit = workspace:Spherecast(current.Focus, CAMERA_PROBE_RADIUS, direction * wanted, params)
	if hit then
		return math.max(hit.Distance - CAMERA_WALL_MARGIN, current.Radius * 0.35)
	end
	return wanted
end

-- The opening angle for a car. Front-left three-quarter is the preference,
-- but a long truck needs the camera far enough out that a bay pillar or the
-- sign over the bay mouth can be in the way, so this walks round the front of
-- the car and takes the first angle with a clear line - or, failing that, the
-- clearest one. Only the opening angle: once the player drags, it is theirs.
local CANDIDATE_YAWS = { 32, 22, 12, 0, -12, -22, -32, 45, -45 }

local function pickOpeningYaw()
	local params = makeRayParams()
	local wanted = fitDistance() * DEFAULT_ZOOM
	local bestYaw, bestClear = DEFAULT_YAW, -1
	for _, degrees in CANDIDATE_YAWS do
		local candidate = math.rad(degrees)
		local clear = clearDistance(orbitDirection(candidate, DEFAULT_PITCH), wanted, params)
		if clear >= wanted * 0.92 then
			return candidate
		end
		if clear > bestClear then
			bestYaw, bestClear = candidate, clear
		end
	end
	return bestYaw
end

-- Returns the camera CFrame and the field of view to use with it.
local function aimedCamera()
	if not current then
		return nil, FIELD_OF_VIEW
	end
	local focus = current.Focus
	local direction = orbitDirection(yaw, pitch)
	local wanted = fitDistance() * zoom
	local distance = clearDistance(direction, wanted, makeRayParams())

	-- Pulled in by a wall: widen the lens by the same ratio, so the car keeps
	-- the framing it would have had from where the camera wanted to be,
	-- rather than suddenly filling the screen. Capped - past ~85 degrees it
	-- stops looking like a camera.
	local fov = FIELD_OF_VIEW
	if distance < wanted then
		local halfTan = math.tan(math.rad(FIELD_OF_VIEW / 2)) * wanted / distance
		fov = math.min(math.deg(2 * math.atan(halfTan)), 85)
	end

	return CFrame.lookAt(focus + direction * distance, focus), fov
end

local function onRenderStep(deltaTime)
	local camera = workspace.CurrentCamera
	if not camera or not current then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	local target, fov = aimedCamera()
	if target then
		local alpha = 1 - math.exp(-CAMERA_SHARPNESS * deltaTime)
		cameraCFrame = if cameraCFrame then cameraCFrame:Lerp(target, alpha) else target
		camera.CFrame = cameraCFrame
		camera.Focus = CFrame.new(current.Focus)
		camera.FieldOfView += (fov - camera.FieldOfView) * alpha
	end
	hideCharacter()
	-- Same fix as PlotTerminal's old mouse step: in first person the camera
	-- controller re-locks the mouse every frame, which would pin the cursor
	-- to the middle of the car where nothing can be clicked.
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

--============================================================================
-- Input: drag to orbit, wheel/pinch to zoom
--============================================================================

local dragInput = nil
local dragLast = nil
local pinchStartZoom = nil

local function connectInput()
	table.insert(connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed or dragInput then
			return
		end
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.MouseButton2 or kind == Enum.UserInputType.Touch then
			dragInput = input
			dragLast = input.Position
		end
	end))

	table.insert(connections, UserInputService.InputChanged:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			if not processed then
				zoom = math.clamp(zoom * (1 - input.Position.Z * WHEEL_ZOOM_STEP), MIN_ZOOM, MAX_ZOOM)
			end
			return
		end
		if not dragInput or pinchStartZoom then
			return
		end
		local isMouseDrag = dragInput.UserInputType ~= Enum.UserInputType.Touch
			and input.UserInputType == Enum.UserInputType.MouseMovement
		if isMouseDrag or input == dragInput then
			local delta = input.Position - dragLast
			dragLast = input.Position
			if delta.Magnitude > 0 then
				userOrbited = true
			end
			yaw -= delta.X * DRAG_YAW_PER_PIXEL
			pitch = math.clamp(pitch + delta.Y * DRAG_PITCH_PER_PIXEL, MIN_PITCH, MAX_PITCH)
		end
	end))

	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if input == dragInput or (dragInput and dragInput.UserInputType == input.UserInputType and input.UserInputType ~= Enum.UserInputType.Touch) then
			dragInput = nil
			dragLast = nil
		end
	end))

	table.insert(connections, UserInputService.TouchPinch:Connect(function(_, scale, _, state, processed)
		if processed and not pinchStartZoom then
			return
		end
		if state == Enum.UserInputState.Begin then
			pinchStartZoom = zoom
		elseif state == Enum.UserInputState.Change and pinchStartZoom then
			zoom = math.clamp(pinchStartZoom / math.max(scale, 0.01), MIN_ZOOM, MAX_ZOOM)
		else
			pinchStartZoom = nil
		end
	end))
end

--============================================================================
-- Public
--============================================================================

function GarageStage.IsOpen()
	return isOpen
end

function GarageStage.Open(plot)
	if isOpen then
		return
	end
	isOpen = true
	plotModel = plot
	spawnCFrame = getSpawnCFrame(plot)
	yaw, pitch, zoom = DEFAULT_YAW, DEFAULT_PITCH, DEFAULT_ZOOM
	userOrbited = false

	previewFolder = Instance.new("Folder")
	previewFolder.Name = "GaragePreview"
	previewFolder.Parent = workspace

	local camera = workspace.CurrentCamera
	savedCamera = { CameraType = camera.CameraType, FieldOfView = camera.FieldOfView }
	camera.FieldOfView = FIELD_OF_VIEW
	cameraCFrame = camera.CFrame

	hideRealCar()
	lockMovement()

	connectInput()
	RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + 1, onRenderStep)
end

function GarageStage.Close()
	if not isOpen then
		return
	end
	isOpen = false
	RunService:UnbindFromRenderStep(RENDER_STEP)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	dragInput, dragLast, pinchStartZoom = nil, nil, nil

	pendingVehicleId = nil
	if current then
		current.Model.Parent = nil
		current = nil
	end
	if previewFolder then
		previewFolder:Destroy()
		previewFolder = nil
	end

	restoreHidden()
	unlockMovement()

	local camera = workspace.CurrentCamera
	if camera then
		camera.FieldOfView = savedCamera and savedCamera.FieldOfView or 70
		camera.CameraType = Enum.CameraType.Custom
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
	savedCamera = nil
	cameraCFrame = nil
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

-- Puts a vehicle on the stage wearing `paintValue` and `materialValue` (either
-- nil = stock - see VehiclePaint). Keeps the camera angle the player has
-- dragged to, so flicking through the list compares cars from the same
-- viewpoint.
function GarageStage.ShowVehicle(vehicleId, paintValue, materialValue)
	if not isOpen then
		return
	end
	local def = VehicleCatalog.Get(vehicleId)
	if not def then
		return
	end
	pendingVehicleId = vehicleId
	if current and current.VehicleId == vehicleId then
		GarageStage.SetBody(paintValue, materialValue)
		return
	end

	local entry = getPreview(def.TemplateName)
	-- Getting the preview can yield (WaitForChild) the first time; the garage
	-- may have been closed, or another car picked, in the meantime - and the
	-- newest pick is the one that wins, however the loads finish.
	if not entry or not isOpen or pendingVehicleId ~= vehicleId then
		return
	end
	if current then
		current.Model.Parent = nil
		current = nil
	end

	local model = entry.Model
	model:PivotTo(spawnCFrame)

	-- Sit it on the floor: find the floor under the spawn point and lift the
	-- pivot so the tyre bottoms touch it. The spawn marker is a flat part on a
	-- flat floor, so one ray from its centre is enough.
	local params = makeRayParams()
	local origin = spawnCFrame.Position + Vector3.new(0, 4, 0)
	local floor = workspace:Raycast(origin, Vector3.new(0, -30, 0), params)
	local floorY = if floor then floor.Position.Y else spawnCFrame.Position.Y
	local pivot = spawnCFrame - spawnCFrame.Position + Vector3.new(spawnCFrame.Position.X, floorY - entry.RestOffset, spawnCFrame.Position.Z)
	model:PivotTo(pivot)

	VehiclePaint.Apply(model, paintValue, materialValue)
	model.Parent = previewFolder

	local boxCFrame, boxSize = model:GetBoundingBox()
	current = {
		VehicleId = vehicleId,
		Model = model,
		-- A touch below the box centre: a car's box includes its roof, and
		-- framing on the true centre leaves it floating in the top half.
		Focus = boxCFrame.Position - Vector3.new(0, boxSize.Y * 0.08, 0),
		Radius = boxSize.Magnitude / 2,
	}
	if not userOrbited then
		yaw = pickOpeningYaw()
	end
end

-- Both halves of the look at once, because the terminal always knows both and
-- a car is never half-previewing.
function GarageStage.SetBody(paintValue, materialValue)
	if current then
		VehiclePaint.Apply(current.Model, paintValue, materialValue)
	end
end

function GarageStage.GetVehicleId()
	return current and current.VehicleId
end

return GarageStage

-- Shows a single custom "Enter Vehicle" prompt (see CustomPrompt.luau) per
-- car instead of a real ProximityPrompt - see CustomPrompt.luau's own header
-- for why. One prompt covering both doors, not one each: with two doors
-- close enough together that being in range of one usually means being in
-- range of the other too, a prompt per door meant both could show at once,
-- and (since each independently bound the same F key) only one of them could
-- ever actually receive the keypress. This script only decides WHEN to show
-- the prompt and fires EnterVehicle when it's triggered - which door that
-- resolves to is VehicleDoors.server.luau's call, based on which one the
-- player is actually standing closer to at that moment.
--
-- Range is judged from the car's Exit# attachments (see VehicleExits). Doors
-- no longer swing and are just welded panels in the Body folder, so there is
-- no door rig to ask - and a panel can be knocked clean off in a crash, which
-- would take the way in with it. The exit attachments are on the Chassis and
-- describe the same thing more reliably: ground level, just outside a door.
--
-- Nothing here is a security boundary. Whether a player may actually enter is
-- decided by the server (VehicleDoors.server.luau) using the same
-- VehicleOwnership rule this script asks - so what's on screen matches what
-- would happen, but a client that lies about it still gets refused.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CustomPrompt = require(ReplicatedStorage.Modules.UI.CustomPrompt)
local VehicleExits = require(ReplicatedStorage.Modules.Vehicles.VehicleExits)
local VehicleOwnership = require(ReplicatedStorage.Modules.Vehicles.VehicleOwnership)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)

local player = Players.LocalPlayer
local VehicleFolder = workspace.Vehicles

-- Measured to the nearest EXIT, not to the seat at the car's centre. Measuring
-- from the centre meant the radius had to cover half the length of the truck
-- before it reached a door at all, so the prompt appeared while the player was
-- still well clear of the car - and appeared just as readily standing at the
-- back of the tray, nowhere near a way in. Door-relative, this is the real
-- "close enough to reach the handle" distance, so it can be small.
--
-- Exit attachments sit on the ground just outside the door, whereas the old
-- door attachments were up on the interior frame - so this is now measured to
-- a point a little lower and further out. If the prompt starts appearing a
-- touch too eagerly or too late, this is the number to move.
local MAX_PROMPT_DISTANCE = 6

local enterVehicleEvent = ReplicatedStorage:WaitForChild("EnterVehicle")

-- Passengers ride with a different key than the driver (G, not F) so standing
-- near both a DriverSeat and a PassengerSeat at once never leaves two prompts
-- contending for the same keypress - see CustomPrompt's winner-by-key pass,
-- which already breaks ties by distance but only when the keys differ do both
-- prompts get to stay on screen at once.
local PASSENGER_KEY = Enum.KeyCode.G

-- [carModel] = { [seat] = CustomPrompt }
local carPrompts = {}

local function setupCarPrompts(carModel)
	local driverSeat = VehicleSeats.GetDriverSeat(carModel)
	local exits = VehicleExits.GetExits(carModel)
	if not driverSeat or #exits == 0 then
		return false -- not fully set up yet - the retry below will catch it once it is
	end

	-- Keyed per seat, not per car: a duplicate prompt would parent a second
	-- billboard to the same seat that nothing holds a reference to - so
	-- tearing the car down would leave it behind, permanently visible, with
	-- no way to reach it. Per-seat keying also means a passenger seat added
	-- after the driver seat's first pass still gets picked up here.
	local seatPrompts = carPrompts[carModel]
	if not seatPrompts then
		seatPrompts = {}
		carPrompts[carModel] = seatPrompts
	end

	for _, seat in VehicleSeats.GetAllSeats(carModel) do
		if not seatPrompts[seat] then
			local isDriverSeat = seat == driverSeat

			local prompt = CustomPrompt.new(seat, {
				Text = if isDriverSeat then "Enter Vehicle" else "Ride Along",
				KeyCode = if isDriverSeat then Enum.KeyCode.F else PASSENGER_KEY,
				MaxActivationDistance = MAX_PROMPT_DISTANCE,
				-- DriverSeat: the billboard floats over the seat (centred
				-- over the cab, so it reads the same from either side), but
				-- range is judged from the door openings - every exit, so a
				-- car with more than two ways in offers the prompt at all of
				-- them. There's only ever one DriverSeat, so nothing else
				-- competes with it for the F key.
				--
				-- Passenger seats measure to themselves instead. They all
				-- share the G key, and CustomPrompt's Heartbeat loop shows
				-- only the single nearest in-range prompt per key - if every
				-- passenger seat on a car measured to the same shared `exits`
				-- list, they'd all compute the identical distance and tie,
				-- and a tie never displaces the current winner, so whichever
				-- seat happened to be set up first would always win no matter
				-- where you were actually standing. Measuring to the seat
				-- itself is what actually varies seat-to-seat.
				DistanceFrom = if isDriverSeat then exits else { seat },
				-- Re-asked every frame rather than pushed from event handlers.
				-- The previous version drove this off Seat.Occupant changing
				-- and the local Humanoid.Seated firing, and a prompt that
				-- outlives EITHER of those - a car that finished replicating
				-- with someone already in it, a Seated event during a
				-- respawn, a car whose seat reference went stale - had no way
				-- back to hidden and simply stayed on screen. Asking the live
				-- values every frame has no such failure mode.
				--
				-- CustomPrompt separately hides any prompt while the local
				-- player is seated in anything at all, so that case is
				-- covered even if this car's own Occupant hasn't replicated
				-- yet.
				--
				-- Only the DriverSeat is ownership-gated. Passenger seats are
				-- open to anyone - riding along doesn't grant control of the
				-- car, so there's nothing for ownership to protect there.
				ShouldShow = function()
					if seat.Occupant ~= nil then
						return false
					end
					return not isDriverSeat or VehicleOwnership.CanEnter(player, carModel)
				end,
			})
			prompt.Triggered:Connect(function()
				enterVehicleEvent:FireServer(carModel, seat)
			end)
			seatPrompts[seat] = prompt
		end
	end
	return true
end

-- A freshly-added car (or one that just hasn't finished replicating to this
-- client yet at game start - Workspace isn't guaranteed fully replicated the
-- instant PlayerScripts starts running) may not have its Frame/Doors in
-- place for a bit. Retries every second, for up to a minute, rather than
-- giving up after a single attempt.
local SETUP_RETRY_INTERVAL = 1
local SETUP_RETRY_TIMEOUT = 60

local function trySetupCarPrompts(carModel)
	if setupCarPrompts(carModel) then
		return
	end
	task.spawn(function()
		local elapsed = 0
		while carModel.Parent == VehicleFolder and not carPrompts[carModel] and elapsed < SETUP_RETRY_TIMEOUT do
			task.wait(SETUP_RETRY_INTERVAL)
			elapsed += SETUP_RETRY_INTERVAL
			if carModel.Parent == VehicleFolder and not carPrompts[carModel] and setupCarPrompts(carModel) then
				return
			end
		end
		if carModel.Parent == VehicleFolder and not carPrompts[carModel] then
			warn("VehicleDoorPrompts: gave up waiting for " .. carModel:GetFullName() .. " to have Exit# attachments on its Chassis and a DriverSeat")
		end
	end)
end

local function teardownCarPrompts(carModel)
	local seatPrompts = carPrompts[carModel]
	if seatPrompts then
		for _, prompt in seatPrompts do
			prompt:Destroy()
		end
		carPrompts[carModel] = nil
	end
end

for _, carModel in VehicleFolder:GetChildren() do
	trySetupCarPrompts(carModel)
end
VehicleFolder.ChildAdded:Connect(trySetupCarPrompts)
VehicleFolder.ChildRemoved:Connect(teardownCarPrompts)

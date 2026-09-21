-- PROTOTYPE: articulated vehicles, driving client half.
--
-- The driver's client already simulates the truck it owns. A coupled trailer
-- is a second body on the same mechanism, owned by the same client, and so it
-- has to be simulated in the same frame by the same loop - otherwise the
-- trailer is a rigid body joined to a truck with nothing holding it up, which
-- reads as the back of the rig sitting on the floor and dragging.
--
-- Deliberately a tiny module rather than lines inside RayCastSuspension's
-- drive loop: that loop is already long and carefully ordered, and everything
-- here is bookkeeping around ONE call to the same VehiclePhysics.Step the
-- truck uses. That single call is the entire physics of a trailer - see
-- Configs/TestTrailer.luau for why "a trailer is a car with no engine" is
-- literal here.
--
-- Owns nothing. Coupling and uncoupling are the server's (TrailerHitch.server),
-- and this only ever reacts to the link the server publishes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TrailerHitch = require(ReplicatedStorage.Modules.Vehicles.TrailerHitch)
local VehiclePhysics = require(ReplicatedStorage.Modules.Vehicles.VehiclePhysics)

local TrailerDrive = {}
TrailerDrive.__index = TrailerDrive

function TrailerDrive.new(carModel)
	return setmetatable({
		CarModel = carModel,
		-- All nil until something is actually coupled. Rebuilt wholesale by
		-- attach() rather than patched, so a second coupling in one drive
		-- session cannot inherit the first trailer's suspension state.
		Trailer = nil,
		Attachments = nil,
		Config = nil,
		State = nil,
	}, TrailerDrive)
end

function TrailerDrive:_detach()
	if not self.Trailer then
		return
	end
	VehiclePhysics.ClearExtraRayIgnore(self.CarModel)
	VehiclePhysics.ClearExtraRayIgnore(self.Trailer)
	self.Trailer = nil
	self.Attachments = nil
	self.Config = nil
	self.State = nil
end

function TrailerDrive:_attach(trailerModel)
	local chassis = trailerModel.PrimaryPart
	if not chassis then
		return false
	end
	-- pcall because GetWheelAttachments asserts, and a trailer whose setup has
	-- not replicated to this client yet is a normal few frames rather than an
	-- error. Returning false just means "try again next frame".
	local ok, attachments = pcall(VehiclePhysics.GetWheelAttachments, chassis)
	if not ok then
		return false
	end

	self.Trailer = trailerModel
	self.Attachments = attachments
	self.Config = VehiclePhysics.GetConfig(chassis)
	self.State = VehiclePhysics.NewState()

	-- Each body's suspension rays must ignore the other's geometry. The server
	-- sets its own copy for its settle loop; this registry is per-context, so
	-- the client has to set its own or the tractor's rear struts will read the
	-- trailer's nose as road and hold the truck up on it.
	VehiclePhysics.SetExtraRayIgnore(self.CarModel, { trailerModel })
	VehiclePhysics.SetExtraRayIgnore(trailerModel, { self.CarModel })
	return true
end

-- Called once per drive frame, right after the truck's own Step.
--
-- Order between the two does not matter: both are accumulating impulses onto
-- their own assemblies within one Heartbeat, and the constraint solver runs
-- after both regardless. What DOES matter is that they happen in the same
-- frame with the same delta, which is the whole reason this is here rather
-- than on its own RunService connection.
function TrailerDrive:Step(delta)
	local linked = TrailerHitch.GetHitchedTrailer(self.CarModel)

	-- Coupled or uncoupled mid-drive. Re-read every frame rather than cached
	-- at session start, because the player can hitch and drop trailers all day
	-- without ever leaving the seat.
	if linked ~= self.Trailer then
		self:_detach()
		if linked and not self:_attach(linked) then
			return -- not set up on this client yet; retry next frame
		end
	end

	if not self.Trailer then
		return
	end
	local chassis = self.Trailer.PrimaryPart
	-- An anchored trailer is a parked one (the server anchors it whenever the
	-- truck is parked - see followTractorState). Stepping it would be applying
	-- impulses to a body that cannot move, which achieves nothing and wastes
	-- four raycasts a frame.
	if not chassis or chassis.Anchored then
		return
	end

	-- No throttle, no steering, no brake pedal: everything that makes this a
	-- trailer rather than a second car is the absence of driver input, plus
	-- Torque = 0 in its config. What it DOES get is suspension, lateral grip
	-- and the low-speed stabiliser, which is the whole of trailer physics.
	VehiclePhysics.Step(self.Trailer, self.Attachments, self.Config, self.State, delta, {
		Throttle = 0,
		Steer = 0,
		Brake = 0,
		Handbrake = false,
	})
end

function TrailerDrive:Destroy()
	self:_detach()
end

return TrailerDrive

--!strict
-- One raycast-suspension "corner" for a single wheel. The wheel part is never
-- welded to the chassis: every Heartbeat we raycast down from a mount point
-- on the chassis, push the chassis up with a spring/damper force via a
-- VectorForce, then place the wheel's CFrame directly at the raycast result
-- (position only, plus steer/roll for visuals).

local RaycastSuspension = {}
RaycastSuspension.__index = RaycastSuspension

export type Config = {
	RestLength: number?, -- studs from mount to wheel center when the spring is relaxed
	SpringTravel: number?, -- extra downward travel allowed past RestLength before the wheel is unsupported
	SpringStiffness: number?, -- force per stud of compression
	SpringDamping: number?, -- force per (stud/sec) of closing speed
	WheelRadius: number?, -- defaults to 1.5 studs
	Steerable: boolean?,
	MaxSteerAngle: number?, -- radians
	RaycastParams: RaycastParams?,
}

local DEFAULT_REST_LENGTH = 1.5
local DEFAULT_SPRING_TRAVEL = 0.75
local DEFAULT_STIFFNESS = 45000
local DEFAULT_DAMPING = 4500
local DEFAULT_MAX_STEER = math.rad(35)
local DEFAULT_WHEEL_RADIUS = 1.5

export type RaycastSuspension = typeof(setmetatable(
	{} :: {
		Chassis: BasePart,
		Wheel: BasePart,
		RestLength: number,
		SpringTravel: number,
		MaxLength: number,
		SpringStiffness: number,
		SpringDamping: number,
		WheelRadius: number,
		Steerable: boolean,
		MaxSteerAngle: number,
		RaycastParams: RaycastParams?,
		OrientationOffset: CFrame,
		Attachment: Attachment,
		VectorForce: VectorForce,
		IsGrounded: boolean,
		SteerAngle: number,
		SpinAngle: number,
		LastSpringLength: number,
	},
	RaycastSuspension
))

function RaycastSuspension.new(chassis: BasePart, wheel: BasePart, config: Config?): RaycastSuspension
	local cfg = config or {}
	local self = setmetatable({}, RaycastSuspension) :: any

	self.Chassis = chassis
	self.Wheel = wheel

	self.RestLength = cfg.RestLength or DEFAULT_REST_LENGTH
	self.SpringTravel = cfg.SpringTravel or DEFAULT_SPRING_TRAVEL
	self.MaxLength = self.RestLength + self.SpringTravel
	self.SpringStiffness = cfg.SpringStiffness or DEFAULT_STIFFNESS
	self.SpringDamping = cfg.SpringDamping or DEFAULT_DAMPING
	self.WheelRadius = cfg.WheelRadius or DEFAULT_WHEEL_RADIUS
	self.Steerable = cfg.Steerable or false
	self.MaxSteerAngle = cfg.MaxSteerAngle or DEFAULT_MAX_STEER
	self.RaycastParams = cfg.RaycastParams

	-- Preserve however the wheel is currently tilted/rotated relative to the
	-- chassis so we can reproduce that exactly every frame instead of assuming
	-- a particular mesh convention.
	self.OrientationOffset = chassis.CFrame:ToObjectSpace(wheel.CFrame).Rotation

	self.IsGrounded = false
	self.SteerAngle = 0
	self.SpinAngle = 0
	self.LastSpringLength = self.RestLength

	-- Mount point sits directly above the wheel's resting position, RestLength
	-- studs up along the chassis, so at rest the ray lands exactly on the wheel.
	local mountWorldPosition = wheel.Position + chassis.CFrame.UpVector * self.RestLength
	local attachment = Instance.new("Attachment")
	attachment.Name = wheel.Name .. "SuspensionMount"
	attachment.WorldPosition = mountWorldPosition
	attachment.Parent = chassis
	self.Attachment = attachment

	local vectorForce = Instance.new("VectorForce")
	vectorForce.Name = wheel.Name .. "SuspensionForce"
	vectorForce.Attachment0 = attachment
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.ApplyAtCenterOfMass = false
	vectorForce.Force = Vector3.zero
	vectorForce.Parent = chassis
	self.VectorForce = vectorForce

	-- The wheel is purely cosmetic: script drives its CFrame every frame from
	-- the raycast, and the chassis is the real physics body (via VectorForce
	-- above). Anchoring the wheel makes it kinematic so physics never fights
	-- the scripted position, which otherwise causes floating/flickering.
	wheel.Anchored = true
	wheel.CanCollide = false
	wheel.CanTouch = false

	return self
end

function RaycastSuspension.SetSteerAngle(self: RaycastSuspension, angle: number)
	if self.Steerable then
		self.SteerAngle = math.clamp(angle, -self.MaxSteerAngle, self.MaxSteerAngle)
	end
end

-- Call once per Heartbeat with the frame's delta time.
function RaycastSuspension.Update(self: RaycastSuspension, dt: number)
	local chassis = self.Chassis
	local wheel = self.Wheel
	local chassisCFrame = chassis.CFrame
	local up = chassisCFrame.UpVector

	local origin = self.Attachment.WorldPosition
	local castLength = self.MaxLength + self.WheelRadius
	local result = workspace:Raycast(origin, -up * castLength, self.RaycastParams)

	local springLength = if result then math.clamp(result.Distance - self.WheelRadius, 0, self.MaxLength) else self.MaxLength
	local compression = self.RestLength - springLength

	-- Damping from the change in spring length over time (not point velocity):
	-- simpler and matches the proven tutorial implementation this was checked against.
	local springVelocity = (springLength - self.LastSpringLength) / dt
	local force = compression * self.SpringStiffness - springVelocity * self.SpringDamping
	force = math.max(force, 0)
	self.LastSpringLength = springLength

	self.IsGrounded = result ~= nil
	self.VectorForce.Force = if result then up * force else Vector3.zero
	local wheelCenter = origin - up * springLength

	-- Visual spin: roll the wheel around its local axle (X axis) based on how
	-- far the wheel's contact point actually traveled this frame.
	local forwardSpeed = chassis:GetVelocityAtPosition(origin):Dot(chassisCFrame.LookVector)
	self.SpinAngle -= (forwardSpeed / math.max(self.WheelRadius, 0.001)) * dt

	local rotation = chassisCFrame.Rotation * self.OrientationOffset
	if self.Steerable and self.SteerAngle ~= 0 then
		rotation *= CFrame.Angles(0, self.SteerAngle, 0)
	end
	rotation *= CFrame.Angles(self.SpinAngle, 0, 0)

	wheel.CFrame = rotation + wheelCenter
end

function RaycastSuspension.Destroy(self: RaycastSuspension)
	self.Attachment:Destroy()
	self.VectorForce:Destroy()
end

return RaycastSuspension

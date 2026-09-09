-- Temporary instrumentation for the "car explodes the instant you get in at a
-- low frame rate" bug. Records everything the crash/damage path actually
-- decides on for a few seconds after a player sits down, then prints it as one
-- block that can be copied straight out of the Output window.
--
-- Delete this file (and the four call sites named below) once the bug is shut.
-- It is deliberately one module rather than prints scattered through the
-- physics, so turning it off is a single flag and removing it is a single
-- search for "VehicleEntryDebug".
--
-- Call sites:
--   VehicleCrashDetector.client.luau - Begin/Finish, per-frame deltaV, impacts
--   VehiclePhysics.luau              - per-wheel suspension numbers (Step)
--   RayCastSuspension.client.luau    - drive-loop gating

local RunService = game:GetService("RunService")

local VehicleEntryDebug = {}

-- The one switch. Set false (or delete the module) when done.
VehicleEntryDebug.Enabled = false

-- How long after sitting down to keep recording, and a hard row cap so a
-- forgotten flag can't eat memory on a 240fps machine.
local WINDOW_SECONDS = 4
local MAX_ROWS = 600

local active = nil

local function now()
	return os.clock()
end

-- Per-frame suspension numbers, written by VehiclePhysics.Step and drained by
-- the next Frame() call. Kept outside `active` because Step runs on a
-- different event than the crash detector and may land either side of it.
local pendingStep = nil

-- Called from VehiclePhysics.Step. Cheap and silent unless a recording is
-- running, so it can stay in the hot loop while this is being chased.
function VehicleEntryDebug.Step(carModel, snapshot)
	if not VehicleEntryDebug.Enabled or not active or active.CarModel ~= carModel then
		return
	end
	pendingStep = snapshot
end

function VehicleEntryDebug.Begin(carModel)
	if not VehicleEntryDebug.Enabled then
		return
	end
	active = {
		CarModel = carModel,
		StartedAt = now(),
		Rows = {},
		Notes = {},
		Frame = 0,
		Finished = false,
	}
	pendingStep = nil
	print(("[EntryDebug] recording %s for %ds - copy everything from here to the END line")
		:format(carModel:GetFullName(), WINDOW_SECONDS))
end

function VehicleEntryDebug.Note(format, ...)
	if not VehicleEntryDebug.Enabled or not active or active.Finished then
		return
	end
	table.insert(active.Notes, {
		Frame = active.Frame,
		Time = now() - active.StartedAt,
		Text = string.format(format, ...),
	})
end

-- `fields` is whatever the caller knows; every key is optional so this never
-- has to be kept in step with the caller.
function VehicleEntryDebug.Frame(carModel, fields)
	if not VehicleEntryDebug.Enabled or not active or active.CarModel ~= carModel or active.Finished then
		return
	end

	local elapsed = now() - active.StartedAt
	active.Frame += 1

	if #active.Rows < MAX_ROWS then
		fields.Frame = active.Frame
		fields.Time = elapsed
		fields.Step = pendingStep
		table.insert(active.Rows, fields)
	end
	pendingStep = nil

	if elapsed >= WINDOW_SECONDS then
		VehicleEntryDebug.Finish()
	end
end

local function fmtVec(v)
	if typeof(v) ~= "Vector3" then
		return "-"
	end
	return string.format("(%.1f,%.1f,%.1f)|%.1f|", v.X, v.Y, v.Z, v.Magnitude)
end

function VehicleEntryDebug.Finish()
	if not active or active.Finished then
		active = nil
		return
	end
	active.Finished = true

	local out = {}
	table.insert(out, "")
	table.insert(out, "===== EntryDebug: " .. active.CarModel.Name .. " =====")
	table.insert(out, ("context: %s, %d rows"):format(
		if RunService:IsStudio() then "Studio" else "live",
		#active.Rows
	))
	table.insert(
		out,
		"f   t      dt     ready mass   | rawDV                gravDV   suspDV                judgedDV | grounded springLens              stiff/damp  scales"
	)

	for _, r in active.Rows do
		local s = r.Step
		table.insert(out, string.format(
			"%-3d %-6.3f %-6.4f %-5s %-6.1f | %-20s %-8.2f %-20s %-8.2f | %-8s %-22s %-11s %s",
			r.Frame,
			r.Time,
			r.Dt or 0,
			tostring(r.DriveReady),
			r.Mass or 0,
			fmtVec(r.RawDeltaV),
			r.GravityDeltaV or 0,
			fmtVec(r.SuspensionDeltaV),
			r.JudgedDeltaV or 0,
			if s then s.Grounded else "-",
			if s then s.SpringLengths else "-",
			if s then string.format("%.0f/%.0f", s.Stiff or 0, s.Damp or 0) else "-",
			if s then string.format("fs=%.2f ss=%.2f", s.FrameScale or 0, s.StableScale or 0) else "-"
		))
	end

	if #active.Notes > 0 then
		table.insert(out, "-- events --")
		for _, n in active.Notes do
			table.insert(out, string.format("f%-3d %-6.3f  %s", n.Frame, n.Time, n.Text))
		end
	else
		table.insert(out, "-- events -- (none)")
	end
	table.insert(out, "===== EntryDebug END =====")

	print(table.concat(out, "\n"))
	active = nil
	pendingStep = nil
end

return VehicleEntryDebug

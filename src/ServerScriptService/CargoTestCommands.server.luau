-- TEMPORARY. Admin-only chat commands for loading cargo before the drive-in
-- loading dock exists, so the mass, the handling penalty, the crate layout and
-- the crash-eject behaviour can all be tuned by feel now rather than after the
-- dock and the contract system are written.
--
-- DELETE THIS FILE once LoadingDock.client.luau lands. It is a testing tool,
-- not a feature: it loads cargo for free, from anywhere, with no contract and
-- no destination, which is not a thing a player should ever be able to do.
--
-- Commands (admins only - see Admin.luau):
--   /cargo <units> [typeId]   load N crates onto the truck you are driving
--   /cargo 0                  unload
--   /cargo types              list the type ids
--   /cargo info               print what is aboard and what it is worth

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Admin = require(ReplicatedStorage.Modules.Admin)
local CargoLoad = require(ReplicatedStorage.Modules.Delivery.CargoLoad)
local CargoTypes = require(ReplicatedStorage.Modules.Delivery.CargoTypes)
local VehicleSeats = require(ReplicatedStorage.Modules.Vehicles.VehicleSeats)
local CargoManager = require(script.Parent.Modules.CargoManager)

local VehicleFolder = workspace:WaitForChild("Vehicles")

local function reply(player, message)
	-- Output window rather than chat: this is a developer tool and the server
	-- console is where the rest of the vehicle systems already log.
	print(string.format("[CargoTest] (%s) %s", player.Name, message))
end

local function handle(player, arguments)
	local first = arguments[1]

	if first == "types" then
		local names = {}
		for _, id in CargoTypes.Order do
			local cargoType = CargoTypes.Get(id)
			table.insert(names, string.format("%s ($%d/crate, fragility %.2f)", id, cargoType.ValuePerUnit, cargoType.Fragility))
		end
		reply(player, table.concat(names, ", "))
		return
	end

	-- Driving, not merely sitting in: loading a truck somebody else is driving
	-- would hand them a handling change they did not ask for.
	local carModel = VehicleSeats.FindCarDrivenBy(player, VehicleFolder)
	if not carModel then
		reply(player, "you are not driving anything")
		return
	end

	if first == "info" or first == nil then
		local load = CargoManager.GetLoad(carModel)
		local chassis = carModel.PrimaryPart
		reply(
			player,
			string.format(
				"%s: %d x %s, condition %.2f, worth $%.0f. Load fraction %.2f, empty mass %.0f, mass now %.0f",
				carModel.Name,
				load.Units,
				load.TypeId,
				load.Condition,
				CargoLoad.Value(load.Units, load.TypeId, load.Condition),
				carModel:GetAttribute(CargoLoad.Attributes.LoadFraction) or 0,
				carModel:GetAttribute(CargoLoad.Attributes.EmptyMass) or 0,
				chassis and chassis.AssemblyMass or 0
			)
		)
		return
	end

	local units = tonumber(first)
	if not units then
		reply(player, "usage: /cargo <units> [typeId] | /cargo types | /cargo info")
		return
	end

	local typeId = arguments[2] or CargoTypes.DefaultTypeId
	if not CargoTypes.Get(typeId) then
		reply(player, string.format("unknown cargo type '%s' - try /cargo types", typeId))
		return
	end

	local loaded = CargoManager.Load(carModel, typeId, units)
	reply(
		player,
		string.format(
			"loaded %d x %s (asked for %d - the rest did not fit, capacity is per-vehicle and upgradeable)",
			loaded,
			typeId,
			units
		)
	)
end

-- Both prefixes are accepted because TextChatService (the default chat since
-- 2023) claims "/" for its own command handling, and whether an unrecognised
-- slash command still reaches Player.Chatted has changed between versions. "!"
-- is never intercepted, so it is the one that definitely works.
local function connectPlayer(player)
	player.Chatted:Connect(function(message)
		if not Admin.IsAdmin(player.UserId) then
			return
		end
		local command, rest = message:match("^([/!]%S+)%s*(.*)$")
		if command ~= "/cargo" and command ~= "!cargo" then
			return
		end

		local arguments = {}
		for word in string.gmatch(rest or "", "%S+") do
			table.insert(arguments, word)
		end

		-- pcall so a typo in a test command can never take this script's
		-- Chatted connection down with it and silently stop every later one.
		local ok, err = pcall(handle, player, arguments)
		if not ok then
			warn("[CargoTest] command failed: " .. tostring(err))
		end
	end)
end

Players.PlayerAdded:Connect(connectPlayer)
-- ...and anyone already here: in Studio's play-solo the local player can be
-- added before this script's first line runs, which would leave the one person
-- testing with no commands at all.
for _, player in Players:GetPlayers() do
	connectPlayer(player)
end

-- Not synced by Rojo. Run DURING A PLAY TEST with the command bar set to
-- CLIENT context (the dropdown at the top of the Command Bar - pick the
-- player, not "Server"), standing near a plot terminal.
--
-- "No prompt appears" has three very different possible causes that all look
-- identical from the outside: PlotTerminal.client.luau never ran at all (old
-- sync, wrong filename, an error before it got that far), it ran but the
-- plot/terminal hierarchy doesn't match what it expects, or it ran fine and
-- you're just standing further than 8 studs from the Screen part. This checks
-- each in order and says which one it is.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local character = player.Character
local rootPart = character and character:FindFirstChild("HumanoidRootPart")
local humanoid = character and character:FindFirstChildOfClass("Humanoid")

print("=== CustomPrompt's global hide conditions ===")
-- CustomPrompt.luau hides EVERY prompt on the client - not just plot ones -
-- whenever any of these say "seated" or "not alive". If one of these is
-- stuck true, a plot prompt can be perfectly configured and still never show.
if not humanoid then
	print("  FAIL  no Humanoid found on character")
else
	print(("  Health            : %.1f"):format(humanoid.Health))
	print(("  SeatPart          : %s"):format(tostring(humanoid.SeatPart)))
	print(("  Sit               : %s"):format(tostring(humanoid.Sit)))
	print(("  GetState()        : %s"):format(tostring(humanoid:GetState())))
	local isSeated = humanoid.SeatPart ~= nil or humanoid.Sit or humanoid:GetState() == Enum.HumanoidStateType.Seated
	if isSeated or humanoid.Health <= 0 then
		print("  FAIL  CustomPrompt will hide EVERY prompt on screen right now - this is almost")
		print("        certainly why nothing appears, independent of the plot setup below.")
	else
		print("  OK    not seated, alive - CustomPrompt should be free to show something")
	end
end

print("=== PlotTerminal.client.luau ran at all? ===")
local playerGui = player:FindFirstChild("PlayerGui")
local terminalGui = playerGui and playerGui:FindFirstChild("PlotTerminalGui")
if terminalGui then
	print("  OK    PlayerGui.PlotTerminalGui exists - the script ran and got past GUI setup")
else
	print("  FAIL  PlayerGui.PlotTerminalGui does NOT exist.")
	print("        The script either never synced in (check the Rojo plugin panel says")
	print("        'Connected' and re-sync), the file isn't under StarterPlayerScripts,")
	print("        or it errored out before reaching the GUI-building code - check the")
	print("        Output window's CLIENT tab specifically (Play Solo mixes them, but a")
	print("        'Play' with multiple test clients gives each its own Output tab).")
	print("        Nothing below this line can be trusted if this failed.")
end

print("=== Remotes (created by PlotManager.server.luau) ===")
for _, name in { "ClaimPlot", "SpawnVehicle", "SelectVehicle", "GetPlotData" } do
	print(("  %-14s: %s"):format(name, if ReplicatedStorage:FindFirstChild(name) then "OK" else "MISSING"))
end

print("=== workspace.Spawn.VehiclePlots ===")
local spawnFolder = workspace:FindFirstChild("Spawn")
local plotsFolder = spawnFolder and spawnFolder:FindFirstChild("VehiclePlots")
if not plotsFolder then
	print("  FAIL  workspace.Spawn.VehiclePlots not found - check the exact names/casing in Explorer")
	return
end

local plotChildren = plotsFolder:GetChildren()
print(("  found %d plot(s) under VehiclePlots"):format(#plotChildren))

for _, plotModel in plotChildren do
	print(("--- %s ---"):format(plotModel.Name))

	local terminal = plotModel:FindFirstChild("Terminal")
	local screen = terminal and terminal:FindFirstChild("Screen")
	local collisionBox = plotModel:FindFirstChild("CollisionBox")

	print(("  Terminal.Screen  : %s"):format(if screen then "OK" else "MISSING"))
	print(("  CollisionBox     : %s"):format(if collisionBox then "OK" else "MISSING"))

	if not screen then
		print("  (client won't build a prompt for this plot at all without Terminal.Screen)")
		continue
	end

	if rootPart then
		local distance = (rootPart.Position - screen.Position).Magnitude
		print(("  distance to Screen: %.1f studs (prompt needs <= 8 by default)"):format(distance))
	end

	-- CustomPrompt.new parents a BillboardGui named "CustomPrompt" directly to
	-- the part you give it - checking for those children is direct proof
	-- setupPlotPrompts actually ran and CustomPrompt.new succeeded, rather than
	-- inferring it from PlotTerminalGui existing (which only proves the script
	-- got through GUI setup, earlier in the same file).
	local promptCount = 0
	for _, child in screen:GetChildren() do
		if child:IsA("BillboardGui") and child.Name == "CustomPrompt" then
			promptCount += 1
			print(("  found CustomPrompt billboard #%d - Enabled=%s"):format(promptCount, tostring(child.Enabled)))
			local canvas = child:FindFirstChildOfClass("CanvasGroup")
			if canvas then
				print(("    CanvasGroup.GroupTransparency=%.2f (0.08 = visible, 1 = hidden)"):format(canvas.GroupTransparency))
			end
		end
	end
	if promptCount == 0 then
		print("  FAIL  no CustomPrompt billboards under Screen at all - setupPlotPrompts")
		print("        never ran (or errored) for this plot. Check Output for an error printed")
		print("        around character spawn, further up than this diagnostic's own output.")
	end

	local ownerUserId = plotModel:GetAttribute("OwnerUserId")
	local ownerName = plotModel:GetAttribute("OwnerName")
	print(("  OwnerUserId       : %s"):format(tostring(ownerUserId)))
	print(("  OwnerName         : %s"):format(tostring(ownerName)))
	if ownerUserId ~= nil then
		print("  (claimed - the claim prompt will never show for this plot; only the open-terminal one, and only to the owner)")
	end
end

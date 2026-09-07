-- Makes a fixed-pixel-designed panel shrink to fit whatever viewport it is
-- actually shown on, uniformly, without touching a single line of the
-- panel's own layout.
--
-- WHY THIS EXISTS: every big panel in this game (the garage terminal, the
-- contract board, the payout summary, the third-person shop) is built the
-- ordinary Roblox way - UDim2.fromOffset sizes and pixel offsets everywhere,
-- designed against a desktop-sized canvas. That is fine on a desktop and it
-- is a real bug on a phone: a 720x700 panel does not become responsive by
-- itself on a 390-wide screen, it just runs off both edges with no way to
-- reach the controls past the edge. Reworking every child's Size and
-- Position into percentages would fix it, but it is a rewrite of each
-- panel's whole layout, individually, forever - every new row or button
-- added later would need the same treatment again.
--
-- A UIScale sidesteps all of that. Parented under the panel, it scales the
-- panel's own Size AND every descendant's Size and Position uniformly, so
-- the whole panel shrinks (or grows) as one image rather than as many
-- independent pieces that would each need their own fix. Only the OFFSET
-- component of a UDim2 is scaled - the Scale component is not - which is
-- exactly right here: every panel this is used on is already centred with a
-- Scale-based Position (fromScale / anchored to 0.5, 0.5), so it stays
-- centred at any scale, and only its pixel dimensions shrink.
--
-- Client-only. Generic on purpose: it names nothing about any one panel.

local Workspace = game:GetService("Workspace")

local ResponsiveScale = {}

-- Fit(panel, options) - attaches a UIScale to `panel` and keeps it sized so
-- the panel fits inside the current viewport with room to spare, shrinking
-- as the viewport shrinks and growing back up to its full designed size
-- (never beyond it) as the viewport allows.
--
-- options:
--   Margin    studs of screen kept clear on every side, so the panel never
--             touches the very edge (default 24).
--   MinScale  never shrinks past this fraction of the design size, so text
--             does not go illegibly small on an extreme viewport - a panel
--             that no longer fits at all is a worse failure than one that
--             overflows slightly (default 0.55).
function ResponsiveScale.Fit(panel, options)
	options = options or {}
	local margin = options.Margin or 24
	local minScale = options.MinScale or 0.55

	-- Read once, from the panel's own Offset size - this IS the size the
	-- panel was designed at, before this module touches anything. Assumes
	-- (like every panel this is used on) that Size is pure Offset with no
	-- Scale component; a panel that mixes the two would need a different
	-- baseline, but none here do.
	local designWidth = panel.Size.X.Offset
	local designHeight = panel.Size.Y.Offset

	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Parent = panel

	local function update()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local viewport = camera.ViewportSize
		if viewport.X <= 0 or viewport.Y <= 0 or designWidth <= 0 or designHeight <= 0 then
			return
		end
		local fit = math.min(1, (viewport.X - margin * 2) / designWidth, (viewport.Y - margin * 2) / designHeight)
		scale.Scale = math.clamp(fit, minScale, 1)
	end

	-- CurrentCamera gets replaced (a respawn swaps cameras out), so the
	-- ViewportSize connection is redone whenever it is, rather than made once
	-- against whatever camera happened to exist when this ran.
	local viewportConnection
	local function rehook()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
		end
		update()
	end

	rehook()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(rehook)

	return scale
end

return ResponsiveScale

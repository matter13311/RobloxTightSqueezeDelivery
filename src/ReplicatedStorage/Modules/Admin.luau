-- Who counts as an admin. Single source of truth shared by the client (which
-- only uses this to decide whether to SHOW admin-only UI, e.g. the "Give
-- $10,000" button in SettingsMenu.client.luau) and the server (which is the
-- actual security boundary - see AdminGrantMoney's handler in
-- PlotManager.server.luau). Never trust the client's own check; it exists
-- purely so non-admins don't see a button that would just get silently
-- rejected.
--
-- TEMPORARY: hardcoded for early testing, per request. Anyone in this table
-- can grant themselves money - fine for now with just the one entry, but
-- replace with a real allowlist (DataStore-backed, or gated some other way)
-- before this ships to anyone who isn't trusted.
local Admin = {}

Admin.UserIds = {
	[23176796] = true,
}

-- How much the settings menu's "Give Money" button grants per click. Shared
-- so the button's own label and the server handler that actually pays out
-- (AdminGrantMoney in PlotManager.server.luau) can never say two different
-- numbers.
Admin.GrantAmount = 10000

function Admin.IsAdmin(userId)
	return Admin.UserIds[userId] == true
end

return Admin

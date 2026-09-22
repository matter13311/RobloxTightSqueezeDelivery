-- Vehicle paint: which colours exist, what they cost, and how a colour gets
-- onto a car. ONE FILE, BOTH SIDES, same as UpgradePasses: the garage paints
-- its local preview with Apply, PlotManager paints the real spawned car with
-- the same Apply, and both validate a saved value with the same Sanitize - so
-- the preview can never show a colour the server would refuse to put on the
-- real car.
--
-- WHAT GETS PAINTED. Every BasePart under a Folder named "Paintable", anywhere
-- in the car. Usually that is Body/Paintable, but it does not have to be: the
-- Pickup's cab shell lives in its Frame folder (welded in Studio, and NOT
-- knock-off-able like Body panels), so it has its own Frame/Paintable rather
-- than being moved into Body and suddenly falling off in crashes. A car with no
-- Paintable folder at all falls back to its whole Body minus glass and lights,
-- which is wrong on most cars (seats, windows, chrome) but is at least visible
-- - it is the "someone added a car and forgot" case, not the intended one.
--
-- A SAVED PAINT VALUE is a string, one of:
--   nil / ""      - stock: the colours the car was built in. Always free.
--   "<ColorId>"   - one of the Colors below, bought with in-game money.
--   "#RRGGBB"     - any colour at all; needs that car's custom paint pass.
-- Strings rather than Color3s because a Color3 cannot go in a DataStore, and
-- because a colour id stays meaningful if its exact shade is retuned here -
-- everyone who bought "Red" gets the new red.
--
-- THE MONEY. There are no free colours: stock is the free option. The eight
-- colours are bought once each, with in-game money, and then work on every
-- car the player owns - buying Red for the Starter and again for the Pickup
-- would feel like paying twice for the same thing. A per-car game pass unlocks
-- the full picker on that car. Nothing here is a security boundary on its own;
-- PlotManager re-checks every purchase and every paint change.

local VehiclePaint = {}

VehiclePaint.FOLDER_NAME = "Paintable"

-- Written onto each painted part the first time it is painted, so "back to
-- stock" has something to go back to. A Color3 attribute, so it survives on a
-- live car and on a cached preview alike.
VehiclePaint.STOCK_ATTRIBUTE = "StockColor"

-- Set true on any part inside a Paintable folder that should keep its own
-- colour anyway (a badge, a stripe) without having to move it out.
VehiclePaint.NO_PAINT_ATTRIBUTE = "NoPaint"

-- Placeholder prices - tune against the economy. Ordered as the swatch grid
-- shows them: the four everyday colours first and cheaper, the four loud ones
-- after.
VehiclePaint.Colors = {
	{ Id = "White", DisplayName = "White", Color = Color3.fromRGB(236, 236, 236), Price = 750 },
	{ Id = "Black", DisplayName = "Black", Color = Color3.fromRGB(28, 28, 32), Price = 750 },
	{ Id = "Red", DisplayName = "Red", Color = Color3.fromRGB(196, 30, 38), Price = 750 },
	{ Id = "Blue", DisplayName = "Blue", Color = Color3.fromRGB(32, 90, 204), Price = 750 },
	{ Id = "Green", DisplayName = "Green", Color = Color3.fromRGB(38, 150, 72), Price = 1500 },
	{ Id = "Yellow", DisplayName = "Yellow", Color = Color3.fromRGB(246, 198, 36), Price = 1500 },
	{ Id = "Orange", DisplayName = "Orange", Color = Color3.fromRGB(240, 118, 28), Price = 1500 },
	{ Id = "Purple", DisplayName = "Purple", Color = Color3.fromRGB(122, 58, 184), Price = 1500 },
}

VehiclePaint.ColorsById = {}
for _, entry in VehiclePaint.Colors do
	VehiclePaint.ColorsById[entry.Id] = entry
end

-- The game pass that unlocks the custom colour picker, PER CAR - same shape
-- and same reasoning as UpgradePasses.PassIdByVehicleId: owning the Starter's
-- palette does nothing for the Pickup. A vehicle absent from this table has no
-- palette pass yet, which shows as "coming soon" rather than as a button that
-- opens an empty purchase prompt - the safe direction for a car added later
-- and forgotten about here.
--
-- The eight money colours are NOT per car (see PlayerDataStore's PaintColors):
-- buying Red once paints anything you own. It is the free-form picker that is
-- sold per vehicle.
VehiclePaint.CustomPaintPassIdByVehicleId = {
	StarterVehicle = 1988528482,
	PickupTruck = 1988696469,
	BoxTruck = 1992038272,
	StraightTruck = 1990070476,
	AmericanHitchTruck = 1988732476,
}

VehiclePaint.CustomPaintDisplayName = "Custom Paint"

function VehiclePaint.CustomPaintPassIdFor(vehicleId)
	return VehiclePaint.CustomPaintPassIdByVehicleId[vehicleId]
end

local HEX_PATTERN = "^#%x%x%x%x%x%x$"

function VehiclePaint.IsCustom(value)
	return type(value) == "string" and value:match(HEX_PATTERN) ~= nil
end

-- The one shape check. Returns the value if it is a paint the game knows
-- how to draw, or nil (= stock) for anything else - including a colour id
-- that has since been removed from Colors, which quietly reverts that car to
-- stock rather than leaving it holding a name nothing can resolve.
function VehiclePaint.Sanitize(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	if VehiclePaint.ColorsById[value] then
		return value
	end
	if VehiclePaint.IsCustom(value) then
		return string.upper(value)
	end
	return nil
end

function VehiclePaint.ToHex(color)
	return string.format(
		"#%02X%02X%02X",
		math.clamp(math.round(color.R * 255), 0, 255),
		math.clamp(math.round(color.G * 255), 0, 255),
		math.clamp(math.round(color.B * 255), 0, 255)
	)
end

-- nil means stock.
function VehiclePaint.ToColor(value)
	value = VehiclePaint.Sanitize(value)
	if not value then
		return nil
	end
	local preset = VehiclePaint.ColorsById[value]
	if preset then
		return preset.Color
	end
	return Color3.fromRGB(tonumber(value:sub(2, 3), 16), tonumber(value:sub(4, 5), 16), tonumber(value:sub(6, 7), 16))
end

local FALLBACK_SKIPPED_MATERIALS = {
	[Enum.Material.Glass] = true,
	[Enum.Material.Neon] = true,
	[Enum.Material.ForceField] = true,
}

function VehiclePaint.GetPaintableParts(carModel)
	local parts = {}
	local foundFolder = false
	for _, descendant in carModel:GetDescendants() do
		if descendant:IsA("Folder") and descendant.Name == VehiclePaint.FOLDER_NAME then
			foundFolder = true
			for _, part in descendant:GetDescendants() do
				if part:IsA("BasePart") and not part:GetAttribute(VehiclePaint.NO_PAINT_ATTRIBUTE) then
					table.insert(parts, part)
				end
			end
		end
	end
	if foundFolder then
		return parts
	end

	local body = carModel:FindFirstChild("Body")
	if body then
		for _, part in body:GetDescendants() do
			if
				part:IsA("BasePart")
				and not FALLBACK_SKIPPED_MATERIALS[part.Material]
				and part.Transparency < 0.5
				and not part:GetAttribute(VehiclePaint.NO_PAINT_ATTRIBUTE)
			then
				table.insert(parts, part)
			end
		end
	end
	return parts
end

-- Paints a car (a live one or a preview) with a saved paint value. Safe to
-- call repeatedly: the first call remembers each part's stock colour, and a
-- later nil puts it back.
function VehiclePaint.Apply(carModel, value)
	local color = VehiclePaint.ToColor(value)
	for _, part in VehiclePaint.GetPaintableParts(carModel) do
		local stock = part:GetAttribute(VehiclePaint.STOCK_ATTRIBUTE)
		if color then
			if typeof(stock) ~= "Color3" then
				part:SetAttribute(VehiclePaint.STOCK_ATTRIBUTE, part.Color)
			end
			part.Color = color
		elseif typeof(stock) == "Color3" then
			part.Color = stock
		end
	end
end

-- What the swatch for a value looks like, for UI. Stock has no single colour,
-- so the caller passes whatever it wants shown for it.
function VehiclePaint.DisplayName(value)
	value = VehiclePaint.Sanitize(value)
	if not value then
		return "Stock"
	end
	local preset = VehiclePaint.ColorsById[value]
	return if preset then preset.DisplayName else "Custom"
end

return VehiclePaint

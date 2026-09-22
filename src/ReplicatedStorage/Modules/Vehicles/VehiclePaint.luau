-- Vehicle bodywork: which colours and which MATERIALS exist, what they cost,
-- and how each gets onto a car. (The file is still named for paint because
-- paint is most of it; the garage tab it feeds is called "Body".) ONE FILE, BOTH SIDES, same as UpgradePasses: the garage paints
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
-- A SAVED MATERIAL VALUE is a string too: nil/"" is stock (the materials the
-- car was built in, always free), or one of the Materials ids below. There is
-- no free-form equivalent and no material pass - a material is a thing off a
-- list in a way a colour is not, so there is nothing a picker would add.
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

-- The material half of STOCK_ATTRIBUTE, and a string rather than the
-- EnumItem itself because Attributes cannot hold an Enum. Read back through
-- Enum.Material, which is why a material Roblox retires would restore as nil
-- and leave the part where it is rather than throwing.
VehiclePaint.STOCK_MATERIAL_ATTRIBUTE = "StockMaterial"

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

-- THE MATERIALS, priced and ordered exactly like the colours above: bought
-- once each with in-game money, account-wide afterwards, and stock is the free
-- option. Eight of them so the picker is the same grid as the swatches.
--
-- Every one of these had to survive the same test: does a nine-year-old see
-- the difference from across the bay, on a car of any colour? That rules out
-- most of Roblox's material list (Pebble, Slate, Granite and friends all read
-- as "slightly rougher plastic" at garage distance) and it is why the four
-- expensive ones are the four that change the car's silhouette in the light
-- rather than its texture.
--
-- Glass and ForceField are deliberately absent: both make the bodywork
-- see-through, which on a car whose panels can be knocked off reads as damage
-- rather than as a purchase.
--
-- !! TESTING PRICES ARE ACTIVE !! Every material Price below is $1 so the whole
-- grid can be tried on in one sitting; the real figure follows each one after
-- `--default`. RESTORE BEFORE SHIPPING. The eight COLOURS above are untouched
-- and still cost their real price.
--
-- `Swatch` is ONLY the colour of that material's chip in the garage grid, and
-- is not applied to anything. A chip cannot show a material honestly - the
-- real preview is the car itself, three feet away and already wearing it,
-- which is the entire reason the garage parks a live model - so the chip's one
-- job is to be recognisably that material's family at 56 pixels.
VehiclePaint.Materials = {
	{ Id = "Glossy", DisplayName = "Glossy", Material = Enum.Material.SmoothPlastic, Price = 1, Swatch = Color3.fromRGB(206, 210, 218) }, --default price 750
	{ Id = "Metal", DisplayName = "Metal", Material = Enum.Material.Metal, Price = 1, Swatch = Color3.fromRGB(150, 158, 170) }, --default price 750
	{ Id = "Plate", DisplayName = "Plate", Material = Enum.Material.DiamondPlate, Price = 1, Swatch = Color3.fromRGB(118, 124, 134) }, --default price 750
	{ Id = "Wood", DisplayName = "Wood", Material = Enum.Material.WoodPlanks, Price = 1, Swatch = Color3.fromRGB(154, 106, 62) }, --default price 750
	{ Id = "Rusty", DisplayName = "Rusty", Material = Enum.Material.CorrodedMetal, Price = 1, Swatch = Color3.fromRGB(142, 82, 52) }, --default price 1500
	{ Id = "Marble", DisplayName = "Marble", Material = Enum.Material.Marble, Price = 1, Swatch = Color3.fromRGB(228, 226, 232) }, --default price 1500
	{ Id = "Foil", DisplayName = "Foil", Material = Enum.Material.Foil, Price = 1, Swatch = Color3.fromRGB(196, 204, 216) }, --default price 1500
	-- The showpiece, and priced as one: Neon makes the bodywork glow in
	-- whatever colour it is painted, so it is the one material that is worth
	-- more the more colours the player already owns.
	{ Id = "Neon", DisplayName = "Neon", Material = Enum.Material.Neon, Price = 1, Swatch = Color3.fromRGB(122, 244, 214) }, --default price 4000
}

VehiclePaint.MaterialsById = {}
for _, entry in VehiclePaint.Materials do
	VehiclePaint.MaterialsById[entry.Id] = entry
end

-- Every Enum.Material by its own name, for putting a part back on the material
-- it was built in (see Apply). Built by iterating the enum rather than indexed
-- with `Enum.Material[name]` on demand, because indexing an Enum with a name
-- it does not have THROWS - and the name being looked up came out of a saved
-- Attribute, which is exactly the value that can go stale.
local MATERIAL_BY_NAME = {}
for _, item in Enum.Material:GetEnumItems() do
	MATERIAL_BY_NAME[item.Name] = item
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

-- The material half of Sanitize, and the same contract: returns the value if
-- it is a material the game still knows how to draw, or nil (= stock) for
-- anything else - including an id retired from Materials since it was saved,
-- which quietly puts that car back to the materials it was built in.
function VehiclePaint.SanitizeMaterial(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return if VehiclePaint.MaterialsById[value] then value else nil
end

-- nil means stock.
function VehiclePaint.ToMaterial(value)
	local entry = VehiclePaint.MaterialsById[VehiclePaint.SanitizeMaterial(value) or ""]
	return entry and entry.Material
end

function VehiclePaint.MaterialDisplayName(value)
	local entry = VehiclePaint.MaterialsById[VehiclePaint.SanitizeMaterial(value) or ""]
	return if entry then entry.DisplayName else "Stock"
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

-- Paints and re-surfaces a car (a live one or a preview) from a saved paint
-- value and a saved material value, either of which may be nil for stock. Safe
-- to call repeatedly: the first call remembers each part's stock colour and
-- material, and a later nil puts that half back.
--
-- ONE function for both rather than two, because every caller that has one
-- value has the other, and two calls would mean two walks of the car's parts
-- and two chances for a call site to update only half of the look.
function VehiclePaint.Apply(carModel, value, materialValue)
	local color = VehiclePaint.ToColor(value)
	local material = VehiclePaint.ToMaterial(materialValue)
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

		local stockMaterial = part:GetAttribute(VehiclePaint.STOCK_MATERIAL_ATTRIBUTE)
		if material then
			if type(stockMaterial) ~= "string" then
				part:SetAttribute(VehiclePaint.STOCK_MATERIAL_ATTRIBUTE, part.Material.Name)
			end
			part.Material = material
		elseif type(stockMaterial) == "string" then
			-- Indexed, not asserted: a material Roblox has since removed leaves
			-- the part on whatever it is wearing, which is visibly wrong but is
			-- a great deal better than erroring partway through and leaving
			-- half the car in the new material and half in the old.
			local restored = MATERIAL_BY_NAME[stockMaterial]
			if restored then
				part.Material = restored
			end
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

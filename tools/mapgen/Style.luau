-- Colours, facade textures, building proportions and alley themes. Each zone
-- has its own look so a player can tell where they are at a glance:
--
--   Old Town  warm brick and cream, shopfronts, awnings, balconies, rooftop
--             water tanks, neon shop signs.
--   Mill      soot-stained brick and corrugated metal, sawtooth factory
--             roofs, pipes, chimneys, fewer windows.
--   Harbour   blue/green/rust sheds with pitched roofs, container stacks,
--             gravel yards.

local Style = {}

Style.Asphalt = Color3.fromRGB(52, 52, 56)
Style.Sidewalk = Color3.fromRGB(125, 122, 116)
Style.Median = Color3.fromRGB(150, 148, 140)
Style.AlleyPaving = Color3.fromRGB(64, 60, 57)
Style.YardPad = Color3.fromRGB(118, 116, 112)
Style.Dirt = Color3.fromRGB(104, 88, 66)
Style.Gravel = Color3.fromRGB(112, 104, 94)
Style.Water = Color3.fromRGB(38, 74, 92)
Style.QuayWall = Color3.fromRGB(96, 92, 86)

local function tex(id, u, v, r, g, b)
	return { id = "rbxassetid://" .. id, u = u, v = v, color = Color3.fromRGB(r, g, b) }
end

Style.Zones = {
	OldTown = {
		textures = {
			tex(1391982944, 20, 12, 255, 245, 225),
			tex(1393548827, 24, 24, 255, 225, 205),
			tex(1393550516, 15, 21, 255, 220, 200),
			tex(1393550884, 12, 12, 255, 210, 190),
			tex(1413211486, 16, 12, 255, 240, 220),
			tex(2856204540, 16, 12, 255, 225, 200),
			tex(2887662, 6, 6, 190, 120, 100),
		},
		colors = { Color3.fromRGB(128, 70, 56), Color3.fromRGB(150, 96, 72), Color3.fromRGB(196, 180, 150), Color3.fromRGB(88, 84, 80), Color3.fromRGB(170, 120, 90) },
		minH = 30, maxH = 64, minLen = 18, maxLen = 38,
		shopfrontChance = 0.8, awningChance = 0.6, balconyChance = 0.45, waterTankChance = 0.05,
		neonChance = 0.35, sawtoothChance = 0, gableChance = 0, pipeChance = 0.1,
		material = Enum.Material.Brick,
	},
	Mill = {
		textures = {
			tex(2871388059, 12, 12, 230, 230, 220),
			tex(1396501591, 16, 16, 205, 210, 215),
			tex(5143828689, 8, 8, 200, 190, 170),
			tex(2887662, 6, 6, 160, 150, 140),
			tex(1396502464, 16, 12, 215, 230, 220),
		},
		colors = { Color3.fromRGB(96, 70, 60), Color3.fromRGB(82, 78, 74), Color3.fromRGB(110, 96, 80), Color3.fromRGB(70, 72, 76), Color3.fromRGB(120, 84, 62) },
		minH = 22, maxH = 44, minLen = 30, maxLen = 60,
		shopfrontChance = 0.15, awningChance = 0.2, balconyChance = 0, waterTankChance = 0.02,
		neonChance = 0.08, sawtoothChance = 0.45, gableChance = 0, pipeChance = 0.5,
		material = Enum.Material.Brick,
		metalChance = 0.35, -- corrugated sheds
	},
	Harbour = {
		textures = {
			tex(5143828689, 8, 8, 170, 190, 200),
			tex(1396501591, 16, 16, 230, 230, 230),
			tex(2871388059, 12, 12, 230, 230, 220),
			tex(1413211486, 16, 12, 230, 255, 245),
		},
		colors = { Color3.fromRGB(62, 96, 120), Color3.fromRGB(70, 110, 90), Color3.fromRGB(140, 72, 50), Color3.fromRGB(150, 150, 146), Color3.fromRGB(96, 104, 110) },
		minH = 18, maxH = 34, minLen = 32, maxLen = 64,
		shopfrontChance = 0.25, awningChance = 0.3, balconyChance = 0, waterTankChance = 0,
		neonChance = 0.12, sawtoothChance = 0, gableChance = 0.55, pipeChance = 0.1,
		material = Enum.Material.Concrete,
		metalChance = 0.5,
		containerLotChance = 0.25, -- some lots are container stacks instead of buildings
	},
}

Style.Awnings = {
	BrickColor.new("Dark orange").Color,
	BrickColor.new("Dark red").Color,
	BrickColor.new("Earth green").Color,
	BrickColor.new("Medium lilac").Color,
	BrickColor.new("Mulberry").Color,
	Color3.fromRGB(30, 80, 130),
}

Style.ContainerColors = {
	Color3.fromRGB(170, 60, 45), Color3.fromRGB(40, 90, 150), Color3.fromRGB(45, 120, 70),
	Color3.fromRGB(200, 140, 40), Color3.fromRGB(110, 110, 115), Color3.fromRGB(130, 50, 90),
}

-- Graffiti and posters from the previous map's alleys.
Style.Graffiti = {
	"rbxassetid://2170504028", "rbxassetid://2629786665", "rbxassetid://2629752282", "rbxassetid://2655497879",
	"rbxassetid://2170430504", "rbxassetid://2629758285", "rbxassetid://7293575877", "rbxassetid://2170473810",
	"rbxassetid://2598340768", "rbxassetid://2629738446",
}
Style.Posters = { "rbxassetid://2629850706", "rbxassetid://2244905104" }

Style.NeonWords = {
	OldTown = { "PIZZA", "DINER", "HOTEL", "BAR", "LAUNDRY", "BOOKS", "TATTOO", "CAFE", "PAWN", "DELI", "RECORDS", "BARBER" },
	Mill = { "WELDING", "PARTS", "TOOLS", "SCRAP", "GARAGE", "SPARKS", "BOLTS" },
	Harbour = { "FISH", "BAIT", "CHOWDER", "SAILS", "ROPE", "OYSTERS", "ICE" },
	noodle = { "NOODLES", "RAMEN", "DUMPLINGS", "BAO", "TEA", "WOK", "SUSHI" },
}
Style.NeonColors = {
	Color3.fromRGB(255, 70, 120), Color3.fromRGB(80, 220, 255), Color3.fromRGB(255, 200, 60),
	Color3.fromRGB(120, 255, 120), Color3.fromRGB(255, 110, 40),
}

-- Alley themes: what goes in the clutter bands, what hangs overhead, how much
-- litter. `props` names are builders in Props.luau; `overhead` likewise.
Style.AlleyThemes = {
	garbage = { props = { "Dumpster", "GarbagePile", "WheelieBins", "Bags", "Puddle", "Crates" }, overhead = { "Wires", "Wires", "AC" }, litter = 0.8 },
	rats = { props = { "GarbagePile", "Bags", "Tires", "Rats", "Puddle", "WheelieBins" }, overhead = { "Wires", "FireEscape" }, litter = 0.9 },
	pigeon = { props = { "Pallets", "Pigeons", "Crates", "Bags" }, overhead = { "Wires", "Wires" }, litter = 0.5 },
	laundry = { props = { "Washers", "Couch", "Tires", "Bags", "Crates" }, overhead = { "Laundry", "Laundry", "FireEscape", "Balcony" }, litter = 0.5 },
	noodle = { props = { "Stall", "Stall", "Crates", "FoodCrates", "Bags" }, overhead = { "Lanterns", "Lanterns", "Neon" }, litter = 0.4 },
	tight = { props = {}, overhead = { "Wires", "AC", "Pipes" }, litter = 0.6 },
	recycling = { props = { "WheelieBins", "WheelieBins", "Crates", "Cans", "Bags" }, overhead = { "Wires", "FireEscape" }, litter = 0.5 },
	junk = { props = { "Couch", "Washers", "Tires", "Mattress", "Crates" }, overhead = { "Wires", "FireEscape", "Neon" }, litter = 0.6 },
	scrap = { props = { "Tires", "Barrels", "ScrapPile", "Pallets", "Crates" }, overhead = { "Wires", "Pipes", "FireEscape" }, litter = 0.6 },
	cardboard = { props = { "Boxes", "Boxes", "Puddle", "Bags", "Pallets" }, overhead = { "Wires", "Wires" }, litter = 0.9 },
	fish = { props = { "FishCrates", "FishCrates", "Barrels", "Bags", "Puddle" }, overhead = { "Wires", "Nets" }, litter = 0.6 },
	docks = { props = { "Pallets", "Crates", "RopeCoils", "Barrels", "FishCrates" }, overhead = { "Wires", "Nets" }, litter = 0.4 },
	market = { props = { "Stall", "Crates", "FoodCrates", "Bags" }, overhead = { "Lanterns", "Wires" }, litter = 0.4 },
}

return Style

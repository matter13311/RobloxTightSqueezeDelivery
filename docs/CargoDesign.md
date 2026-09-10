# Cargo Load & Delivery — design and implementation notes

Written for whoever (human or AI) picks this up next. It records the *reasoning*,
not just the shape, because most of the decisions here were forced by how
`VehiclePhysics.luau` is already written — and look arbitrary until you know
that.

---

## 1. The gameplay loop this serves

```
Depot  ──▶ pick a contract, choose how heavy to load
       ──▶ drive the route (player's choice of path)
       ──▶ park at the destination (reverse-in pays more)
       ──▶ payout  ──▶ repair / upgrade  ──▶ harder contracts
```

Money comes from **arriving**, never from distance travelled. Multiple routes to
one destination are therefore free — we do not measure the path, only the
endpoint, so a branching map needs no extra scoring machinery. The short tight
alley and the long wide road pay the same; the alley just pays *sooner*.

Cargo load is the risk dial the player pulls themselves every single run: more
crates means more money and a worse-handling truck.

How hard that dial bites is one number, `CargoMassFractionPerUnit`, on each
vehicle config. It is **0.07** — lowered from 0.10, which had been tuned against
a fully-upgraded capacity of 10 and was therefore punishing on the capacity-4 bed
every new player actually drives. Section 5.1 has the unlock order that keeps the
heaviest cargo away from a beginner entirely.

**Weight bands are measured against the truck, not absolutely.** `Light` /
`Moderate` / `Heavy` are multiples of *a full bed of plain Parcels in the vehicle
being quoted* (`CargoLoad.FullBedMassFraction`), so the ratio is
`units / capacity × the type's MassMultiplier` and does not move when the player
upgrades their bed. The first version banded absolute mass fractions, which
broke on the one axis the player controls: `CargoCapacity` is an upgrade, so the
mass a load *can* reach scales with it, and past about capacity 8 every job on
the board read "Heavy". Fixed thresholds do not fail safely here — they just move
the "every band says the same word" bug from one end of the upgrade path to the
other.

---

## 2. What the existing physics does and does not give us

**Read this before tuning anything.** Three of the decisions below were forced by
it.

`VehiclePhysics.Step` applies per-wheel impulses. Which of them scale with
`AssemblyMass` decides what adding cargo mass does for free:

| Effect | Code | Mass-scaled? | Result of adding cargo mass |
|---|---|---|---|
| Suspension spring | `Stiffness * (MaxLength - springLength)` | **No** | Truck sags, squats, bottoms out. Free. |
| Drive force | `Throttle * gearTorque * (...)` | **No** | Slower acceleration, struggles on ramps. Free. |
| Lateral grip | `axleGrip * (mass/4) * g` vs `-v.X * (mass/4)` | **Yes, both sides** | Cornering is *identical* loaded or empty. |
| Foot brake | `frictionStopImpulse`: `coefficient * wheelWeight` vs `v.Z * mass/4` | **Yes, both sides** | Stopping distance is *identical*. |

So mass alone buys us sag and sluggishness, but **not** the two things that make
a heavy load frightening: long stopping distance and losing the back end.

Those are applied explicitly, as a load-scaled multiplier on `BrakeFriction` and
on the lateral grip coefficients — see `CargoLoad.HandlingAt`. This is physically
defensible: a real loaded truck stops worse precisely because tire friction does
not scale linearly with load.

The mass itself is still worth adding, for the sag, the sluggishness, the raised
centre of mass and the collision inertia.

---

## 3. Decisions, and why

### 3.1 Cargo mass lives in ONE invisible ballast part, not in the crates

`VehicleCollisionSetup.server.luau:123` already establishes the convention:
visible bodywork is `Massless = true` and **all** mass lives in the Chassis.
Cargo follows it.

- Crate models: welded, `Massless = true`, purely visual.
- One invisible `CargoBallast` part, welded into the bed, carrying the entire
  load mass via `CustomPhysicalProperties.Density`.

Why not just let the crates weigh something?

- Mass would shift the centre of mass differently depending on how many crates
  spawned and where they landed in the bed grid. That is untunable — you could
  never get consistent handling across loads.
- One part is one number to tune, one number for the server to verify, and
  unloading is `ballast:Destroy()`.

The ballast sits at **bed height, not chassis centre**, which raises the centre
of mass. `VehiclePhysics` applies tire forces at the contact patch specifically
so the body *can* roll (see its `tireForcePosition` comment), so a high ballast
makes a loaded truck genuinely lean and feel tippy. That is real emergent physics
from one well-placed part, not a fudge.

**Do not** change the Chassis's own density: `VehicleCollisionSetup` reads
density back off the part and writes it again, and you would be fighting it.

### 3.2 Mass is expressed as a FRACTION of the truck's empty mass

`CargoMassFractionPerUnit`, not an absolute number. Chassis masses differ per
vehicle and change whenever someone resizes a part in Studio; a fraction keeps
"a full load roughly doubles the truck" true for every vehicle without
re-tuning. The empty mass is measured once, the first time a vehicle is loaded,
and cached on the model as the `CargoEmptyMass` attribute.

### 3.3 Cargo never physically falls off

Crates are welded and `Massless`. Nothing loose is ever added to the assembly.

- The driving client owns the chassis (`Raycast.server.luau:232`). A crate that
  broke loose would become its own assembly with its own network ownership —
  the classic result is crates that teleport and jitter for every player except
  the driver.
- Loose collidable parts in tight alleys wedge under a wheel and launch trucks
  through walls.
- It creates unrecoverable runs. A crate bounces somewhere no truck can reach
  and the run is dead with no recourse. That is a rage-quit, not a challenge.

**Instead**, hard impacts reduce a server-tracked *cargo condition*, and at
thresholds a crate is **visually ejected** — unwelded, `Massless = false`, given
an impulse, handed to `Debris` — exactly the way `VehicleDamage.server.luau`'s
`spawnLoosePanel` already throws body panels. The player sees the crate fly off
and loses its pay. All of the drama, none of the broken states, and it reuses a
pipeline that already exists.

### 3.4 Loading happens at a drive-in dock, not at the plot terminal

The plot terminal is on-foot, per-account, spend-money UI. Loading is per-run,
in-vehicle, in-the-flow. Merging them would make every run start with: park,
exit, walk, menu, walk back, re-enter, drive — six steps of friction on the most
repeated action in the game.

Driving in also means the depot bay **is** the parking mechanic, so it doubles as
a zero-stakes tutorial for the thing that is scored at the destination.

### 3.5 Reverse parking is detected geometrically, not by tracking the gear

At rest, inside the bay:

```lua
local facing = chassis.CFrame.LookVector:Dot(space.CFrame.LookVector)
--  facing >  threshold -> tail-in (reversed, bonus)
--  facing < -threshold -> nose-in
--  in between          -> crooked, no bonus
```

One dot product, and **the geometry enforces it, not the code**: size the bays so
a truck physically cannot turn around inside one, and final orientation becomes a
complete proof of how it entered. There is no exploit left to close.

The check runs **on the server, gated on the truck being stationary**. That
matters: `VehicleDamage.server.luau`'s header explains that the server's copy of a
client-owned chassis is a lagging echo — but only while it is *moving*. A
stationary truck's echo is exact, so "must come to a stop to score" is
simultaneously good game feel and the one condition that makes server-side
validation trustworthy.

In first person with a loaded bed blocking the rear window, `VehicleMirrorViews`
stops being decoration and becomes a required tool. That is the mirrors paying
off.

### 3.6 Crates go on ONE AT A TIME, and the truck is held still while they do

The problem this solves: the player is sitting at the dock looking **forward**,
out of the windscreen. The bed is behind them and they will not turn around to
look at it. A load applied in a single frame is therefore a truck that silently
starts handling worse for no reason the player ever saw — from their seat, the
car just got mysteriously heavy.

So `CargoManager.Load` places one crate every `SecondsPerCrate`, and brings the
ballast up with each one. What that buys, in order of how much work it does:

| Channel | Why it lands | Cost |
|---|---|---|
| **The truck dips on its springs, once per crate** | The suspension spring is NOT mass-scaled (section 2), so every increment of ballast makes the whole vehicle visibly sag. Six crates is six dips, each deeper than the last | free — it is the physics already there |
| **A thud per crate** | Needs no eyeballs at all, which is the entire point for a player facing the wrong way. Randomised from `SoundIds` so a big load is not one sample stuttering | one `Sound`, played server-side so bystanders hear the dock working |
| **The overlay** | Names what is happening and counts it down, for a child who would otherwise read a frozen truck as a broken game, then turns green and says "Cargo Added!" | `CargoLoadingHud.client.luau` |

**Ordered deliberately.** The overlay is the caption, not the event: delete it
and the mechanic still communicates. The dip and the thud are the message.

**Why the truck is held still.** The driving client zeroes throttle and steer
and holds the handbrake while `CargoLoad.IsLoading` is true. It is *not*
anchored — anchoring would freeze the suspension dip, which is the one thing
worth showing. It is also not a security boundary and does not need to be: the
server has already committed the load and taken the contract, so a client that
ignored the hold would simply drive off and have its crates appear around it on
schedule.

**Pace it SLOW.** `SecondsPerCrate` is 0.8, not the 0.35 the first pass used.
An adult reads 0.35 fine; a child cannot process six separate events in two
seconds — the thuds blur into one rumble, the individual dips merge into a
single sag, and the counter finishes before they have worked out what it is
counting. If it is retuned, tune *down* from something too slow rather than up
from something too fast: the failure mode of too slow is boredom, which shows up
in a playtest, and the failure mode of too fast is a child who never learns
their truck got heavy, which does not.

**The beat at the end.** `CompleteHoldSeconds` (2s) keeps the load "in progress"
after the last crate lands, and the truck stays held for it. The overlay turns
green and says **"Cargo Added!"** over "your truck is heavy now — brake early and
take corners slow". That beat is the only point in a run where the player is
stopped, has nothing to do, and is definitely looking at the screen, so it is
where the one sentence they actually need goes. It is not skippable, because a
player who could skip it would, every run.

**`Load` still does not yield.** Everything a caller can observe — the return
value, `Units`, `TypeId`, `Condition` — is committed before it returns; only the
placing runs on its own thread. `DeliveryManager` depends on that (it loads,
then takes the contract off the board, and nothing may slip in between).

Three consequences worth knowing:

- **`CargoUnits` is the final count from the first frame**, not a running total.
  The count that climbs is `CargoLoadingPlaced`, which is absent entirely when
  no load is running — absence is the "am I loading" test.
- **The ballast is created once and then re-densified**, rather than destroyed
  and re-welded per crate. Rebuilding a massive welded part six times in two
  seconds tears the assembly apart and puts it back together on each step, which
  a client-owned chassis on a raycast suspension feels as a lurch.
- **Impacts are ignored while loading.** The truck is immobilised in the bay, so
  any impact arriving then is somebody else driving into a parked vehicle, and
  that should not cost its driver a penny.

---

## 4. What has to exist in Studio

None of this is in the repo — Rojo only syncs `src/`, and models live in the
place file. Build these by hand; the code finds them by name.

### 4.1 On each vehicle template (`ServerStorage.VehicleTemplates.<Name>`)

Add **one Attachment** to the `Chassis` part, alongside the existing `WheelFL` /
`WheelFR` / `WheelRL` / `WheelRR` attachments:

| Name | Type | Where to put it |
|---|---|---|
| `CargoBed` | `Attachment` | Centre of the bed FLOOR, at the height crates should rest on |

Its **orientation matters**: crates are laid out along the attachment's local
axes — `LookVector` is the bed's length (pointing toward the tailgate),
`RightVector` its width, `UpVector` up out of the bed.

If the attachment is missing, `CargoManager` falls back to the rear portion of
the model's bounding box and logs a warning. That works, but it is a guess — add
the attachment.

### 4.2 The depot loading bay and the delivery destinations

```
Workspace
└── Delivery                          (Folder)  ← create this
    ├── Depot                         (Folder)
    │   └── LoadingBay                (Model)
    │       └── Space                 (Part)    ← see "parking space parts" below
    └── Destinations                  (Folder)
        ├── HardwareStore             (Model)   ← name it whatever the place is
        │   ├── Space1                (Part)
        │   └── Space2                (Part)    ← optional, any number
        └── CornerShop                (Model)
            └── Space1                (Part)
```

Anything directly under `Destinations` is a delivery location. Its `Name` is the
id the code uses **and** what shows on the player's HUD, so name them readably.

### 4.3 Parking space parts — the important bit

A parking space is **one Part**, and its transform is the entire contract:

| Property | Value | Why |
|---|---|---|
| `Name` | anything starting with `Space` | how they are found |
| `Anchored` | `true` | it is a marker, not physics |
| `CanCollide` | `false` | the truck drives through it |
| `Transparency` | `1` (use `0.5` while building) | invisible in play |
| `Size` | the bay volume — X = width, Y = height, Z = depth | the truck must fit inside it to count |
| **Orientation** | **the part's FRONT face points OUT of the bay, toward the road the truck arrives from** | this is what makes the reverse-parking dot product work |

Get the orientation wrong and reverse parking scores backwards. To check it in
Studio: the part's front-face arrow should point at the road — i.e. the direction
a truck's *nose* faces once it has reversed in correctly.

Size the space so a truck **cannot turn around inside it**: roughly the truck's
length plus a stud or two, and its width plus a stud or two. That tightness is
what makes orientation-at-rest a proof of reverse entry, and it is the difficulty
of the mechanic.

Optional attributes on a space Part:

| Attribute | Type | Default | Meaning |
|---|---|---|---|
| `PayoutMultiplier` | number | `1` | a nastier bay can be worth more |

---

## 5. Module layout

| File | Role |
|---|---|
| `ReplicatedStorage/Modules/Delivery/CargoTypes.luau` | Crate definitions: appearance, value, fragility |
| `ReplicatedStorage/Modules/Delivery/CargoLoad.luau` | Shared math: load → mass, handling penalty, cargo value |
| `ReplicatedStorage/Modules/Delivery/DeliveryConfig.luau` | Tuning + the names everything looks for in Workspace |
| `ReplicatedStorage/Modules/Delivery/ParkGrade.luau` | Shared: is the truck in the bay, and how well parked |
| `ReplicatedStorage/Modules/Delivery/ProgressionConfig.luau` | Delivery milestones, the contract cap they unlock, refill timing, product ids |
| `ServerScriptService/Modules/Destinations.luau` | The destination list, its spaces and its distance pricing |
| `ServerScriptService/Modules/ContractPool.luau` | A player's persisted job board: generation, real-time refill, refresh |
| `ServerScriptService/Monetization.server.luau` | `ProcessReceipt` — the game's only one. Today: the board refresh product |
| `ServerScriptService/Modules/CargoManager.luau` | Authoritative load state; builds crates + ballast; turns validated impacts into ruined goods |
| `ServerScriptService/DeliveryManager.server.luau` | Contracts, arrival detection, payout |
| `StarterPlayer/StarterPlayerScripts/DeliveryHud.client.luau` | Contract board at the dock, running-job display, payout summary |
| `StarterPlayer/StarterPlayerScripts/CargoLoadingHud.client.luau` | The "Loading Cargo" overlay while crates are being placed. Pure caption — see section 3.6 |

There is no separate loading-dock script: the contract board is part of
`DeliveryHud`, and it opens when `ParkGrade` says the truck is stopped inside
the depot's bay — the same test the server re-runs before it loads anything.

### The loop as built

1. Drive into `Delivery.Depot.LoadingBay` and stop. The board opens with the
   jobs currently in your pool, each sized to your truck's current
   `CargoCapacity`. It is the SAME pool every time — see section 5.1.
2. Accept one. The server re-checks you are in the bay, in your own truck, at
   rest, then loads the crates and the ballast — one crate at a time, over
   several seconds, with the truck held still. See section 3.6.
3. Drive to the named destination and park in one of its spaces.
4. Stop for `StoppedHoldSeconds`. The server grades the park, pays out, and
   empties the bed.

Quoted pay is the **floor** — a pristine, nose-in delivery. Reversing in
cleanly and arriving undamaged pays more. That direction matters: players are
told a number that can only go up, rather than one they get docked from.

### 5.1 The contract pool, delivery milestones, and the refresh product

The board is not rolled on arrival. Each player carries a **pool** of contracts
in their save (`ContractPool.luau`), and every visit to the dock shows that
same pool. Driving out and back in changes nothing; neither does hopping to
another server.

The pool refills **one job at a time**, on a real-time clock
(`ProgressionConfig.Contracts.RegenSeconds`, currently 10 minutes), up to a cap.
Accrual stops at the cap, so a week away banks a full board and no more.
Accepting a job — not completing it — is what takes it off the board.

How big the board gets is gated on **lifetime deliveries**, and that count is
the only progression number in the game. There is no EXP and no level: both were
considered and both were the same fact under a second name, so every gate is
stated and displayed in deliveries. Board sizes live in
`ProgressionConfig.Contracts.CapMilestones`; vehicles carry their own figure as
`VehicleCatalog`'s `RequiredDeliveries`.

| Lifetime deliveries | Board holds |
|---|---|
| 0 | 3 jobs |
| 20 | 4 jobs — also unlocks the Pickup Truck |
| 75 | 5 jobs |
| 200 | 6 jobs |
| 450 | 7 jobs |

Deliveries gate **which cargo types the board will offer**, too
(`ProgressionConfig.Cargo.UnlockMilestones`):

| Lifetime deliveries | Unlocks | Mass | Why there |
|---|---|---|---|
| 0 | Parcels | 1.00 | Light, cheap, unbreakable — the baseline everything else is priced and banded against |
| 0 | Party Balloons | 0.50 | Half the weight of Parcels and the brightest thing in the catalog. Fragile, so it teaches "drive smoothly" with none of the weight lesson attached |
| 0 | Flat-Pack Furniture | 0.85 | Wide and flat, so a stack of it reads differently from everything else before the colour even registers |
| 5 | Fresh Produce | 1.15 | Barely heavier than Parcels, but it bruises |
| 12 | Paint Cans | 1.25 | The first genuinely mid-weight load, and fragile with it — the careful-driving lesson at a weight that can punish it, before Glassware charges properly for the same mistake |
| 25 | Glassware | 1.40 | Heavy *and* fragile, so it wants both lessons at once. Deliberately after the Pickup Truck at 20 |
| 50 | Sand & Gravel | 2.10 | Three times the weight of Parcels. Last, and not close |

**Three types at zero, not one.** A starting board holds three jobs, and with a
single unlocked type it drew three identical brown stacks — a board that is not
a choice and does not look like one. All three starters are at or below Parcels'
weight, which matters as much as the colour: the heavy end was already well
covered, and weight is what a beginner is least equipped to handle, so variety
early is bought at the *light* end.

**Why gate them.** Weight is this game's difficulty, and the types carry wildly
different amounts of it. Ungated, a brand new player's first board could be
nothing but gravel — and a stock vehicle under a full gravel load could barely
pull out of the bay. That is not a difficulty spike the player chose; the random
number generator chose it for them, on the one run where they know least about
how the game drives.

The alternative was to make every type lighter until the worst case was
survivable, which flattens the whole catalog to protect its first ten minutes.
Gating leaves gravel exactly as heavy as it should be and simply does not offer
it yet. It also turns four of the seven types into something to unlock, which
the game had none of between "buy a bigger bed" and "buy a second vehicle".

Two consequences worth knowing:

- **The tutorial needs no special case.** Its forced first contract is whatever
  the board offers a 0-delivery player, and by construction that is one of the
  three lightest types in the game.
- **The gate is on GENERATION only.** A contract already in a player's pool is
  never revoked — taking back a job somebody can already see is worse than the
  rare save that holds one its owner has not yet earned.

The depot footer shows whichever of the two ladders — board size or next cargo
type — is *nearer*, by name ("12 more deliveries to unlock Glassware"). One line
was the space available, and the near target is the one a player can act on.

### 5.2 Why the board does not draw uniformly at random

`ContractPool.generate` picks both the destination and the cargo type
**preferring one not already on the board**, falling back to the full set once
everything is represented.

Uniform random clumps visibly at the size a board actually is. With three
destinations, better than one board in ten is three copies of the same place;
with three cargo types, the same again. Both were reported as bugs, and that is
the correct reaction — a board of three identical jobs is not a choice, however
defensible the dice were.

It is a preference, not a rule, so a map with two destinations and a board of
five still generates.

**If one destination is all you ever see**, check the server log at startup:
`Destinations.Build` now prints the list it found (`Destinations: 3 built —
Warehouse1, Warehouse2, ...`). Contract generation can only offer names on that
list, and the usual reason a building is missing from it is that it has no
`Space*` part, which `Build` skips with a warning nobody is looking for.

### 5.3 Crate colour

A crate's colour is `CargoTypes.CrateColor(type, index)` — entry
`(index mod #Palette) + 1` of the type's optional `Palette`, falling back to its
flat `Color`. A full bed used to be one solid slab of a single colour; three or
four shades break it into countable boxes.

**Indexed, not random.** The contract board draws its ViewportFrame preview from
the same `CargoLoad.CrateOffset` grid the real crates use, so two callers
computing the same colour from the same index need no shared seed and cannot
drift — the preview matches the bed crate for crate, which is the whole reason
that grid is shared in the first place.

Leaderstats are **Money** and **Deliveries**. Deliberately no third column: a
level would have been the delivery count looked up in a table, so the player
list would have carried the same fact twice.

A **developer product** refills the board to the cap *and* re-rolls every job in
it. Both halves matter — a refill alone does nothing for a player whose
complaint is that the jobs they have are bad ones. The purchase is granted
through `Monetization.server.luau`, which is and must remain the game's only
`ProcessReceipt` callback, and the save is written through immediately: a
consumed receipt Roblox will never re-present must never be able to buy nothing.

What is persisted per contract is a **seed** — id, destination, cargo type, and
how full a load it is as a *fraction* of capacity — never a finished card. Crate
counts, quoted pay and weight bands are all derived at draw time against the
truck the player is sitting in, so upgrading `CargoCapacity` still changes what
the board offers, and re-tuning payouts re-prices every saved job with no
migration.

### Money

`PlotManager` still owns every player's balance. It exposes one
`BindableFunction` named `AwardMoney` under `ServerScriptService` — server-only,
so no client can see it — and `DeliveryManager` pays out through that. Nothing
else may touch `data.Money`.

The contract pool is reached the same way and for the same reason: it is part of
the save, so `PlotManager` owns it and exposes `GetContractBoard`,
`TakeContract`, `RecordDelivery` and `RefreshContracts` as server-only
BindableFunctions. `DeliveryManager` and `Monetization` never see player data.

### How load reaches the physics

One attribute, no new remotes — the same trick `VehicleOwnership` uses:

- The server sets `CargoLoadFraction` (0–1) on the **vehicle Model**.
- `VehiclePhysics.Step` reads it every frame and lerps `BrakeFriction` and the
  lateral grip coefficients toward their loaded multipliers.

Attributes replicate for free, so the driving client's physics loop reads exactly
what the server wrote. It is read per-frame rather than baked into `GetConfig`
because `GetConfig` runs once per drive session, and load changes while the
player is already seated at the dock.

### Vehicle config keys

Flat, not a nested `Cargo = {}` table, deliberately: `GetConfig`'s Attribute
override tier cannot hold tables (its own comment says so), and flat keys get
that tier for free.

| Key | Meaning |
|---|---|
| `CargoCapacity` | crate slots. Also an `Upgrades` entry, so it is purchasable |
| `CargoMassFractionPerUnit` | mass added per crate, as a fraction of empty mass |
| `CargoLoadedBrakeMultiplier` | `BrakeFriction` multiplier at 100% load |
| `CargoLoadedGripMultiplier` | lateral grip multiplier at 100% load |
| `CargoBedAttachmentName` | defaults to `"CargoBed"` |

`CargoCapacity` drops straight into the existing `Upgrades` table format, so
`VehicleUpgrades`, `PlayerDataStore.reconcile` and the terminal's slider UI pick
it up with no new machinery — `reconcile` already iterates `rawConfig.Upgrades`
generically.

---

## 6. Known soft spot: exploits

Cargo condition derives from client-reported impacts (the client owns the
chassis, so it has to). A cheater who suppresses reports gets full pay.
`VehicleDamage`'s rate limiting and clamping stop the worst of it.

This is deliberately not over-engineered: it is a "make more money than intended"
exploit, not a "break the game for other players" one. Cap per-run payout
server-side, and revisit only if it ever matters.

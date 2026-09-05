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
| `ServerScriptService/Modules/CargoManager.luau` | Authoritative load state; builds crates + ballast; turns validated impacts into ruined goods |
| `ServerScriptService/DeliveryManager.server.luau` | Contracts, arrival detection, payout |
| `StarterPlayer/StarterPlayerScripts/DeliveryHud.client.luau` | Contract board at the dock, running-job display, payout summary |
| `ServerScriptService/CargoTestCommands.server.luau` | **Temporary.** Admin `/cargo` commands for tuning before the dock exists — delete once the loop is proven |

There is no separate loading-dock script: the contract board is part of
`DeliveryHud`, and it opens when `ParkGrade` says the truck is stopped inside
the depot's bay — the same test the server re-runs before it loads anything.

### The loop as built

1. Drive into `Delivery.Depot.LoadingBay` and stop. The board opens with three
   offers, each sized to your truck's current `CargoCapacity`.
2. Accept one. The server re-checks you are in the bay, in your own truck, at
   rest, then loads the crates and the ballast.
3. Drive to the named destination and park in one of its spaces.
4. Stop for `StoppedHoldSeconds`. The server grades the park, pays out, and
   empties the bed.

Quoted pay is the **floor** — a pristine, nose-in delivery. Reversing in
cleanly and arriving undamaged pays more. That direction matters: players are
told a number that can only go up, rather than one they get docked from.

### Money

`PlotManager` still owns every player's balance. It exposes one
`BindableFunction` named `AwardMoney` under `ServerScriptService` — server-only,
so no client can see it — and `DeliveryManager` pays out through that. Nothing
else may touch `data.Money`.

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

```
██████╗ ███████╗ █████╗ ██╗     ██╗████████╗██╗   ██╗
██╔══██╗██╔════╝██╔══██╗██║     ██║╚══██╔══╝╚██╗ ██╔╝
██████╔╝█████╗  ███████║██║     ██║   ██║    ╚████╔╝
██╔══██╗██╔══╝  ██╔══██║██║     ██║   ██║     ╚██╔╝
██║  ██║███████╗██║  ██║███████╗██║   ██║      ██║
╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝      ╚═╝
 ████████╗██╗   ██╗███╗   ██╗███████╗██████╗  ██████╗██╗  ██╗██╗██████╗
 ╚══██╔══╝██║   ██║████╗  ██║██╔════╝██╔══██╗██╔════╝██║  ██║██║██╔══██╗
    ██║   ██║   ██║██╔██╗ ██║█████╗  ██████╔╝██║     ███████║██║██████╔╝
    ██║   ██║   ██║██║╚██╗██║██╔══╝  ██╔══██╗██║     ██╔══██║██║██╔═══╝
    ██║   ╚██████╔╝██║ ╚████║███████╗██║  ██║╚██████╗██║  ██║██║██║
    ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝
```

> **RealitySucks-TunerChip** — Universal drift chip for QBCore. Five profiles. Useable item. Persistent state. Free.

`Framework: QBCore` &nbsp;|&nbsp; `Version: 2.0.0` &nbsp;|&nbsp; `License: GPL-3.0` &nbsp;|&nbsp; `Price: Free.99`

---

## // 01 — WHAT THIS IS

A drift chip resource players can install on nearly any vehicle in-game using an item (`ws_driftchip`).
Once installed, it modifies the vehicle's handling in real time — traction, inertia, steering lock, engine power — to make it slide.

Five profiles are included. Each one feels and behaves differently. Players pick what fits their car and style.

When a player logs out with drift active, it remembers. When they log back in, it re-enables automatically.

No database needed. No ox_lib. No extra dependencies beyond qb-core and qb-menu.

---

## // 02 — FILES & WHAT THEY DO

> New to FiveM scripting? Here's exactly what each file is responsible for.

| File | Runs On | Purpose |
|---|---|---|
| `fxmanifest.lua` | — | Tells FiveM what this resource is and which files to load |
| `config.lua` | Client | All settings — keys, profiles, allowed vehicles, messages |
| `client.lua` | Client | The actual drift logic — reads config, modifies vehicle handling |
| `server.lua` | Server | Creates the useable item, saves drift state to player metadata |

**Why client and server?**
In FiveM, some things can only happen on the client (vehicle handling, NUI, player input) and some things can only happen on the server (saving data, item registration, database calls). This resource uses both — that's standard QBCore structure.

---

## // 03 — INSTALL

```
1.  Extract RealitySucks-TunerChip into your /resources folder
2.  Open server.cfg and add:         ensure RealitySucks-TunerChip
3.  Add ws_driftchip to your shared items (see step 4 below)
4.  Restart your server
```

**Step 3 explained — adding the useable item:**

Open `qb-core/shared/items.lua` and add this inside the items table:

```lua
['ws_driftchip'] = {
    name         = 'ws_driftchip',
    label        = 'Drift Chip',
    weight       = 100,
    type         = 'item',
    image        = 'ws_driftchip.jpg',
    unique       = false,
    useable      = true,
    shouldClose  = true,
    combinable   = nil,
    description  = 'A performance chip that modifies vehicle handling for drift.'
},
```

> **What is a useable item?** In QBCore, a useable item is an item in a player's inventory that triggers a server-side function when used. In `server.lua`, we register `ws_driftchip` as useable — so when a player clicks "use" on the item in their inventory, QBCore calls our function, which then tells the client to apply the drift profile. That's the whole flow: inventory → server event → client event → handling change.

---

## // 04 — CONFIG BREAKDOWN

Everything tunable lives in `config.lua`. Here's what each setting actually does:

```lua
Config.ApplyOnEnter = false
```
If `true`, drift auto-applies when a player gets into a vehicle (if they had it on when they logged out).
Set to `false` if you want players to manually re-enable it each session.

```lua
Config.InstallMs = 1200
```
Fake "install" delay in milliseconds when enabling the chip. Creates immersion — the notification shows "Installing..." and waits before applying. Set to `0` to skip it entirely.

```lua
Config.AllowedVehicleClasses = {0,1,2,3,4,5,6,7,8,9,12}
```
Controls which GTA vehicle classes can use the chip. Class numbers map to:
`0` Compacts · `1` Sedans · `2` SUVs · `3` Coupes · `4` Muscle · `5` Sports Classics · `6` Sports · `7` Super · `8` Motorcycles · `9` Off-road · `12` Vans

Remove a class number to block it. Set to `nil` to allow everything.

```lua
Config.ToggleKey   = 'F5'
Config.MenuKey     = 'F6'
```
Default keybinds. Players can rebind these in GTA's key settings after first use. You can change the defaults here.

---

## // 05 — DRIFT PROFILES

Each profile tunes different handling values. Here's what they feel like and when to use them:

| Profile | Handling Style | Smoke Color | Best Vehicle Type |
|---|---|---|---|
| **Balanced** | Stable, predictable slides — easy to control | White | Any RWD car |
| **Takeover** | Loose rear, big angle, heavy smoke | Warm yellow-white | Wide body builds |
| **Pursuit** | Grip/drift hybrid — fast cornering with slip | Light blue | Police interceptors, chase builds |
| **JDM** | Snappy throttle response, tight precise angle | Green tint | Japanese sports cars |
| **Muscle** | Maximum torque, long sustained slides | Warm red tint | American V8 builds |

> Players switch profiles with F6 (or `/driftmenu`). The selected profile persists until they change it or disable drift.

---

## // 06 — CREATIVE IDEAS FOR YOUR SERVER

Don't just hand players the item. Here are ways to build around it:

**Drift Shop Job**
Create an NPC mechanic at a garage or tuner shop location. Players bring their car, pay a fee, and the mechanic "installs" the chip. Gate the item behind that interaction instead of a flat shop.

**Racing League Whitelist**
Only allow certain vehicle classes — strip out everything except Sports and Super (classes 6 and 7). Make the chip an entry requirement for a drift league faction or job.

**Illegal Street Racing Economy**
Tie the chip to the black market. Only obtainable through md-drugs money laundering or a criminal contact NPC. Makes drift culture feel underground, not just a free toggle.

**Ranked Drift Modes**
Lock the stronger profiles (Takeover, Muscle) behind a skill or reputation system. New players start with Balanced only. Unlock better profiles through events or achievements tracked in metadata.

**Vehicle-Specific Chips**
Duplicate the resource and create profile variants — a `JDM Chip` that only allows the JDM profile and only works on Japanese car models. Sell them as separate items at different price points.

**Drift Event Activator**
Trigger `ws-driftchip:client:SelectMode` server-side during a scheduled drift event to auto-equip all registered participants with the Takeover profile for the duration. Clean it up with the Disable event when the event ends.

---

## // 07 — KEYBINDS & COMMANDS

| Input | Action |
|---|---|
| `F5` | Toggle drift on / off |
| `F6` | Open profile selection menu |
| `/drift` | Toggle via chat command |
| `/driftmenu` | Open menu via chat command |

---

## // 08 — TROUBLESHOOTING

**Drift isn't applying when I use the item**
Make sure `ws_driftchip` is added to `qb-core/shared/items.lua` exactly as shown in the install section. If the item doesn't exist in shared, QBCore won't register it as useable.

**qb-menu isn't opening**
Confirm `qb-menu` is started in your `server.cfg` before `RealitySucks-TunerChip`. Resource load order matters.

**Handling isn't resetting after disable**
The resource stores original handling values when it first touches a vehicle. If you modify handling with another resource after the chip loads, the stored "original" values may be stale. Restart the resource or the vehicle to reset the store.

**Players can drift in vehicles they shouldn't**
Edit `Config.AllowedVehicleClasses` in `config.lua` and remove the class numbers you want to block.

---

## // 09 — LICENSE

GPL-3.0 — Free to use, modify, and redistribute. Credit appreciated, not required.
This was built on a live server and tested before release. If something breaks, open an issue.

---

```
// Made by RealitySucksRP
// Built for the community — not for profit.
// Reality Sucks. Script anyway.
```

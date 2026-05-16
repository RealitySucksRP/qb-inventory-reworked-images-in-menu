# qb-inventory-punk

**RealitySucks Edition -- Dungeon UI**

Open-source custom UI qb-inventory for FiveM, built on the Anya-Project rework backend.
Cash-as-item support, optional HUD compatibility hook, fully patched and CFX-clean.
Style name is "punk", nickname is "Dungeon UI". All original logic -- drag-drop, stash
system, Vue.js app -- is untouched. Only the visual layer and a few backend hooks were
rebuilt.

Version: `2.5.1-rs-punk-open-source`

---

## What This Is

A complete CSS and asset overhaul of QBCore's qb-inventory, layered on top of the
Anya-Project (AP) qb-inventory-rework backend. Holographic glass panels, hex grid
backgrounds, dungeon decorative art behind the menu, segmented weight bars, custom
typography. The inventory logic itself is the original framework code plus the AP
rework patches -- only `main.css`, `fxmanifest.lua`, and added UI art files were touched
on the frontend.

This release is genuinely open source: no `escrow_ignore` block, no `/assetpacks`
dependency. Drop it in, run it, fork it.

---

## What Changed From Stock

The entire CSS was replaced with an intentional design system:

- Full dark background with subtle 40px grid lines and color zone glows (green player
  side, blue storage side)
- Glass panel surfaces with top accent lines per inventory type
- Item slots are flat dark with corner bracket accents that lift on hover
- Segmented weight bar -- 12 individual segments instead of a plain fill bar
- Barlow Condensed typography with dominant weight numbers and eyebrow tags
- Context menu rebuilt with left border accent on hover, sharp and clean
- Hotbar flush to the bottom of the player panel with active slot indicator line
- Slot entry animation replaced with a clean scale-in
- Holographic hex / server-tech skin with true transparent glass panel
- Dungeon background art layers: zhead, zbody, zskelly placed behind the menu
- RealitySucks logo (rslogo) watermark inside the inventory panel

Nothing in `index.html`, `app.js`, or `js/app.js` was modified. Vue.js logic, drag and
drop, tooltips, context menu behavior, weapon attachments -- all original.

---

## Features Preserved

All original qb-inventory features work as before:

- Stashes (personal and shared)
- Vehicle trunk and glovebox
- Weapon attachments
- Shops with price display
- Item drops
- Drag and drop between inventories
- Context menu -- use, give, drop, split, serial, attachments
- Item durability bar per slot
- Hotbar with keybind slots 1-5
- Item tooltips with description and weight

---

## Cash As Item

This package ships with cash-as-item support enabled by default via the AP rework
backend. This requires a patched `qb-core/player.lua` that treats cash as a regular
inventory item rather than account balance.

If you do not want cash-as-item behavior, set in `config/config.lua`:

```lua
Config.CashAsItem = false
```

If you do keep it enabled, make sure your `qb-core` is patched for the AP rework, or
cash will not persist correctly.

---

## Custom HUD Integration (Optional)

The inventory will hide and show your HUD when the menu opens and closes. By default it
calls the `SetHUDLifeVisible` export on `rs-hudlifeV2`. If you do not use that HUD,
disable the hook in `config/config.lua`:

```lua
Config.CustomHUD = {
    Enabled = false,
    ResourceName = 'rs-hudlifeV2',
    ExportName  = 'SetHUDLifeVisible'
}
```

To use a different HUD resource, change `ResourceName` and `ExportName` to match your
HUD's export.

---

## Dependencies

- [qb-core](https://github.com/qbcore-framework/qb-core) -- patched for AP rework if using cash-as-item
- [qb-weapons](https://github.com/qbcore-framework/qb-weapons)
- [oxmysql](https://github.com/overextended/oxmysql)

---

## Installation

1. Drop the folder into your `[qb]` resources directory
2. **IMPORTANT:** rename the folder to `qb-inventory`, or your `server.cfg` ensure line
   will not match
3. Add to your `server.cfg`:

   ```cfg
   ensure qb-inventory
   ```

4. Import `qb-inventory.sql` into your database if doing a fresh install (see below)
5. Configure `config/config.lua` for your HUD (or disable the hook)

---

## Database (Fresh Install)

```sql
CREATE TABLE IF NOT EXISTS `inventories` (
  `id` INT(11) NOT NULL AUTO_INCREMENT,
  `identifier` VARCHAR(50) NOT NULL,
  `items` LONGTEXT DEFAULT ('[]'),
  PRIMARY KEY (`identifier`),
  KEY `id` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4;
```

---

## Migrating From Old qb-inventory

Upload `qb-inventory.sql` to create the new `inventories` table. Use the provided
`migrate.sql` to move all saved inventory data from stashes, trunks, and gloveboxes.
Once migration is complete you can drop the `gloveboxitems`, `stashitems`, and
`trunkitems` tables.

---

## Config Defaults

| Setting              | Default          |
|----------------------|------------------|
| MaxWeight            | 120000 (120 kg)  |
| MaxSlots             | 40               |
| StashSize maxweight  | 2000000          |
| StashSize slots      | 100              |
| DropSize maxweight   | 1000000          |
| DropSize slots       | 50               |
| Open keybind         | TAB              |
| Hotbar keybind       | Z                |
| CleanupDropTime      | 15 minutes       |
| CleanupDropInterval  | 1 minute         |

---

## Localization

Eight languages included in `locales/`: Arabic, Czech, German, English, Spanish,
Japanese, Dutch, Portuguese. Switch via your qb-core locale setting.

---

## UI Tweaking

See `RS_UI_QUICK_TWEAKS.txt` in the resource root for the full CSS variable reference.
Quick summary -- all easy tweaks are CSS variables at the bottom of `html/main.css`:

**Glass transparency:**
- `--rs-panel-glass` -- lower = clearer menu panel
- `--rs-header-glass` -- lower = clearer top header
- `--rs-slot-glass` -- lower = clearer item slots
- `--rs-logo-watermark-opacity` -- higher = stronger logo behind menu
- `--rs-art-opacity` -- higher = stronger side images

**Dungeon art positioning:**
- `--rs-zhead-left` / `--rs-zhead-top`
- `--rs-zbody-right` / `--rs-zbody-top`
- `--rs-zskelly-right` / `--rs-zskelly-bottom`

**Sizing:**
- `--rs-item-icon-scale` -- item icon size inside slots
- `--rs-item-slot-min-height` -- slot row height
- `--rs-zhead-width` / `--rs-zbody-width` / `--rs-zskelly-width`

**Notification placement:**
- `--rs-notify-right` / `--rs-notify-top` / `--rs-notify-size`

---

## Version History

### v1.1 -- RS Dungeon UI Patch
- Added transparent PNG UI art files: `rslogo.png`, `zhead.png`, `zbody.png`, `zskelly.png`
- Placed zhead, zbody, zskelly behind the menu UI as decorative background layers
- Added rslogo as a watermark inside the inventory panel
- Kept the main inventory grid at 5 columns with slots 1-5 numbered
- Updated `fxmanifest.lua` so top-level UI PNG files load correctly and item images can
  remain in `html/images/`

### v1.2 -- RS UI Sizing
- Stretched the player inventory menu height about 50% taller without changing width or
  column count
- Added bottom-of-file easy CSS controls for menu height and decorative image movement

### v1.3 -- Holographic Cyberpunk Skin (2026-05-01)
- Applied the holographic cyberpunk / dungeon menu preview styling to the live inventory
- Only visual menu CSS was changed: panels, borders, columns, slot glow, hover styling
- Inventory logic, item image paths, drag/drop, and hotbar behavior unchanged
- Item icons still belong in `html/images/`

### v1.5 -- Transparent Glass
- Kept the holographic hex / server-tech skin
- Made the panel true transparent glass so the logo and art show through behind the menu

### v1.6 -- Dungeon UI Cleanup
- Fixed holographic transparent/grid background leaking before character select and
  staying visible during gameplay
- Disabled global `body::before` and `body::after` visual overlays so the game screen
  stays clean when the inventory is closed
- Kept the holographic grid / glass style inside the inventory menu only
- Moved `zskelly` slightly down and left on the screen
- No inventory logic, item paths, drag/drop, hotbar, or server code changed

### v1.7 -- Notification and Art Clarity
- Fixed item notification placement to right-center, slightly higher
- Forced notification size/style to match the zombie build
- Enlarged dungeon background art and moved zskelly lower/left
- Kept the holographic grid inside the inventory only

### v1.8 -- Text and Item Icon Clarity
- Notification position/style left untouched from v1.7
- Enlarged and sharpened inventory header text, weight text, slot numbers, amount text,
  and bottom hints
- Enlarged item icons inside the inventory squares
- Increased dungeon background art size/contrast so the images stand out more behind the
  glass UI

### v2.5.1 -- Open Source Release
- Removed invalid loose Lua note file (`For Damage & BC_Wounding.lua`)
- Removed old backup files and dev-only folders
- Removed dead/orphan root `config.lua` that was not loaded by `fxmanifest.lua`
- Verified no `escrow_ignore` and no `/assetpacks` dependency
- Kept the custom menu UI and dungeon art intact

---

## Credits

Original resource by the QBCore Framework team:
[qbcore-framework/qb-inventory](https://github.com/qbcore-framework/qb-inventory)
Copyright (C) 2021 Joshua Eger.

Huge thank you to **Anya-Project** -- the rework patches in
[qb-inventory-rework](https://github.com/Anya-Project/qb-inventory-rework) are the
backend foundation that made cash-as-item and the polish layer possible.

Build by **Kakarot** and **RealitySucks RP** (William Brito).
UI redesign and Dungeon theme by RealitySucks RP.

---

## License

Licensed under the GNU General Public License v3. Full license text is in the `LICENSE`
file in this repository.

```
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see https://www.gnu.org/licenses/
```

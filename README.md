# qb-inventory-punk

> Open-source custom UI qb-inventory for FiveM -- Dungeon UI / Punk Edition. Holographic glass panels, dungeon art behind the menu, cash-as-item support, AP rework backend.

[![License](https://img.shields.io/badge/license-GPL--3.0-red)](LICENSE)
[![Framework](https://img.shields.io/badge/framework-QBCore-blue)](https://github.com/qbcore-framework/qb-core)
[![Version](https://img.shields.io/badge/version-2.5.1--rs--punk-green)](https://github.com/RealitySucksRP/qb-inventory-reworked-images-in-menu/releases)

## Preview

![qb-inventory-punk preview](qb-inventory-punk.png)

## Features

- Holographic glass panels with hex grid background and color-zone glows
- Dungeon art layers (zhead, zbody, zskelly) placed behind the menu
- RealitySucks logo watermark inside the inventory panel
- Segmented 12-piece weight bar
- Barlow Condensed typography with dominant weight numbers
- Corner-bracket item slots that lift on hover
- Custom hotbar flush to the bottom of the player panel with active slot indicator
- Cash-as-item support via AP rework backend
- Optional HUD hide/show hook (works with rs-hudlifeV2 or any HUD that exposes a visibility export)
- All original qb-inventory logic preserved: stashes, vehicle trunk/glovebox, weapon attachments, drops, shops, durability, item tooltips
- Genuinely open source -- no escrow_ignore, no assetpacks dependency

## Dependencies

- [qb-core](https://github.com/qbcore-framework/qb-core) (patched for AP rework if using cash-as-item)
- [qb-weapons](https://github.com/qbcore-framework/qb-weapons)
- [oxmysql](https://github.com/overextended/oxmysql)

## Installation

1. Download and extract into your `resources` folder
2. **Rename the folder to `qb-inventory`** -- this is critical, server.cfg will not match otherwise
3. Add `ensure qb-inventory` to your `server.cfg`
4. Import `qb-inventory.sql` into your database (fresh install)
5. Open `config/config.lua` and either configure your HUD export or set `Config.CustomHUD.Enabled = false`
6. Restart your server

## Configuration

| Option                    | Default              | Description                                                                |
| ---                       | ---                  | ---                                                                        |
| `CashAsItem`              | `true`               | Cash treated as inventory item via AP rework. Requires patched qb-core.    |
| `CustomHUD.Enabled`       | `true`               | Hide/show external HUD when inventory opens.                               |
| `CustomHUD.ResourceName`  | `rs-hudlifeV2`       | Resource name of the HUD to hook.                                          |
| `CustomHUD.ExportName`    | `SetHUDLifeVisible`  | Export function called on visibility change.                               |
| `MaxWeight`               | `120000`             | Max player carry weight in grams (120 kg).                                 |
| `MaxSlots`                | `40`                 | Max player inventory slots.                                                |
| `StashSize.maxweight`     | `2000000`            | Max stash weight.                                                          |
| `StashSize.slots`         | `100`                | Max stash slots.                                                           |
| `DropSize.maxweight`      | `1000000`            | Max ground drop weight.                                                    |
| `DropSize.slots`          | `50`                 | Max ground drop slots.                                                     |
| `Keybinds.Open`           | `TAB`                | Open inventory keybind.                                                    |
| `Keybinds.Hotbar`         | `Z`                  | Toggle hotbar keybind.                                                     |
| `CleanupDropTime`         | `15`                 | Drop cleanup time (minutes).                                               |
| `CleanupDropInterval`     | `1`                  | Drop cleanup check interval (minutes).                                     |

## Cash As Item

This package ships with cash-as-item enabled by default. The AP rework backend treats cash as a regular inventory item rather than account balance. This requires a patched `qb-core/player.lua` from the Anya-Project rework. If your qb-core is not patched, either patch it or set:

```lua
Config.CashAsItem = false
```

## Custom HUD Integration

By default the inventory calls the `SetHUDLifeVisible` export on `rs-hudlifeV2` to hide and show your HUD when the menu opens. To use a different HUD, edit `config/config.lua`:

```lua
Config.CustomHUD = {
    Enabled      = true,
    ResourceName = 'your-hud-resource',
    ExportName   = 'YourVisibilityExport'
}
```

Or disable the hook entirely by setting `Enabled = false`.

## Database

Fresh install:

```sql
CREATE TABLE IF NOT EXISTS `inventories` (
  `id` INT(11) NOT NULL AUTO_INCREMENT,
  `identifier` VARCHAR(50) NOT NULL,
  `items` LONGTEXT DEFAULT ('[]'),
  PRIMARY KEY (`identifier`),
  KEY `id` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4;
```

Migrating from old qb-inventory: import `qb-inventory.sql` to create the new `inventories` table, then run `migrate.sql` to move data from `stashitems`, `trunkitems`, and `gloveboxitems`. After confirming the move, drop those three legacy tables.

## UI Tweaking

All easy CSS controls live at the bottom of `html/main.css`. See `RS_UI_QUICK_TWEAKS.txt` for the full reference. Quick summary:

**Glass transparency** -- `--rs-panel-glass`, `--rs-header-glass`, `--rs-slot-glass`, `--rs-logo-watermark-opacity`, `--rs-art-opacity`

**Dungeon art positioning** -- `--rs-zhead-left/-top`, `--rs-zbody-right/-top`, `--rs-zskelly-right/-bottom`

**Sizing** -- `--rs-item-icon-scale`, `--rs-item-slot-min-height`, `--rs-zhead-width`, `--rs-zbody-width`, `--rs-zskelly-width`

**Notifications** -- `--rs-notify-right`, `--rs-notify-top`, `--rs-notify-size`

## Version History

- **v2.5.1** -- Open source release. Removed dead files, verified no escrow_ignore, no assetpacks dependency.
- **v1.8** -- Enlarged and sharpened inventory text, slot numbers, weight readouts, and item icons.
- **v1.7** -- Notification placement fixed to right-center, dungeon art enlarged, zskelly moved lower-left.
- **v1.6** -- Stopped holographic background from leaking before character select and during gameplay.
- **v1.5** -- True transparent glass panel so logo and art show through behind the menu.
- **v1.3** -- Holographic cyberpunk skin applied to the live inventory.
- **v1.2** -- Player inventory stretched 50% taller; added bottom-of-file CSS controls.
- **v1.1** -- Dungeon UI patch: added rslogo, zhead, zbody, zskelly PNG art behind the menu.

## Credits

Original resource: [qbcore-framework/qb-inventory](https://github.com/qbcore-framework/qb-inventory) -- Copyright (C) 2021 Joshua Eger

Backend foundation: [Anya-Project/qb-inventory-rework](https://github.com/Anya-Project/qb-inventory-rework) -- huge thanks for the rework patches that made cash-as-item and the polish layer possible.

Build by **Kakarot** and **RealitySucks RP**.
UI redesign and Dungeon theme by William Brito (RealitySucks RP).

## License

GPL-3.0 -- Free to use, modify, and redistribute with credit.

---

Made by [RealitySucksRP](https://github.com/RealitySucksRP) -- built for the community, not for profit.

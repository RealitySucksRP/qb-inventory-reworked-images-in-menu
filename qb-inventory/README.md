# qb-inventory -- RealitySucks Edition

Custom UI redesign of qb-inventory for FiveM. All original logic, drag-drop, stash system, and Vue.js app are untouched. Only the visual layer was rebuilt -- `main.css` -- to bring the inventory up to standard. 

\---

## // 01 -- WHAT CHANGED

The entire CSS was replaced with an intentional design system:

* Full dark background with subtle 40px grid lines and color zone glows (green player side, blue storage side)
* Glass panel surfaces with top accent lines per inventory type
* Item slots are flat dark with corner bracket accents that lift on hover
* Segmented weight bar -- 12 individual segments instead of a plain fill bar
* Barlow Condensed typography with dominant weight numbers and eyebrow tags
* Context menu rebuilt with left border accent on hover, sharp and clean
* Hotbar flush to the bottom of the player panel with active slot indicator line
* Slot entry animation replaced with a clean scale-in

Nothing in `index.html`, `app.js`, or `js/app.js` was modified. Vue.js logic, drag and drop, tooltips, context menu behavior, weapon attachments -- all original.

\---

## // 02 -- DEPENDENCIES

* [qb-core](https://github.com/qbcore-framework/qb-core)
* [qb-smallresources](https://github.com/qbcore-framework/qb-smallresources) -- for transfer logging

\---

## // 03 -- FEATURES

All original qb-inventory features are preserved:

* Stashes (personal and shared)
* Vehicle trunk and glovebox
* Weapon attachments
* Shops with price display
* Item drops
* Drag and drop between inventories
* Context menu -- use, give, drop, split, serial, attachments
* Item durability bar per slot
* Hotbar with keybind slots 1-5
* Item tooltips with description and weight

\---

## // 04 -- INSTALLATION

Drop the folder into your `\[qb]` resources directory and add to your `server.cfg`:

```bash
ensure qb-inventory
```

Import `qb-inventory.sql` into your database if doing a fresh install.

\---

## // 05 -- DATABASE (fresh install)

```sql
CREATE TABLE IF NOT EXISTS `inventories` (
  `id` INT(11) NOT NULL AUTO\_INCREMENT,
  `identifier` VARCHAR(50) NOT NULL,
  `items` LONGTEXT DEFAULT ('\[]'),
  PRIMARY KEY (`identifier`),
  KEY `id` (`id`)
) ENGINE=InnoDB AUTO\_INCREMENT=1 DEFAULT CHARSET=utf8mb4;
```

\---

## // 06 -- MIGRATING FROM OLD qb-inventory

Upload the new `inventory.sql` file to create the new `inventories` table. Use the provided `migrate.sql` to move all saved inventory data from stashes, trunks, and gloveboxes. Once complete you can drop the `gloveboxitems`, `stashitems`, and `trunkitems` tables.

\---

## // 07 -- CREDITS

Original resource by the QBCore Framework team -- [qbcore-framework/qb-inventory](https://github.com/qbcore-framework/qb-inventory)

UI redesign by RealitySucks RP.

\---

## // 08 -- LICENSE

Original QBCore inventory is licensed under the GNU General Public License v3.
Design by William Brito

Credit and license.

&#x20;   QBCore Framework
    Copyright (C) 2021 Joshua Eger



HUGE THANK YOU TO ANYA-PROJECT. These are the patches I needed to make this work. 



https://github.com/Anya-Project/qb-inventory-rework 

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program. If not, see <https://www.gnu.org/licenses/>


\---

\*RealitySucks RP --  PLEASE MAKE SURE TO NAME THIS FILE qb-inventory on your resources folder and server.cfg



## RS DUNGEON UI Patch v1.1 --Dungeon is a nickname punk is the style. 

* Added transparent PNG UI art files: `rslogo.png`, `zhead.png`, `zbody.png`, and `zskelly.png`.
* Placed zhead, zbody, and zskelly behind the menu UI as decorative background layers.
* Added rslogo as a watermark inside the inventory panel.
* Kept the main inventory grid at 5 columns with slots 1-5 numbered.
* Updated `fxmanifest.lua` so top-level UI PNG files load correctly and item images can remain in `html/images/`.

## RS UI v1.2

* Stretched the player inventory menu height about 50% taller without changing width or column count.
* Added bottom-of-file easy CSS controls for menu height and decorative image movement.

## RS UI Update - v1.3 - applied holographic cyberpunk/dungeon menu preview

* Date: 2026-05-01
* Added the latest preview styling to the live inventory menu.
* Only visual menu CSS was changed: panels, borders, columns, slot glow, and hover styling.
* Inventory logic, item image paths, drag/drop, and hotbar behavior were not changed.
* Item icons still belong in `html/images/`.

## RS UI Update

* v1.5 - kept new holographic hex/server-tech skin and made the panel true transparent glass so the logo/art show behind the menu.



## RS Dungeon UI v1.6

* Fixed holographic transparent/grid background leaking before character select and staying visible during gameplay.
* Disabled global `body::before`/`body::after` visual overlays so the game screen stays clean when inventory is closed.
* Kept the holographic grid/glass style inside the actual inventory menu only.
* Moved `zskelly` slightly down and left on the screen.
* No inventory logic, item image paths, drag/drop, hotbar behavior, or server code changed.

### v1.7 - Notification / art clarity patch

* Fixed item notification placement to right-center, slightly higher.
* Forced notification size/style to match the zombie build.
* Enlarged dungeon background art and moved zskelly lower/left.
* Kept the holographic grid inside the inventory only.

### RS UI v1.8 - Text + Item Icon Clarity

* Notification position/style left untouched.
* Enlarged and sharpened inventory header text, weight text, slot numbers, amount text, and bottom hints.
* Enlarged item icons inside the inventory squares.
* Increased dungeon background art size/contrast so the images stand out more behind the glass UI.


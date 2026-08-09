# RS qb-inventory Punk Edition Patch v2.5.6

Changed-files-only patch for the Punk/Dungeon edition.

## Fixes included
- Slot swap fix: dragging weapon/item onto an occupied slot now swaps correctly.
- Weapon x1 can swap with item stacks without the server rejecting the move amount.
- Rework-style Weapon Inspection panel added to this Punk edition.
- Normal attachment-item installs show in the panel.
- Prebuilt/purchased weapon attachments are read from weapon metadata.
- Reads multiple metadata formats: info.attachments, info.components, info.mods, weaponAttachments, weapon_attachments.
- Reads component strings/hashes and attachment item keys.
- Fallback reads currently installed ped weapon components when the weapon is held.
- Shop purchase uses the registered shop item info as source of truth so prebuilt weapon metadata is preserved.

## Files changed
- qb-inventory/html/app.js
- qb-inventory/html/index.html
- qb-inventory/html/main.css
- qb-inventory/client/main.lua
- qb-inventory/server/main.lua

## Not touched
- images
- sounds
- config
- fxmanifest
- escrow/assetpacks
- database SQL

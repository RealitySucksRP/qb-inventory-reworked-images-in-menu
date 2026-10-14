# RS Punk qb-inventory v3.0.5 — QBCore Production Guard

This pass applies the sibling inventory's production-security findings to the Punk twin without replacing its menu style.

## Security / authority

- Scope remains QBCore + qb-inventory only; no Qbox/ESX/Standalone bridge and no external `rs_bridge` dependency.
- Added the Cfx `/onesync` manifest constraint because vehicle/drop authority depends on server network ids, coordinates and routing buckets.
- Vehicle sessions retain and revalidate the same network id, plate, inventory type and routing bucket on every move; capacity is resolved from server entity/QBCore data rather than client claims.
- Player, drop, vehicle and shop interactions reject cross-routing-bucket access.
- Generic stashes are bound to their trusted open position and live distance checks.
- Vending requests are rate-limited and validate model/proximity/context; optional strict coordinates provide full server-side location authority for static map vending.
- Robbery search duration is server-enforced and victim state is checked again before opening.
- Server-only search locks prevent two-robber races without trusting replicated client state.
- Live inventory sessions are watchdog-revalidated and force-close when their authorization context disappears.
- Shop purchases share the inventory mutation mutex, re-read stock after locking and reject malformed/negative pricing.
- Item use rejects dead/last-stand/handcuffed state and is server rate-limited.
- Dynamic tooltip HTML is escaped before rendering.
- Client writes to `inv_busy` were removed; the server owns that state.
- Raw `playerDropped` clears locks, pending drop requests and debounced persistence state so recycled source IDs cannot inherit stale state.

## Drops / lifecycle

- Drops are routing-bucket aware and use the carrier's server coordinates when placed back down.
- A player may carry only one server-tracked bag; carried bags cannot simultaneously be opened.
- Death/last stand releases carried bags.
- Late-streamed bag entities remain registered for target reconciliation instead of being lost after one failed entity lookup.
- Creation failures/collisions clean up and refund safely.
- Empty/expired drops are removed from server state before entity cleanup.
- Server-owned drop entities are deleted on resource stop.
- Forced close/unload/resource stop explicitly restores NUI focus, blur, HUD state, pending operations, carry state and the exact opened trunk door.

## Persistence / cash / correctness

- Dirty stash/trunk/glovebox state is debounced to the database and flushed on close/shutdown/resource stop.
- Dirty cached inventory removal no longer silently evicts state after a failed database save.
- Cash-state requests are rate-limited and the client cash update handler is present.
- Punk's existing `Config.CashItemName` is now honored consistently instead of server files silently hard-coding `cash`.
- Same-inventory rearrangements report success correctly and `SetItemData` schedules persistence.
- Vending registrations are ephemeral and cleaned on close/unload/disconnect.
- Manifest image patterns explicitly include `.png`, `.PNG` and `.webp` while excluding non-runtime files in the image folder.

## Punk UI preservation

- Punk `index.html`, layout/art, item images and menu styling remain the active NUI.
- Punk-only image helper methods are preserved.
- The active CSS no longer calls Google Fonts at runtime; the same CSS family names now resolve to the fonts already bundled in `html/font/`.
- The old `html/ui.html`, `html/css/` and `html/js/` files remain unreferenced legacy material and are not loaded by the manifest.

## Known boundaries

- Non-networked base-map vending prop existence cannot always be independently proven server-side unless `VendingStrictLocations` is enabled and coordinates are configured.
- GTA door-lock status remains part of the normal client interaction path; the server still proves exact vehicle identity, bucket and distance throughout the inventory session.
- Floor drops are intentionally runtime-ephemeral rather than database-persistent.

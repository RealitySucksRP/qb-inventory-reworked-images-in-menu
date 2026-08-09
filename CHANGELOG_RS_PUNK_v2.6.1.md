# RealitySucksRP qb-inventory v2.6.1 — Drop/Inventory Synchronization Fix

## Fixed

- Floor drops now return the authoritative server-side player inventory and drop inventory in one response.
- Removed the browser-side second subtraction that could make an item disappear or reappear depending on event timing.
- Player inventory refresh events now carry the authoritative server item table instead of rereading stale client-cached `PlayerData.items`. Legacy callers without a payload are refreshed through a server snapshot callback.
- Inventory moves, merges, splits, and swaps now reconcile both panels from the server after each operation.
- Rejected ghost-item moves are corrected immediately instead of remaining visible until the inventory is reopened.
- Added one-operation-at-a-time UI gating while an inventory transaction is waiting for the server.
- Added unique drop operation IDs and short server-side idempotency caching to prevent a repeated callback from creating/removing the same drop twice.
- Added per-player drop request locking.
- Failed bag creation/networking refunds the item to the authoritative player inventory.
- Drop entity placement no longer blocks the NUI callback indefinitely.
- Drop target/entity waits are bounded so stuck network entities do not leave permanent client threads.
- Floor-drop locks now track the player using the bag and release the previous bag when the UI switches to a newly created drop.

## Compatibility

- No SQL changes.
- No config changes.
- No item image or UI artwork changes.
- Cash-as-item remains enabled exactly as supplied.
- The legacy `DropItem` NUI callback remains available for older custom UI code.

## Version

`2.6.1-rs-punk-drop-sync`

# Punk UI — v2.6.2 Cash Synchronization Hotfix

**Development baseline:** `2.6.2-rs-punk-cash-sync`  
**Live-confirmed:** No

## Fixed

- Normal QBCore `AddMoney('cash')`, `RemoveMoney('cash')`, and `SetMoney('cash')` operations now synchronize with the physical `cash` inventory item.
- Existing account-only cash is migrated into a physical cash item when no item exists yet.
- Existing physical cash remains authoritative when both account and item values already exist but disagree.
- Inventory-originated cash changes update QBCore buying power without recursively calling patched money functions.
- HUD and inventory refreshes receive the same authoritative cash amount.
- A failed cash-item creation/removal rolls QBCore cash back to the actual item total, preventing invisible spendable cash.
- Added a clear startup warning when `Config.CashAsItem = true` but `qb-core/shared/items.lua` is missing the `cash` item.

## Preserved

- All v2.6.1 authoritative floor-drop, ghost-item reconciliation, idempotency, refund, and bounded entity-wait fixes.
- Existing UI, CSS, images, item definitions, SQL, weight/slot settings, HUD hide/show hook, and custom integrations.

## Changed files

```text
fxmanifest.lua
server/main.lua
server/functions.lua
server/cash_sync.lua
CHANGELOG_RS_PUNK_v2.6.2.md
```

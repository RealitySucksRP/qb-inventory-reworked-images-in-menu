# Punk UI — v2.6.3 Cash Authority / Display Hotfix

**Development baseline:** `2.6.3-rs-punk-cash-authority`  
**Live-confirmed:** No

## Fixed

- Reworked account-to-item synchronization so physical `cash` is written as one canonical stack instead of routing the repair back through generic `AddItem`/`RemoveItem`.
- Removes the v2.6.2 false "free an inventory slot" failure when a valid cash stack/free slot already exists.
- Supports both stock QBCore money functions and older AP/RS qb-core builds that already route cash through qb-inventory.
- Cash item changes update `PlayerData.money.cash` directly so vehicle shops and other framework scripts retain normal buying power.
- The bridge no longer manually re-fires `QBCore:Server:OnMoneyChange` during item->account repair, avoiding duplicate/legacy server-event paths that can expose broken `source` handling in customized qb-core builds.
- Added authoritative server cash-state request on player/resource load; the client no longer recalculates HUD cash from possibly stale `PlayerData.items` snapshots.
- Added a 5-second drift reconciler for resources/core forks that mutate cash without emitting the normal money event.
- Added `/cashcheck` to compare physical cash and QBCore cash totals in game.
- Cash slot amounts now display as currency, e.g. `$34,601,900`, instead of `x34601900`.

## Preserved

- All v2.6.1 floor-drop duplication, ghost-item reconciliation, request-lock, refund, and bounded entity-wait fixes.
- All v2.6.2 QBCore/physical-cash bridging behavior that was already working.
- Existing Punk UI artwork, CSS, item images, SQL, item definitions, weight/slot configuration, weapons, expiry/freshness behavior, and HUD visibility integration.

## Changed files in cumulative patch

```text
fxmanifest.lua
html/index.html
html/app.js
client/main.lua
client/drops.lua
server/main.lua
server/functions.lua
server/cash_sync.lua
server/commands.lua
CHANGELOG_RS_PUNK_v2.6.1.md
CHANGELOG_RS_PUNK_v2.6.2.md
CHANGELOG_RS_PUNK_v2.6.3.md
```

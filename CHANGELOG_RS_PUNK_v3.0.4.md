# RS Punk qb-inventory v3.0.4

Death/cash compatibility hardening for the Punk UI twin. No Punk NUI art or menu layout was changed.

## Confirmed root cause addressed

A live trace showed an external gameplay resource calling QBCore cash removal while the player was dead:

```text
[qb-core][death-cash-guard] BLOCKED cash removal while dead | src=1 amount=1000 reason=zombie-death-loss invoking=RealitySucks_ZombieHubs
```

With Cash-As-Item enabled, normal `RemoveMoney('cash', ...)` calls intentionally remove the physical `cash` inventory item too. That is correct for purchases, but it can surprise server owners when death/zombie/medical/hardcore resources also impose cash penalties.

## Added

- Death/last-stand guard in qb-inventory `RemoveCash`.
- Final-authority guard for direct `RemoveItem(..., 'cash', ...)` calls while dead/downed.
- `Config.CashItemName = 'cash'` so cash preservation/sync code uses one canonical item name.
- Protection for generic `SetInventory` replacements so an empty replacement does not silently erase existing physical cash.
- Post-`ClearInventory` repair/save passes to survive external medical/death scripts that race inventory persistence.
- Cash/HUD refresh after protected inventory clears.
- Detailed blocked-removal logging with amount, reason, invoking resource, and optional traceback.
- `SERVER_OWNER_COMPATIBILITY_NOTES.md` with a death-resource audit checklist and server.cfg guidance.
- Warning added to `docs/qb-core-cash-as-item.md` so an older install recipe is not used to overwrite the newer death-cash guard.

## Default protection

Recommended server.cfg settings:

```cfg
set qb_protect_cash_while_dead 1
set qb_death_cash_trace 1
```

Only set `qb_protect_cash_while_dead 0` if the server intentionally wants trusted resources to remove physical cash while the player is dead/downed.

## Preserved

- Punk UI artwork, fonts, images, CSS, layout, and `html/app.js` are untouched by this patch.
- Existing v3.0.3 structural fixes remain intact.
- Existing v3.0.2 server-authoritative session/security/transfer/drop/shop behavior remains intact.
- `Config.CustomHUD.Enabled = true` remains unchanged.
- Punk vehicle-capacity settings remain unchanged.

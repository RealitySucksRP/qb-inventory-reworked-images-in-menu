# RS Punk qb-inventory — Server Owner Compatibility Notes: Cash-As-Item + Death / Respawn Resources

## Read this before enabling physical cash

RS Punk qb-inventory ships with `Config.CashAsItem = true`. When `qb-inventory` is configured with cash as a physical inventory item, QBCore cash and the `cash` item are intentionally synchronized.

That means this normal framework call:

```lua
Player.Functions.RemoveMoney('cash', amount, reason)
```

is no longer "account-only" bookkeeping. It removes the matching physical `cash` item from the player's inventory as well.

This is correct behavior for purchases, fines, shops, and other normal cash transactions. It becomes dangerous when another resource has its own death-loss, respawn-loss, zombie-death, hardcore, survival, robbery, or wipe system.

## Confirmed compatibility incident

A live server trace identified this exact conflict:

```text
[qb-core][death-cash-guard] BLOCKED cash removal while dead | src=1 amount=1000 reason=zombie-death-loss invoking=RealitySucks_ZombieHubs
```

The caller was `RealitySucks_ZombieHubs`, using the reason `zombie-death-loss`.

This proves the loss was not caused by `rs-lilhudlife`, `qb-inventory`, or `qb-ambulancejob`. A separate gameplay resource intentionally requested a cash deduction at death, and cash-as-item synchronization would have correctly converted that request into physical inventory removal.

The same class of conflict can come from ANY resource, not just ZombieHubs.

## Server-owner checklist

Before deploying this build, audit every resource that reacts to player death, last stand, bleed-out, hospital respawn, zombie death, PvP death, robbery death, or character reset.

Search those resources for calls or strings such as:

```text
RemoveMoney('cash'
RemoveMoney("cash"
SetMoney('cash'
SetMoney("cash"
RemoveCash
RemoveItem
cash
isdead
inlaststand
death-loss
death_loss
death penalty
lost $
WipeInventoryOnRespawn
UPDATE players SET inventory
inventory = '{}'
```

A match is not automatically a bug. It means the resource must be reviewed to decide whether cash loss is actually intended.

## Recommended rules

### If players should KEEP physical cash when they die

Keep this enabled in `server.cfg`:

```cfg
set qb_protect_cash_while_dead 1
```

This is the recommended default for this package.

Death/downed cash-removal attempts are rejected at both QBCore and qb-inventory authority layers.

### If a resource has an optional death-money penalty

Disable that resource's death-cash penalty, or configure the penalty to use `bank` instead of `cash` when appropriate for your server design.

Do not assume a "cash" penalty is harmless framework metadata. With Cash-As-Item enabled, `cash` means the physical inventory item.

### If the server intentionally wants players to lose physical cash on death

Only then disable the protection knowingly:

```cfg
set qb_protect_cash_while_dead 0
```

Doing this allows any trusted server resource using normal QBCore/qb-inventory cash removal paths to take physical cash while the player is dead/downed.

Audit all death-related resources before disabling it.

## Notifications must check the transaction result

A death-penalty resource should never show "You died and lost $X" unless the money removal actually succeeded.

Safe pattern:

```lua
local removed = Player.Functions.RemoveMoney('cash', amount, 'death-penalty')

if removed then
    -- show the loss notification
else
    -- do not claim money was lost
end
```

If the resource ignores the return value, the player may still see a false loss notification even though the death-cash guard protected the money.

## Do not wipe inventory with direct SQL

Do not use death/respawn code that directly replaces a player's inventory row with `{}` or another empty payload.

Direct SQL inventory wipes bypass inventory authority, preservation rules, cash-as-item synchronization, logging, and rollback behavior.

Use the inventory resource's server API and explicitly define which items are preserved.

## qb-ambulancejob note

The audited ambulance build was configured with inventory wiping disabled and a normal hospital bill taken from bank. The patch also removes the old direct-SQL inventory wipe path so enabling a future respawn wipe does not silently bypass qb-inventory.

## rs-lilhudlife note

`rs-lilhudlife` is display/synchronization only in this workflow. It does not own cash and should not be used as the authority for adding/removing money.

If the HUD and inventory both change together, that usually means the underlying authoritative money/inventory operation succeeded. Investigate the calling resource, not the HUD.

## Troubleshooting

Keep tracing enabled while integrating new death/zombie/medical resources:

```cfg
set qb_death_cash_trace 1
```

A blocked attempt prints:

- player source
- attempted amount
- reason string
- invoking resource when FiveM exposes it
- Lua call trace

Example:

```text
[qb-core][death-cash-guard] BLOCKED cash removal while dead | src=1 amount=1000 reason=zombie-death-loss invoking=RealitySucks_ZombieHubs
```

That line is the first place to look when a server owner reports that cash disappears at death.

## Compatibility principle

**Cash-As-Item changes the meaning of framework cash operations.**

Once enabled, all resources that call QBCore cash functions must be treated as inventory-integrated code. A death penalty that used to modify only `PlayerData.money.cash` can now remove the real `cash` item. Review those integrations before release rather than treating the HUD, inventory, medical script, and death script as isolated systems.


## RS Punk v3.0.4 note

This Punk edition and the sibling Zombie-art edition use the same client/server inventory brain for the protected code paths. The v3.0.4 hardening was therefore applied to the shared backend logic without changing the Punk NUI artwork, images, fonts, layout, or menu theme.

`Config.CashItemName = 'cash'` is now the single currency item name used by the death/respawn safeguards in this build. If your framework uses a differently named physical currency item, change that setting and the corresponding framework/shared-item definition together.

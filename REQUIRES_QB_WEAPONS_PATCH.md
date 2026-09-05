# REQUIRED: 3 companion edits in `qb-weapons`

**This inventory alone is not enough.** The weapon-attachment fixes in
`qb-inventory` v2.6.0+ (RS Zombie / APCode variant) depend on three small edits
inside the **separate `qb-weapons` resource**. Those files are NOT shipped in
this folder, because overwriting someone else's `qb-weapons` would wipe their
own weapon config.

If you install this inventory without applying the edits below:

- Attachments bought as part of a weapon-shop build **display correctly** in the
  Weapon Inspection panel...
- ...but **clicking one to detach it silently fails and does nothing.**
- Attachment items used from the inventory **do not appear on the gun** until you
  re-equip (holster + draw) the weapon.
- On some forks, equipping a shop-built weapon can throw a Lua error on
  `joaat()`.

Applies to: `qb-inventory` **2.6.0-rs-zombie-rework-open-source and later**
(including the 2.6.1 drop-sync baseline). Edit target: **`qb-weapons`**, any
recent QBCore version. Roughly 40 lines total, all copy-paste.

---

## Why this is needed (the actual bug)

Two resources describe the same attachment in two different formats:

| Source | Stores `component` as | Example |
|---|---|---|
| `rs-weaponshops` (and most weapon shops) | component **NAME string** | `'COMPONENT_AT_PI_SUPP_02'` |
| `qb-weapons/config.lua` `WeaponAttachments` | component **HASH number** (backtick literal) | `` `COMPONENT_AT_PI_SUPP_02` `` |

Stock `qb-weapons` compares those two with `==`. A string **never** equals a
number in Lua, so the lookup always failed and detaching a shop-bought
attachment did nothing at all - no error, no notification, no change.

The fix is to normalize both sides to a hash before comparing.

---

## Edit 1 of 3 - `qb-weapons/server/main.lua`

**Fixes:** detaching a shop-bought attachment does nothing.

Near the top of the file, in the `-- Helpers --` section, FIND the
`HasAttachment` function (usually around line 24). It appears in one of two
forms depending on your qb-weapons version - **both have the same bug**:

**Form A - stock QBCore qb-weapons:**

```lua
local function HasAttachment(component, attachments)
    for k, v in pairs(attachments) do
        if v.component == component then
            return true, k
        end
    end
    return false, nil
end
```

**Form B - nil-safe variant used by some forks:**

```lua
local function HasAttachment(component, attachments)
    for k, v in pairs(attachments or {}) do
        if (v.component or v) == component then
            return true, k
        end
    end
    return false, nil
end
```

REPLACE whichever form you have with this (adds one new helper above it):

```lua
-- Attachment metadata can store components as hash numbers (this resource) or as
-- component name strings (weapon shops like rs-weaponshops). Normalize both sides
-- to hashes so lookups work no matter which resource wrote the metadata.
local function ComponentToHash(component)
    if type(component) == 'number' then return component end
    if type(component) == 'string' and component ~= '' then
        return tonumber(component) or joaat(component)
    end
    return nil
end

local function HasAttachment(component, attachments)
    local target = ComponentToHash(component)
    if not target then return false, nil end
    for k, v in pairs(attachments or {}) do
        local current = ComponentToHash(type(v) == 'table' and v.component or v)
        if current and current == target then
            return true, k
        end
    end
    return false, nil
end
```

> If your copy matches neither form exactly, match on the **function name** and
> replace the entire function. The replacement above is self-contained and does
> not depend on the original body.

---

## Edit 2 of 3 - `qb-weapons/client/main.lua`

**Fixes:** shop-built weapons erroring / not showing attachments on equip.

Inside `RegisterNetEvent('qb-weapons:client:UseWeapon', ...)` (usually around
line 157), FIND:

```lua
        if weaponData.info.attachments then
            for _, attachment in pairs(weaponData.info.attachments) do
                GiveWeaponComponentToPed(ped, weaponHash, joaat(attachment.component or attachment))
            end
        end
```

REPLACE with:

```lua
        if weaponData.info.attachments then
            for _, attachment in pairs(weaponData.info.attachments) do
                -- Metadata may hold a hash number (this resource) or a component name
                -- string (weapon shops); joaat only accepts strings.
                local component = type(attachment) == 'table' and attachment.component or attachment
                if type(component) == 'string' and component ~= '' then
                    component = tonumber(component) or joaat(component)
                end
                if type(component) == 'number' then
                    GiveWeaponComponentToPed(ped, weaponHash, component)
                end
            end
        end
```

---

## Edit 3 of 3 - `qb-weapons/client/main.lua`

**Fixes:** attachment doesn't show on the gun until you re-equip it.

`qb-weapons/server/main.lua` already fires `qb-weapons:client:applyComponentNow`
and `qb-weapons:client:removeComponentNow` when an attachment item is used or
toggled - but **no client handler for either event exists**, so both events go
nowhere. Add them.

Paste this block into `qb-weapons/client/main.lua` immediately AFTER the
`qb-weapons:client:CheckWeapon` event handler (which ends with `end)` around
line 186), and BEFORE the `-- Threads` comment:

```lua
-- Server fires these when an attachment item is used/toggled so the component
-- shows on the held weapon immediately instead of waiting for a re-equip.
local function ResolveComponentHash(component)
    if type(component) == 'table' then component = component.component end
    if type(component) == 'number' then return component end
    if type(component) == 'string' and component ~= '' then
        return tonumber(component) or joaat(component)
    end
    return nil
end

RegisterNetEvent('qb-weapons:client:applyComponentNow', function(weaponName, component)
    local ped = PlayerPedId()
    local weaponHash = joaat(weaponName)
    local componentHash = ResolveComponentHash(component)
    if not componentHash or not HasPedGotWeapon(ped, weaponHash, false) then return end
    GiveWeaponComponentToPed(ped, weaponHash, componentHash)
end)

RegisterNetEvent('qb-weapons:client:removeComponentNow', function(weaponName, component)
    local ped = PlayerPedId()
    local weaponHash = joaat(weaponName)
    local componentHash = ResolveComponentHash(component)
    if not componentHash or not HasPedGotWeapon(ped, weaponHash, false) then return end
    RemoveWeaponComponentFromPed(ped, weaponHash, componentHash)
end)
```

> Placement is flexible - anywhere at file top level works. Do NOT paste it
> inside another function.

---

## Install

1. Back up `qb-weapons/server/main.lua` and `qb-weapons/client/main.lua`.
2. Apply Edits 1-3 above.
3. Restart **both** resources:

```
restart qb-weapons
```

```
restart qb-inventory
```

For the first validation pass, prefer a **full server restart** over a live
`restart`, so both clients and server reload the event handlers together.

---

## Verify it worked

1. Buy a prebuilt weapon **with attachments** from the weapon shop.
2. Open inventory, right-click the weapon, choose **Attachments**.
3. Attachments appear with their real item images. *(This part works even
   WITHOUT the qb-weapons edits - do not stop here.)*
4. **Click a filled slot.** The attachment must disappear from the panel AND the
   attachment item must land back in your inventory. **This is the part that only
   works once Edit 1 is applied.**
5. Equip the weapon - the attachment is visible on the model.
6. Use a standalone attachment item while holding a compatible weapon - it
   should appear on the gun **instantly**, with no holster/re-draw. *(Edit 3.)*

Console check - after clicking a filled slot, you should NOT see:

```
[qb-inventory] RemoveAttachment blocked: no component for ...
```

---

## Notes / gotchas

- **Escrowed or encrypted `qb-weapons`:** if `server/main.lua` or
  `client/main.lua` is not editable, these edits cannot be applied and shop-built
  attachments will remain non-detachable. There is no inventory-side workaround  - 
  the comparison bug lives in `qb-weapons`.
- **Heavily modified forks:** apply by function/event name rather than exact
  text match.
- **Reapply after updating `qb-weapons`.** An update will overwrite these edits.
- These edits are **backward compatible.** Attachments saved the old way (hash
  numbers) keep working exactly as before - normalization accepts both formats.
- Nothing here changes `qb-weapons/config.lua`, your `WeaponAttachments` table,
  weapon list, durability, tints, or repair logic.

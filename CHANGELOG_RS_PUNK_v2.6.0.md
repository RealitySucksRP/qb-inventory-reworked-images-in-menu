# qb-inventory-punk v2.6.0 - Crisp Text, Real Stacking, Shop-Build Attachments

Same three fixes as the RS Zombie inventory, ported to the punk (cyan/magenta
holographic) UI. Restart BOTH `qb-inventory-punk` and `qb-weapons` in-game.

## Items stack now
- New config option `Config.StackWithDifferentExpiry = true` (config/config.lua):
  non-unique items always stack by name, even when freshness/expiry differs.
  Merged stacks keep the EARLIER expiry so stacking can never extend an item's
  life. Set it to `false` to restore old exact-expiry-match behavior.
- Applies everywhere: server AddItem (shop buys, loot, gives), drag-merge in the
  same inventory, and drag-merge across inventories (stash/drop/player). The NUI
  mirrors the same rule so client prediction matches the server.
- Cross-inventory stack merges now carry the moving item's metadata instead of
  duplicating the target's.

## Weapon attachments read "as they come" (rs-weaponshops prebuilt builds)
- Weapon Inspection now trusts shop metadata directly: if `info.attachments`
  entries name a real shared item (rs-weaponshops saves item/attachment/label/
  component), the attachment shows even when qb-weapons has no mapping.
- Attachment slots use the item's real inventory image, not a guessed `<key>.png`.
- Smarter slot detection (key + label): compensators/silencers -> Muzzle, thermal
  scopes -> Optics, luxury finishes -> Skin/Tint, etc.
- New "Other Attachments" overflow section: anything that does not fit the six
  standard slots (heavy barrels, exotic shop items) is still visible/removable.
- Weapon Inspection shows the installed weapon tint (uses the shop's tint label).
- Panel scrolls instead of clipping on short screens.
- Fixed a nil-field bug that could stop attachment key matching early, and gated
  the ped-scan fallback so GTA's built-in default clip no longer shows as a
  phantom attachment.

## Blurry text
- The punk UI does NOT downscale the whole menu with transform:scale, so it was
  already free of the main rasterization blur. For maximum crispness this patch
  switches `text-rendering: geometricPrecision` (soft edges) to
  `optimizeLegibility` across the menu.
- Drag ghost is now zoom-aware for parity (no effect at the punk UI's 1:1 scale).

## qb-weapons companion fixes (shared qb-weapons resource - already applied)
- `HasAttachment` hash-normalizes components, so DETACHING attachments bought as
  part of a weapon-shop build works (shop metadata stores component NAME strings;
  qb-weapons config stores hash NUMBERS - they never matched before).
- Equipping a weapon applies attachments saved as either name strings or hash
  numbers without erroring.
- Added the missing `qb-weapons:client:applyComponentNow`/`removeComponentNow`
  handlers, so using/toggling an attachment item shows on the held weapon
  instantly instead of after a re-equip.

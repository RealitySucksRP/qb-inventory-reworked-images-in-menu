# RS Punk qb-inventory v3.0.2

This build ports the functional/security updates from the supplied `qb-inventory-zombie` v3.0.2 resource into the supplied RS Punk build while preserving the Punk menu artwork and base layout.

## 3.0.2 / 3.0.1 updates carried over

- Server-authoritative inventory sessions are loaded and enforced.
- Player-only close requests now clear `inv_busy` correctly without producing false `close-no-session` blocks.
- Named secondary inventory closes remain session/mismatch protected.
- Inventory snapshot refreshes require the active server session before secondary inventory data is returned.
- Client-callable snowball grant/removal event removed.
- Floor-drop bootstrap exposes network entity ids only; contents/internal state stay server-side.
- Give-item requests resolve item name, amount bounds, slot and metadata from the real server inventory slot.
- Shop purchases require the active server shop session and validated positive integer slot/amount values.
- Cross-inventory swaps compensate partial failures so items are restored rather than silently lost.
- Public AddItem/RemoveItem inputs are validated; explicit AddItem slots cannot overwrite occupied slots.
- Player-search locks are acquired for both participants, closing the two-searcher race window.
- Disconnect/resource-stop cleanup releases stale search locks, sessions and `inv_busy` state.
- ID-card and driver-license displays use authoritative server-side metadata.
- Shop, stash and floor-drop opens consistently acquire the server busy/session lock.
- Resource-start method registration uses actual QBCore server player ids.

## 3.0.0 hardening carried over

- Client moves are restricted to the inventory the server says that player has open, with distance revalidation on every move.
- Client-originated legacy `inventory:server:OpenInventory` calls are blocked by default.
- Robbery uses a single-use expiring server token and validates the hands-up responder.
- Drop pickup/movement is server-validated and carrier-bound.
- AddItem/RemoveItem amounts are floored/validated and reject malformed values.
- `closeInventory` is type-checked and scoped to the caller's live session.
- Vending shops are server-positioned and player-scoped.
- Trunk/glovebox requests now include a vehicle network id and the server verifies the real vehicle/plate/proximity.
- qb-target startup waits on resource state and player search uses `AddGlobalPlayer`.
- `qb-target` is now a declared dependency.
- Save/diagnostic logging is debug-gated.
- Bag carry polling sleeps while no bag is being held.

## Existing 2.6.x features retained

- Cash-as-item synchronization remains ENABLED in this Punk build, matching the supplied Punk config.
- Existing RS custom HUD integration remains ENABLED, matching the supplied Punk config.
- Drop reconciliation/idempotency, server snapshots and failed-bag refunds remain present.
- Expiry-aware stacking and earlier-expiry merge behavior remain present.
- Weapon inspection supports shop metadata, attachment overflow and real item images.
- Cash values remain currency-formatted in NUI.

## NUI functional updates

- Added the newer explicit drop confirmation/amount dialog using Punk theme variables.
- Hardened item notification handling for malformed/missing item payloads.
- Serial copy accepts both `serie` and `serial` metadata keys.
- Browser JS/runtime libraries are bundled locally; the Punk UI body, artwork files and theme CSS remain the base UI.
- Preserved the Punk build's more defensive server-time fallback for decay/expiry display.

## Deliberately preserved from RS Punk

- `Config.CashAsItem = true`
- `Config.CustomHUD.Enabled = true`
- Punk `config/vehicles.lua` capacity values (the zombie sample's active Zentorno/Tigon example overrides were NOT imported).
- Punk menu artwork, top-level art PNGs, item images and existing base layout/theme.

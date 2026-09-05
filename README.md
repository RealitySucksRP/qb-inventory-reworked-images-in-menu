<p align="center">
  <img src="images/punk.png" alt="RS Punk Inventory Preview" width="100%">
</p>

<p align="center">
  <a href="https://ko-fi.com/R6R51XYJ6N">Support RealitySucksRP on Ko-fi</a> ·
  <a href="https://reality-sucks-rp-webstore.tebex.io/">RealitySucksRP Tebex Store</a>
</p>

# RealitySucksRP qb-inventory — Punk Edition

## Upstream project and credit

This repository is a **modified derivative** of [Anya Project / AP Code — `qb-inventory-rework`](https://github.com/anya-project/qb-inventory-rework).

The Anya Project/AP Code contributors are credited for the upstream inventory rework and its original feature work. RealitySucksRP maintains this Punk edition with its custom UI/art direction, synchronization and security hardening, compatibility work, and edition-specific changes.

This modified edition remains licensed under **GPL-3.0**. The upstream project and license notices must be preserved when redistributing modified copies.

**RealitySucksRP modification notice updated:** September 4, 2026.

---

### A modern, aggressive inventory built for serious FiveM roleplay

I rebuilt the traditional inventory experience into something that feels more modern, more visual, and better suited for today’s RP servers.

**RS Punk Inventory** combines a neon cyber-punk presentation with a hardened server-authoritative inventory system designed around real gameplay: cash, weapons, floor drops, vehicle storage, item transfers, and fast day-to-day RP interactions.

The interface is designed to look like part of the game rather than a plain utility menu, while the backend focuses heavily on keeping inventory state accurate between the player, server, HUD, and other resources.

## Physical Cash That Actually Works

Cash can exist as a real inventory item while remaining synchronized with the player’s actual spending power.

That means when cash is given, earned, spent, dropped, picked up, or changed through QBCore money functions, the cash item, HUD balance, and server-side buying power stay together.

## Hardened Floor Drop System

Floor drops use authoritative server inventory snapshots instead of trusting the browser to guess what happened. This helps reduce ghost items, duplicated visual stacks, failed move states, and item-loss conditions.

## Features

- Neon cyber-punk inventory interface
- Physical cash item support
- Live cash/HUD synchronization
- Server-authoritative cash state
- Currency formatting for large cash stacks
- Weapons and weapon metadata
- Floor item drops
- Glovebox and vehicle storage interaction
- Player-to-player item transfers
- Stack splitting and merging
- Inventory weight and slot limits
- Hotbar support
- Server-authoritative move reconciliation
- Duplicate floor-drop protection
- Failed-drop item refunds
- Automatic inventory-state recovery
- Compatibility support for existing qb-inventory-style integrations

## Custom Menu UI

The UI includes customizable image slots, server branding, background art, watermark images, size/position controls, opacity, and colors.

Most visual edits are done in:

```text
html/main.css
html/index.html
html/images/
html/*.png
```

## Requirements

- FiveM
- QBCore / `qb-core`
- `qb-weapons`
- `oxmysql`
- Properly configured QBCore items

## Installation

1. Back up your existing inventory and player data.
2. Place the resource inside your server resources folder.
3. Keep the resource folder named `qb-inventory`.
4. Start dependencies first.
5. Configure cash, HUD, item, and inventory options.
6. Restart the server.

## Credits

- Original QB Inventory foundation: QBCore Framework project
- Upstream rework: [Anya Project / AP Code — qb-inventory-rework](https://github.com/anya-project/qb-inventory-rework)
- Punk UI, RealitySucksRP styling, additional synchronization/security hardening, integrations, and release packaging: **RealitySucksRP**

## License

This repository remains under the **GNU General Public License v3.0 (GPL-3.0)** in accordance with the upstream project. See `LICENSE` and `UPSTREAM_ATTRIBUTION.md`.

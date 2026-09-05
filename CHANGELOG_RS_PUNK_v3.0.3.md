# RS Punk qb-inventory v3.0.3

Structural and NUI asset correction pass for the v3.0.2 Zombie-to-Punk merge.

## Fixed

- Corrected the distribution so `server/cash_sync.lua` is present alongside the manifest that loads it.
- Corrected the distribution so `config/vehicles.lua` is present alongside the manifest that loads it.
- Added the real Zombie v3.0.2 `html/images/missing.png` runtime fallback image.
- Reworked three Vue image bindings so static asset validators do not mistake runtime expressions (`notificationImage` and attachment-image functions) for literal filenames.
- Kept the same runtime notification and attachment-image behavior, including fallback-on-error.
- Bumped the manifest resource version to `3.0.3-rs-punk`.

## Preserved

- All v3.0.2 server-authoritative/session/security/transfer/drop/shop/vehicle updates remain intact.
- `Config.CashAsItem = true` remains unchanged.
- `Config.CustomHUD.Enabled = true` remains unchanged.
- Punk vehicle-capacity config remains unchanged.
- The original Punk visual payload is unchanged: 3,081 supplied image/font/SVG assets hash-identically to the original Punk ZIP. The only added image is the functional `images/missing.png` fallback from the Zombie build.

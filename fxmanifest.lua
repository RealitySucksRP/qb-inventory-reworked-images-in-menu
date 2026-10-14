fx_version 'cerulean'
game 'gta5'

author 'Kakarot / RealitySucksRP'
description 'RS Punk UI qb-inventory with QBCore production guards, server-authoritative sessions, cash-as-item support, weapon attachments, drops, and HUD compatibility.'
version '3.0.5-rs-punk-production-guard'

dependencies {
    '/onesync',
    'qb-core',
    'qb-weapons',
    'oxmysql',
    'qb-target'
}

shared_scripts {
    '@qb-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config/config.lua',
    'config/vehicles.lua'
}

client_scripts {
    'client/main.lua',
    'client/drops.lua',
    'client/vehicles.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/sessions.lua',
    'server/main.lua',
    'server/functions.lua',
    'server/cash_sync.lua',
    'server/commands.lua',
    'server/compat.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/main.css',
    'html/app.js',

    -- All browser runtime dependencies are local. No CDN is required by the active UI.
    'html/vendor/*.js',
    'html/vendor/*.css',
    'html/vendor/fontawesome/css/*.css',
    'html/vendor/fontawesome/webfonts/*.woff2',

    -- Preserve the RS Punk UI artwork/theme exactly as supplied.
    'html/*.png',
    'html/dark/*.png',
    'html/dark/*.svg',
    'html/font/*.ttf',

    -- Item art formats actually present in this package. Keep this explicit so
    -- non-runtime files inside html/images are not packed by the resource.
    'html/images/*.png',
    'html/images/*.PNG',
    'html/images/*.webp'
}

exports {
    'HasItem'
}

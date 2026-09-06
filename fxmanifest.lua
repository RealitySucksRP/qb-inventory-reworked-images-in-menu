fx_version 'cerulean'
game 'gta5'

author 'Kakarot / RealitySucksRP'
description 'RS Punk UI qb-inventory with 3.0.4 death-cash protection, 3.0.3 structural fixes, server-authoritative sessions, hardened transfers, cash-as-item support, weapon attachments, drops, and HUD compatibility.'
version '3.0.4-rs-punk'

dependencies {
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

    -- Local runtime dependencies from the 3.0.2 update.
    'html/vendor/*.js',
    'html/vendor/*.css',
    'html/vendor/fontawesome/css/*.css',
    'html/vendor/fontawesome/webfonts/*.woff2',

    -- Preserve the RS Punk UI artwork/theme exactly as supplied.
    'html/*.png',
    'html/images/*.*',
    'html/dark/*.png',
    'html/dark/*.svg',
    'html/font/*.ttf',
    'html/font/*.otf'
}

exports {
    'HasItem'
}

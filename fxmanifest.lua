fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Kakarot / RealitySucksRP'
description 'Player inventory system providing a variety of features for storing and managing items'

dependencies {
    'qb-core',
    'qb-weapons',
    'oxmysql'
}

shared_scripts {
    '@qb-core/shared/locale.lua',
    'locales/en.lua',
    'locales/*.lua',
    'config/*.lua'
}

client_scripts {
    'client/main.lua',
    'client/drops.lua',
    'client/vehicles.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
    'server/functions.lua',
    'server/commands.lua',
    'server/compat.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/main.css',
    'html/app.js',

    'html/*.png',

    'html/images/*.*',
    'html/images/*.png',
    'html/images/*.jpg',
    'html/images/*.jpeg',
    'html/images/*.webp',
    'html/images/*.gif',
    'html/images/*.svg',

    'html/dark/*.png',
    'html/dark/*.svg',

    'html/font/*.ttf',
    'html/font/*.otf'
}

exports {
    'HasItem'
}
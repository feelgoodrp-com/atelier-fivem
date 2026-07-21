fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'atelier-fivem'
author 'feelgood'
description 'In-game viewer for clothing packs built with atelier'
version '0.1.0'
repository 'https://github.com/feelgoodrp-com/atelier-fivem'

-- NO dependencies on purpose. This resource is standalone-first; ESX, qb-core
-- and qbox are detected at RUNTIME (see framework/resolve.lua). Declaring a
-- dependency here would refuse to start the resource on every other setup —
-- exactly the trap that makes some scripts qbox-only, because qbx_core happens
-- to `provide 'qb-core'`.

shared_script 'config.lua'

client_scripts {
    'framework/resolve.lua',
    'client/discovery.lua',
    'client/indexmap.lua',
    'client/scene.lua',
    'client/apply.lua',
    'client/probe.lua',
    'client/main.lua',
}

server_scripts {
    'framework/resolve.lua',
    'server/main.lua',
}

ui_page 'web/dist/index.html'

-- Listed by hand, no globs: the build writes fixed names (see web/vite.config.ts).
files {
    'web/dist/index.html',
    'web/dist/assets/index.js',
    'web/dist/assets/index.css',
    -- Unlisted = 404 in game, and the brand row silently loses its logo.
    'web/dist/atelier-logo.png',
}

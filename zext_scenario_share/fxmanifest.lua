fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'zext_scenario_share'
author 'Zext'
description 'Scenario Share: copy WHIP Director scenarios between servers as codes (WDS1. long codes, ZX- short codes). /scenarioshare for Director builders. No edits to whip_core.'
version '2.0.0'
repository 'https://github.com/ZextEU/zext-scenario-share'

dependency 'whip_core'

ui_page 'html/index.html'
files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
}

shared_scripts {
    '@whip_core/lib/satellite.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/codec.lua',
    'server/main.lua',
}

client_scripts {
    'client/main.lua',
}

-- Short codes are looked up here; set it to "" to turn short codes off (long codes always work):
--   set zext_share_hub "https://zext-scenario-hub.whipshare.workers.dev"

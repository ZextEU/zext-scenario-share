-- ============================================
-- /whip SECTION — Director (client wiring)
-- ============================================
--
-- The page half is html/js/wp/director.js (the Lore characters page: wp/lore.js). Every request it makes is one of the hub's callbacks
-- (server/director/hub.lua), forwarded here by name with only the arguments that op takes, in order;
-- the server gates each by the Director permissions (a builder's, or a Director admin's).
-- Edit leaves the panel for the world builder on that scenario (client/director.lua DirectorOpenAt).

-- The Director's group: one section per page (wp/director.js PAGES), each asking for what it shows itself.
for _, id in ipairs({ 'director', 'directorLive', 'directorScenarios', 'directorLore', 'directorShipped', 'directorRuns',
                      'directorAccess' }) do
    PanelSections[id] = { enter = function() end, leave = function() end }
end

local OPS = {
    list       = {},
    overview   = { 'days', 'scope', 'value' },   -- scope: all, scenario, lore or maker, and which (value)
    create     = { 'key', 'name', 'from' },
    startRun   = { 'key' },
    lore       = {},
    loreSave   = { 'key', 'name', 'model', 'bankName', 'notes', 'picture', 'frameX', 'frameY', 'frameZ', 'voice' },
    loreRetire = { 'key' },
    loreVoiceTest = { 'key', 'url' },   -- a voice line played at the builder (server/director/lore_voice.lua)
    loreActivity = { 'key' },           -- the Lore page's Interactions: scenarios, phone, payments (director/lore.lua)
    loreTest   = { 'key', 'mode' },     -- test mode: their NPC in front of the builder (director/lore_voice.lua)
    loreTestSay = { 'url', 'text' },    -- ...and a variant said by it
    loreProps  = { 'key', 'hat', 'hatTexture' },   -- their hat (director/lore.lua): -1 for none
    loreLook   = { 'key', 'look', 'image' },       -- 'none': their look made in the character editor taken away
    players    = { 'key' },
    runs       = { 'key', 'before' },
    events     = { 'key', 'runId', 'before' },
    history    = { 'key' },
    places     = { 'key' },   -- the Scenarios page's map, and who made it
    takePath   = { 'key', 'take' },   -- a car's take, drawn on that map when the car is clicked
    restore    = { 'key', 'rev' },
    activate   = { 'key', 'rev', 'endRuns' },
    deactivate = { 'key', 'endRuns' },
    delete     = { 'key' },
    abort      = { 'runId' },
    export     = { 'key', 'rev' },
    shareDoc   = { 'key', 'rev' },   -- PROJECT Z PATCH: a scenario as a share code (Import: wpDirectorImport below)
    packs      = {},
    accept     = { 'resource', 'file' },
    refuse     = { 'resource', 'file' },
    trust      = { 'resource', 'on' },   -- the Director API: a resource's scenarios accepted by themselves
    access     = {},
    grant      = { 'charId', 'level' },
    revoke     = { 'userId', 'level' },
    -- The Dungeon Mode page (server/director/live.lua): what is up, removing one, clearing mine (or, an admin's, everyone's),
    -- and one effect off.
    liveList   = {},
    liveRemove = { 'id' },
    liveClear  = { 'all' },
    liveFxOff  = { 'key' },
}

RegisterNUICallback('wpDirector', function(d, cb)
    local op = type(d) == 'table' and d.op or nil
    local names = type(op) == 'string' and OPS[op] or nil
    if not names then cb({ ok = false, why = 'unknown request' }) return end
    local args = type(d.args) == 'table' and d.args or {}
    local list = {}
    for i, name in ipairs(names) do list[i] = args[name] end
    local res, why = Callback('whip_core:director:' .. op, table.unpack(list, 1, #names))
    if res == nil or res == false then
        cb({ ok = false, why = why or 'No answer from the server' })
    else
        cb({ ok = true, data = res })
    end
end)

-- PROJECT Z PATCH: Import code (wp/director.js). The page unpacks the code into a document; it goes up as a
-- latent event, as the editor's Save does (big documents get lost as plain events), and the hub makes a new
-- draft from it (server/director/hub.lua importCode). Its tokens start high so they never meet the editor's.
local importToken = 900000000
RegisterNUICallback('wpDirectorImport', function(d, cb)
    if type(d) ~= 'table' or type(d.doc) ~= 'table' or type(d.key) ~= 'string' or type(d.name) ~= 'string' then
        cb({ ok = false, why = 'Nothing to import' }) return
    end
    importToken = importToken + 1
    TriggerLatentServerEvent('whip_core:server:directorDoc', 500000, importToken, d.doc)
    local res, why = Callback('whip_core:director:importCode', d.key, d.name, importToken)
    if res == nil or res == false then cb({ ok = false, why = why or 'No answer from the server' })
    else cb({ ok = true, data = res }) end
end)

-- Into the world builder on a scenario (`key`).
RegisterNUICallback('wpDirectorEdit', function(d, cb)
    cb('ok')
    local key = type(d) == 'table' and type(d.key) == 'string' and d.key or nil
    if key and DirectorOpenAt then DirectorOpenAt(key) end
end)

-- Start Dungeon Mode: the panel closes and the world builder opens on the live world (client/director_live.lua).
-- Answers { ok } or { ok = false, why }; the server gates everything it does (director.live).
RegisterNUICallback('wpDirectorLive', function(_, cb)
    if not DirectorLive then cb({ ok = false, why = 'Dungeon Mode is not here' }) return end
    if WhipPanelIsOpen and WhipPanelIsOpen() then WhipPanelClose() end
    CreateThread(function()
        Wait(0)   -- (the panel's focus let go first)
        local ok, why = DirectorLive.open()
        if not ok then UI.Notify(why or 'Dungeon Mode could not open', 'error') end
    end)
    cb({ ok = true })
end)

-- A lore character's look in the character editor (wp/lore.js: Male or Female makes a new one, Edit look the one
-- they have). The panel closes, the builder wears the look while making it (client/appearance.lua EditLook), and
-- Save keeps it with the headshot taken of it (server/director/lore.lua). Back on the Lore page either way.
-- Answers { ok } at once, or { ok = false, why } when the editor cannot open now (a gun drawn, in a car).
RegisterNUICallback('wpLoreLook', function(d, cb)
    d = type(d) == 'table' and d or {}
    local key = type(d.key) == 'string' and d.key or nil
    local gender = (d.gender == 'male' or d.gender == 'female') and d.gender or nil
    local name = type(d.name) == 'string' and d.name ~= '' and d.name:sub(1, 80) or key
    if not key then cb({ ok = false, why = 'Which lore character?' }) return end
    local why = LookEditProblem and LookEditProblem() or (not EditLook and 'The character editor is not here') or nil
    if why then cb({ ok = false, why = why }) return end
    cb({ ok = true })
    CreateThread(function()
        local look
        if not gender then
            local r = Callback('whip_core:loreLook', key)
            look = type(r) == 'table' and type(r.look) == 'table' and r.look or nil
            if not look then WhipPanelResult('Their look could not be read', 'err') return end
        end
        WhipPanelClose()
        local function back(text, kind)
            if PlayerIsDead then return end   -- a death closed the editor: no panel over the death screen
            WhipPanelOpen('directorLore')
            if text then WhipPanelResult(text, kind) end
        end
        local ok, ewhy = EditLook({ appearance = look, gender = gender, title = name, sub = 'Lore character',
            done = function(made, headshot)
                if not made then back() return end
                local res, swhy = Callback('whip_core:director:loreLook', key, made, headshot or '')
                if not res then back('Their look was not saved: ' .. tostring(swhy or 'no answer from the server'), 'err')
                elseif res.portrait then back('Their look is saved, and their portrait with it', 'ok')
                else back('Their look is saved, but their portrait could not be taken', 'err') end
            end })
        if not ok then back(ewhy, 'err') end
    end)
end)

-- Copy my look (wp/lore.js): the builder's character as they are now becomes the lore character's look, with a
-- headshot of them for its portrait. Nothing changes for the builder. Answers { ok, portrait } or { ok = false, why }.
RegisterNUICallback('wpLoreCopyLook', function(d, cb)
    local key = type(d) == 'table' and type(d.key) == 'string' and d.key or nil
    if not key then cb({ ok = false, why = 'Which lore character?' }) return end
    if not CurrentAppearance then cb({ ok = false, why = 'Your look cannot be read here' }) return end
    local look, why = CurrentAppearance()
    if not look then cb({ ok = false, why = why }) return end
    local headshot = TakeHeadshot and TakeHeadshot(PlayerPedId()) or nil
    local res, swhy = Callback('whip_core:director:loreLook', key, look, headshot or '')
    if not res then cb({ ok = false, why = swhy or 'No answer from the server' }) return end
    cb({ ok = true, portrait = res.portrait == true })
end)

-- Lore characters' headshots for any page that shows their faces (html/js/lore-faces.js: the Lore page, the
-- Director's pickers, the world builder, the maps): { ok, portraits = { [key] = dataUrl } }.
RegisterNUICallback('lorePortraits', function(d, cb)
    local keys = type(d) == 'table' and type(d.keys) == 'table' and d.keys or {}
    local res = Callback('whip_core:director:lorePortraits', keys)
    if type(res) == 'table' then cb({ ok = true, portraits = res.portraits or {} }) else cb({ ok = false }) end
end)

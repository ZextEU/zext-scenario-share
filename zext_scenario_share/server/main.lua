-- Scenario Share: Director scenarios as codes, as a resource of its own (no edits to whip_core).
--
-- Share:  a scenario's newest revision (or one named) becomes a code. The screen deflates it into "WDS1.";
--         scripts get "WDS0." (GetScenarioShareCode). Either works on any WHIP server: nothing is hosted.
-- Import: a code becomes a Director TEMPLATE ("Imported: <name>" in the editor's New list). A builder's copy of
--         it is an ordinary draft scenario, switched off, that they check and edit before switching it on.
--         Imports are kept in this resource's own table and offered again whenever whip_core starts.
--
-- Who: Director builders (WHIP permission director.build; full admins hold it too).
--
-- Reading a scenario: whip_core has no export that hands out a whole scenario document (GetScenario is a
-- summary), so Share reads the Director's own tables, read-only: director_scenarios + director_revisions.
-- If whip_core adds such an export, use it here instead.

local PERM = 'director.build'
local TABLE = 'zext_scenario_share_imports'
local PART_MAX = 7000          -- characters in one piece of an upload (the client splits a code into these)
local PARTS_MAX = 160          -- 160 x 7000 = 1.1 M characters: more than any 512 KB scenario needs
local NAME_MAX = 60            -- a Director template's name

local imports = {}             -- [name] = { id, name, doc, by, at }
local ready = false

local function say(fmt, ...) print(('[zext_scenario_share] ' .. fmt):format(...)) end

local function trim(s) return type(s) == 'string' and s:gsub('^%s+', ''):gsub('%s+$', '') or '' end

-- ============================================
-- Templates
-- ============================================

--- Offer one import in the Director's New list. Answers true, or false and why.
local function offer(name, doc)
    local ok, why = Whip.call('__RegisterDirectorTemplate', name, doc)
    if ok ~= true then return false, tostring(why or 'The Director did not take it') end
    return true
end

--- A name not used by another import: "Courier", "Courier (2)", ...
local function freeName(want)
    want = trim(want)
    if want == '' then want = 'Imported scenario' end
    want = want:sub(1, NAME_MAX)
    if not imports[want] then return want end
    for i = 2, 99 do
        local tail = (' (%d)'):format(i)
        local n = want:sub(1, NAME_MAX - #tail) .. tail
        if not imports[n] then return n end
    end
    return nil
end

--- What Check says is wrong with it, as short lines (at most 6): the builder fixes these in the editor.
local function problemsOf(doc)
    local passes, problems = Whip.core:CheckDirectorScenario(doc)
    local out = {}
    if passes == true or type(problems) ~= 'table' then return out end
    for _, p in ipairs(problems) do
        if type(p) == 'table' and p.severity == 'error' and type(p.message) == 'string' then
            out[#out + 1] = p.message
            if #out >= 6 then break end
        end
    end
    return out
end

--- Make an import of a document: a template, kept in our table. Answers { name, problems }, or false and why.
---@param doc table
---@param wantName string|nil
---@param by { charId: number|nil, label: string }
local function importDoc(doc, wantName, by)
    if not ready then return false, 'Scenario Share is still starting: try again in a moment' end
    if type(doc) ~= 'table' or type(doc.nodes) ~= 'table' then return false, 'That is not a scenario (it has no cards)' end
    local name = freeName(trim(wantName) ~= '' and wantName or doc.name)
    if not name then return false, 'Too many imports share that name: pick another' end
    doc.id, doc.rev, doc.key, doc.requires = nil, nil, nil, nil
    doc.name = name
    local okText, text = pcall(json.encode, doc)
    if not okText or type(text) ~= 'string' then return false, 'That scenario cannot be written down' end
    if #text > Codec.MAX_BYTES then return false, 'That scenario is too big' end
    local problems = problemsOf(doc)
    local ok, why = offer(name, doc)
    if not ok then return false, 'The Director refused it: ' .. why end
    local id = MySQL.insert.await(('INSERT INTO `%s` (`name`, `doc`, `importedBy`, `importedByName`) VALUES (?, ?, ?, ?)'):format(TABLE),
        { name, text, by.charId, by.label:sub(1, 80) })
    if not id then
        Whip.call('RemoveDirectorTemplate', name)
        return false, 'It could not be saved (database)'
    end
    imports[name] = { id = id, name = name, doc = doc, by = by.label, at = os.time() }
    say('%s imported "%s" (a Director template)', by.label, name)
    return { name = name, problems = problems }
end

local function removeImport(name, byLabel)
    local it = imports[name]
    if not it then return false, 'No import called ' .. tostring(name) end
    Whip.call('RemoveDirectorTemplate', name)
    MySQL.query.await(('DELETE FROM `%s` WHERE `id` = ?'):format(TABLE), { it.id })
    imports[name] = nil
    say('%s removed the import "%s"', byLabel, name)
    return true
end

-- ============================================
-- Sharing: reading a scenario
-- ============================================

--- A stored scenario's document, ready to pack: doc, name, rev; or nil and why.
local function docForShare(key, rev)
    if type(key) ~= 'string' or key == '' then return nil, 'Which scenario?' end
    rev = math.tointeger(tonumber(rev)) or 0
    local rows = MySQL.query.await([[
        SELECT s.`name`, r.`rev`, r.`doc`
        FROM `director_scenarios` s
        JOIN `director_revisions` r ON r.`scenarioId` = s.`id` AND r.`rev` = IF(? > 0, ?, s.`draftRev`)
        WHERE s.`key` = ? LIMIT 1]], { rev, rev, key })
    if not rows then return nil, 'The Director\'s scenarios cannot be read (database)' end
    local row = rows[1]
    if not row then
        return nil, rev > 0 and ('%s has no revision %d'):format(key, rev)
            or ('%s is not a stored scenario (one loaded with /director load is not: save it first)'):format(key)
    end
    local ok, doc = pcall(json.decode, row.doc)
    if not ok or type(doc) ~= 'table' then return nil, 'That scenario cannot be read' end
    doc.id, doc.rev, doc.requires = nil, nil, nil
    doc.key = key   -- a suggestion for the importer, nothing more
    if #row.doc > Codec.MAX_BYTES then return nil, ('It is over %d KB: too big to share'):format(Codec.MAX_BYTES // 1024) end
    return doc, row.name or key, math.tointeger(tonumber(row.rev))
end

-- ============================================
-- The screen's view
-- ============================================

local function view()
    local list = {}
    local all = Whip.core:GetScenarios()
    for _, s in ipairs(type(all) == 'table' and all or {}) do
        list[#list + 1] = { key = s.key, name = s.name, on = s.on == true, source = s.source,
                            stored = s.source ~= 'file', rev = s.draftRev or s.rev }
    end
    table.sort(list, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
    local mine = {}
    for _, it in pairs(imports) do mine[#mine + 1] = { name = it.name, by = it.by, at = it.at } end
    table.sort(mine, function(a, b) return (a.at or 0) > (b.at or 0) end)
    return { scenarios = list, imports = mine, hub = Codec.hubUrl() }
end

-- ============================================
-- Uploads: a code arrives in pieces (a big plain client-to-server message never arrives)
-- ============================================

local uploads = {}   -- [source] = { total, parts, got }

AddEventHandler('playerDropped', function() uploads[source] = nil end)

local function labelOf(player)
    return (player and player.fullName or 'someone') .. (player and player.charId and (' (char %d)'):format(player.charId) or '')
end

-- ============================================
-- Declarations
-- ============================================

Whip.register(function()
    local okTable, twhy = Whip.core:EnsureTable(TABLE, ([[
        CREATE TABLE IF NOT EXISTS `%s` (
            `id`             INT UNSIGNED NOT NULL AUTO_INCREMENT,
            `name`           VARCHAR(60)  NOT NULL,
            `doc`            MEDIUMTEXT   NOT NULL,
            `importedBy`     INT UNSIGNED NULL,
            `importedByName` VARCHAR(80)  NULL,
            `createdAt`      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`),
            UNIQUE KEY `name` (`name`)
        )]]):format(TABLE))
    if okTable ~= true then
        say('^1its table could not be made: %s^7', tostring(twhy))
        return
    end

    -- Every import, offered again (whip_core forgets templates when it restarts).
    imports = {}
    local rows = MySQL.query.await(('SELECT `id`, `name`, `doc`, `importedByName`, UNIX_TIMESTAMP(`createdAt`) AS `at` FROM `%s`'):format(TABLE)) or {}
    local offered = 0
    for _, r in ipairs(rows) do
        local okDoc, doc = pcall(json.decode, r.doc)
        if okDoc and type(doc) == 'table' then
            local ok, why = offer(r.name, doc)
            if ok then offered = offered + 1 else say('the import "%s" was refused: %s', r.name, why) end
            imports[r.name] = { id = r.id, name = r.name, doc = doc, by = r.importedByName or '?', at = tonumber(r.at) }
        else
            say('the import "%s" cannot be read: left out', tostring(r.name))
        end
    end
    if offered > 0 then say('%d import(s) offered in the Director\'s New list', offered) end
    ready = true

    Whip.core:SecureCallback('zext_scenario_share:open', { permission = PERM, whileDead = true, rateLimit = 500, burst = 3 },
    function()
        return view()
    end)

    Whip.core:SecureCallback('zext_scenario_share:share', { permission = PERM, whileDead = true, rateLimit = 500, burst = 3,
        params = { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 } } },
    function(_, _, key, rev)
        local doc, name, got = docForShare(key, rev)
        if not doc then return false, name end
        return { doc = doc, name = name, rev = got }
    end)

    Whip.core:SecureCallback('zext_scenario_share:part', { permission = PERM, whileDead = true, rateLimit = 20, burst = 40,
        params = { { 'index', 'int', 1, PARTS_MAX, 1 }, { 'total', 'int', 1, PARTS_MAX, 1 }, { 'piece', 'string', PART_MAX } } },
    function(source, _, index, total, piece)
        local u = uploads[source]
        if index == 1 or not u or u.total ~= total then
            u = { total = total, parts = {}, got = 0 }
            uploads[source] = u
        end
        if not u.parts[index] then u.got = u.got + 1 end
        u.parts[index] = piece
        return u.got
    end)

    Whip.core:SecureCallback('zext_scenario_share:import', { permission = PERM, whileDead = true, rateLimit = 1000, burst = 2,
        params = { { 'name', 'string', NAME_MAX, '' } } },
    function(source, player, name)
        local u = uploads[source]
        uploads[source] = nil
        if not u or u.got ~= u.total then return false, 'The code did not all arrive: try again' end
        local doc, why = Codec.decode(table.concat(u.parts, '', 1, u.total))
        if not doc then return false, why end
        local r, rwhy = importDoc(doc, name, { charId = player and player.charId, label = labelOf(player) })
        if not r then return false, rwhy end
        local v = view()
        v.done = r
        return v
    end)

    Whip.core:SecureCallback('zext_scenario_share:remove', { permission = PERM, whileDead = true, rateLimit = 500, burst = 3,
        params = { { 'name', 'string', NAME_MAX } } },
    function(_, player, name)
        local ok, why = removeImport(name, labelOf(player))
        if not ok then return false, why end
        return view()
    end)
end)

-- ============================================
-- Exports (server): other resources share and import too
-- ============================================
--
--   exports.zext_scenario_share:ImportScenarioCode(code, opts?) -> true, { name, problems } | false, why   WAITS
--     code: a short code (ZX-...), a long code (WDS1./WDS0.), a scenario's JSON text, or a scenario table.
--     opts: { name? } (else the scenario's own name; "(2)" and on when an import already has it).
--     It becomes a template in the Director's New list, as the screen's Import does.
--   exports.zext_scenario_share:GetScenarioShareCode(key, rev?) -> code | false, why   (a WDS0. long code)

exports('ImportScenarioCode', function(code, opts)
    local by = GetInvokingResource() or 'a script'
    opts = type(opts) == 'table' and opts or {}
    local until_ = GetGameTimer() + 20000
    while not ready and GetGameTimer() < until_ do Wait(250) end
    local doc, why
    if type(code) == 'table' then
        local okCopy, text = pcall(json.encode, code)
        if not okCopy then return false, 'That table cannot be written down as a scenario' end
        doc = json.decode(text)
    else
        doc, why = Codec.decode(code)
    end
    if not doc then return false, why end
    local r, rwhy = importDoc(doc, opts.name, { charId = nil, label = 'resource ' .. tostring(by) })
    if not r then return false, rwhy end
    return true, r
end)

exports('GetScenarioShareCode', function(key, rev)
    local doc, why = docForShare(key, rev)
    if not doc then return false, why end
    local ok, text = pcall(json.encode, doc)
    if not ok or type(text) ~= 'string' then return false, 'That scenario cannot be written down' end
    return 'WDS0.' .. Codec.b64url(text)
end)

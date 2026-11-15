-- The /director screen's and the /whip Director section's server half (client/director.lua and
-- tools/panel_sections/director.lua forward each request here). Each answers `result` or `false, why`.
-- Who may (server/permissions.lua): a Director builder (director.build) sees every scenario and makes, edits, tests,
-- switches on and off; a Director admin (director.admin) also deletes, accepts and exports shipped packs, and gives or
-- takes Director access. The gate is the schema's `permission`. A dead builder may build (whileDead).
-- A document goes up as a latent event, never inside a callback: a large plain client-to-server event never
-- arrives. The page sends it with a token (whip_core:server:directorDoc), then asks save/check naming that token; the
-- callback waits a few seconds for it to land. Coming down, a document rides the callback's answer.

local CORE = GetCurrentResourceName()
local BUILD, ADMIN = 'director.build', 'director.admin'
local UPLOAD_WAIT_MS = 8000          -- under the client's 10 s callback timeout
local UPLOAD_BPS = 500000            -- what the client is told to send at (bytes a second)
local EXAMPLES = { 'courier', 'steal_car', 'vault' }   -- server/director/examples/<name>.json offered by New

local uploads = {}   -- [src] = { [token] = { doc, why, at } }: a Save and a Check sent together each land
local UPLOADS_HELD = 4   -- a player's documents waiting to be taken, at most (the oldest goes)
local editing = {}   -- [key] = { [src] = name }

-- ============================================
-- A document from a page: plain data only
-- ============================================
--
-- What arrives is whatever a client sent, so it is copied, never kept: text, numbers, yes/no and
-- tables of those, keys that are words or list positions, a bounded size and depth. A function
-- reference (a table that throws when indexed) or anything else is refused. What the document
-- MEANS is DirectorGraph.check's job; this only makes sure it is data.

-- (A scenario with variants holds each one's cards two levels further in, and up to eight copies of a job.)
local MAX_DEPTH, MAX_ENTRIES = 14, 150000

local function copyPlain(v, depth, count)
    local t = type(v)
    if t == 'string' or t == 'boolean' then return v end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return nil, 'a number in it is not a number' end
        return v
    end
    if t ~= 'table' then return nil, 'it holds something that is not text, a number or a list' end
    if DirectorKit.callable(v) then return nil, 'a function is not a value' end
    if depth > MAX_DEPTH then return nil, 'it is nested too deep' end
    local out = {}
    local k, x = next(v)
    while k ~= nil do
        count[1] = count[1] + 1
        if count[1] > MAX_ENTRIES then return nil, 'it is too big' end
        if type(k) ~= 'string' and math.type(k) ~= 'integer' then return nil, 'it has a key that is not a word' end
        local c, why = copyPlain(x, depth + 1, count)
        if why then return nil, why end
        out[k] = c
        k, x = next(v, k)
    end
    return out
end

SecureEvent('whip_core:server:directorDoc', {
    permission = BUILD,
    whileDead = true,
    rateLimit = 500,
    burst = 4,
    params = { { 'token', 'id' }, { 'doc', 'any' } },
}, function(source, _, token, doc)
    local clean, why = copyPlain(doc, 1, { 0 })
    -- Read the one way (doc.lua): what the editor sent is a scenario of this Director's format, or why not.
    if clean then clean, why = DirectorDoc.load(clean) end
    local held = uploads[source] or {}
    uploads[source] = held
    -- (Never more than a few: one nobody took, its request gone, is the oldest, and goes first.)
    local n, oldest = 0, nil
    for t, u in pairs(held) do
        n = n + 1
        if not oldest or u.at < held[oldest].at then oldest = t end
    end
    if n >= UPLOADS_HELD and held[token] == nil then held[oldest] = nil end
    held[token] = { doc = clean, why = why, at = GetGameTimer() }
end)

--- The document a page sent with `token`, once it has landed. Answers the doc, or nil and why.
local function takeUpload(src, token)
    local deadline = GetGameTimer() + UPLOAD_WAIT_MS
    while true do
        local held = uploads[src]
        local u = held and held[token]
        if u then
            held[token] = nil
            if not next(held) then uploads[src] = nil end
            if not u.doc then return nil, 'That scenario could not be read: ' .. tostring(u.why) end
            return u.doc
        end
        if GetGameTimer() > deadline then return nil, 'The scenario did not arrive in time: try again' end
        Wait(100)
    end
end

-- ============================================
-- Reading
-- ============================================

local function off()
    if Director.off then return 'The Director is off: ' .. Director.off end
    if not DirectorStore.ready then return 'The Director is still starting' end
    return nil
end

local function editorsOf(key, except)
    local names = {}
    for src, name in pairs(editing[key] or {}) do
        if src ~= except and Players[src] then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

local function liveRuns()
    local out = {}
    local now = GetGameTimer()
    for _, run in ipairs(DirectorRuntime.list()) do
        local names = {}
        for s in pairs(run.players) do
            local p = Players[s]
            names[#names + 1] = p and p.fullName or ('#' .. tostring(s))
        end
        table.sort(names)
        out[#out + 1] = { id = run.id, scenario = run.scenarioId, rev = run.rev, test = run.test == true,
                          players = names, seconds = math.floor((now - (run.startedAt or now)) / 1000),
                          variant = run.variantName }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- One of the screen's requests: a builder's unless `level` says ADMIN. `level = false`: no permission,
--- for a request that only ends what the sender owns (their own test), which a builder who has just
--- lost access must still be able to end.
local function cb(name, params, handler, rate, level)
    ---@type string|nil
    local permission = BUILD
    if level == false then permission = nil elseif level ~= nil then permission = level end
    SecureCallback('whip_core:director:' .. name, {
        permission = permission,
        whileDead = true,
        rateLimit = rate or 200,
        burst = 5,
        params = params,
    }, handler)
end

--- Players' runs of a scenario going now (a builder's test is not counted).
local function runsGoing(key)
    local n = 0
    for _, run in ipairs(DirectorRuntime.list()) do
        if run.scenarioId == key and not run.test then n = n + 1 end
    end
    return n
end

cb('list', {}, function(source)
    local stats = DirectorStore.ready and DirectorStore.stats() or {}
    local rows = {}
    for _, s in ipairs(DirectorStore.ready and DirectorStore.list() or {}) do
        local st = stats[s.id] or {}
        local sc = Director.active[s.key]
        local live = runsGoing(s.key)
        s.runs, s.succeeded, s.calledOff, s.lastRunAt = st.runs or 0, st.succeeded or 0, st.aborted or 0, st.lastAt
        s.on = sc ~= nil and sc.dbId == s.id
        s.onRev = s.on and sc.rev or nil
        -- A script switched it (SwitchScenario, in memory only): { on, by = resource }.
        local sw = Director.scriptSwitched[s.key]
        s.switchedBy = sw and { on = sw.on, by = sw.by } or nil
        s.live, s.editors = live, editorsOf(s.key, source)
        s.pack = DirectorStore.packOf(s.key)   -- shipped: read-only here
        -- The description is the draft's (the Blueprint's), as the editor has it now.
        local sum = DirectorStore.summary(s.key)
        if sum then s.description = sum.description ~= '' and sum.description or nil end
        -- Its variants' names, when it has more than one (the page says them).
        if sum and type(sum.variants) == 'table' and #sum.variants > 1 then
            s.variants = {}
            for i, v in ipairs(sum.variants) do s.variants[i] = v.name end
        end
        s.makerId = (DirectorStore.creatorOf(s.key))   -- the Overview's Made by filter (nil: the server, a pack)
        rows[#rows + 1] = s
    end
    -- The Overview's "with a lore character" filter: who there is to pick.
    local lore = {}
    for _, c in ipairs(DirectorLore and DirectorLore.list() or {}) do lore[#lore + 1] = { key = c.key, name = c.name } end
    -- A scenario switched on from a file (/director load) is live too, but not in the store.
    local files = {}
    for id, sc in pairs(Director.active) do
        if not sc.dbId then files[#files + 1] = { key = id, name = sc.name } end
    end
    local pending = 0
    for _, p in ipairs(DirectorPacks.list()) do if p.status == 'pending' then pending = pending + 1 end end
    -- templates: other resources' starting points (Whip.template, packs.lua), beside the examples.
    return { off = off(), scenarios = rows, files = files, runs = liveRuns(), examples = EXAMPLES, lore = lore,
             templates = DirectorPacks.templates and DirectorPacks.templates() or {},
             admin = Permissions.has(source, ADMIN), pendingPacks = pending,
             isolated = Director.isolated[source] ~= nil }
end)

--- The jobs a card's `job` field picks from: { { key, name }, ... }.
local function jobList()
    local out = {}
    for _, j in ipairs(Jobs and Jobs.getAll and Jobs.getAll() or {}) do
        if type(j.key) == 'string' then out[#out + 1] = { key = j.key, name = j.name or j.key } end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

cb('cards', {}, function(source)
    -- rev: the catalogue's revision (it moves as other resources add or take away cards: the page asks
    -- again when an open, or a push, says it has). locked: a card naming a permission this builder has
    -- not got (cards_api.lua, Director.gatedChange): drawn with a lock, not to be added or changed.
    local cards = DirectorNodes.wire()
    for _, c in ipairs(cards) do
        if c.permission and not Permissions.has(source, c.permission) then c.locked = true end
    end
    -- tasks: what a placed thing's Tasks list can hold (server/director/tasks.lua), for its page.
    return { cards = cards, format = DirectorDoc.FORMAT, rev = DirectorNodes.rev, jobs = jobList(), lore = DirectorLore.list(),
             tasks = DirectorTasks.wire() }
end)

--- The world builder's Play here (client/director_preview.lua): things' task lists read as a run reads them, from the
--- scenario as it is in the editor (not saved yet). `things`: { { id, kind, tasks } }, at most 8; `world`: the
--- scenario's things as a step may name them { [id] = { kind, def } } (a route's points with them). Answers
--- { plans = { { id, plan = { steps, after } | nil, problems } } }, an emote's animation looked up for each step.
local PREVIEW_MAX = 8
cb('previewPlans', { {'things', 'any'}, {'world', 'any'} }, function(_, _, things, world)
    local W = {}
    for id, w in pairs(type(world) == 'table' and world or {}) do
        if type(id) == 'string' and #id <= 64 and type(w) == 'table' and type(w.kind) == 'string' and #w.kind <= 24 then
            W[id] = { id = id, kind = w.kind, label = type(w.label) == 'string' and DirectorKit.cut(w.label, 60) or nil,
                      def = type(w.def) == 'table' and w.def or {} }
        end
    end
    local out = {}
    for i, t in ipairs(type(things) == 'table' and things or {}) do
        if i > PREVIEW_MAX then break end
        if type(t) == 'table' and type(t.id) == 'string' and type(t.kind) == 'string' then
            -- (Its take ids: a task's take is one of its own. A page that sends none is not asked.)
            local owner = type(t.takes) == 'table' and { def = { takes = t.takes } } or nil
            local ok, plan, probs = pcall(DirectorTasks.compile, t.kind, t.tasks, W, owner)
            if ok then
                for _, s in ipairs(plan and plan.steps or {}) do
                    local key = DirectorSteps.is(s.t, 'emoteAnim')
                    if key then s.p.anim = DirectorTasks.emoteAnim(s.p[key]) end
                    -- Another resource's step: a field naming a placed thing, for the preview to find its copy.
                    local d = DirectorTasks.get(s.t)
                    if d and d.satellite then
                        for _, f in ipairs(d.fields) do
                            if f.kind == 'world' and type(s.p[f.key]) == 'string' then s.p[f.key] = { thing = s.p[f.key] } end
                        end
                    end
                end
                out[#out + 1] = { id = t.id, plan = plan, problems = probs }
            else
                out[#out + 1] = { id = t.id, problems = { { i = 0, label = 'Tasks', why = 'could not be read' } } }
            end
        end
    end
    return { plans = out }
end, 30)

-- ============================================
-- Lore characters (server/director/lore.lua): the hub's Lore list
-- ============================================

cb('lore', {}, function(source)
    -- pictureLinks: the link starts a picture may have (the form says so, and checks before saving).
    -- voice: the voice lines the form shows, their link starts, on or not (director/lore_voice.lua).
    return { lore = DirectorLore.list(true), ready = DirectorLore.ready, admin = Permissions.has(source, ADMIN),
             pictureLinks = DirectorLore.pictureLinks(), voice = DirectorLore.voiceInfo() }
end)

cb('loreSave', { { 'key', 'key', 64 }, { 'name', 'string', 80 }, { 'model', 'string', 64, '' },
                 { 'bankName', 'string', 50, '' }, { 'notes', 'string', 2000, '' }, { 'picture', 'string', 255, '' },
                 -- the picture's framing: the point kept in view (0-100 across, down) and the zoom (1-3)
                 { 'frameX', 'number', 0, 100, 50 }, { 'frameY', 'number', 0, 100, 50 }, { 'frameZ', 'number', 1, 3, 1 },
                 -- the voice lines as JSON text, read and checked by DirectorLore.save (cleanVoice); empty leaves them
                 { 'voice', 'string', 48000, '' } },
function(_, player, key, name, model, bankName, notes, picture, frameX, frameY, frameZ, voice)
    local c, why = DirectorLore.save(key, { name = name, model = model, bankName = bankName, notes = notes, picture = picture,
        pictureFrame = { x = frameX, y = frameY, z = frameZ }, voice = voice }, player and player.fullName or nil)
    if not c then return false, why end
    return { character = c }
end, 500)

cb('loreRetire', { { 'key', 'key', 64 } }, function(_, player, key)
    local ok, why = DirectorLore.retire(key, player and player.fullName or nil)
    if not ok then return false, why end
    return true
end, 500, ADMIN)

--- The card list moved (another resource added, changed or took away cards: cards_api.lua): every
--- builder with a scenario open is told, and their page asks for it again.
function Director.cardsCatalogueChanged(rev)
    local told = {}
    for _, list in pairs(editing) do
        for src in pairs(list) do
            if not told[src] then
                told[src] = true
                TriggerClientEvent('whip_core:client:directorCardsChanged', src, rev)
            end
        end
    end
end

cb('open', { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 } }, function(source, player, key, rev)
    local why = off()
    if why then return false, why end
    local row = DirectorStore.get(key)
    if not row then return false, 'No scenario called ' .. key end
    local doc, r = DirectorStore.revision(key, rev > 0 and rev or row.draftRev)
    if not doc then return false, r end
    local _, problems = DirectorGraph.check(doc)
    -- Only the draft is being edited: opening an old revision to look at it is not.
    if r == row.draftRev then
        for k, list in pairs(editing) do list[source] = nil; if next(list) == nil then editing[k] = nil end end
        editing[key] = editing[key] or {}
        editing[key][source] = player.fullName
    end
    local sc = Director.active[key]
    -- cardsRev: the page asks for the card list again when it has moved since it last did; providers:
    -- whose each other-resource card was when it was switched on (a card not here names who to start). lore: the
    -- lore characters as they are now, so their NPCs wear their peds as they are (the card list's may be old).
    return { scenario = row, doc = doc, rev = r, problems = problems, editors = editorsOf(key, source),
             on = sc ~= nil and sc.dbId == row.id, onRev = sc and sc.dbId == row.id and sc.rev or nil,
             uploadBps = UPLOAD_BPS, pack = DirectorStore.packOf(key), cardsRev = DirectorNodes.rev,
             providers = DirectorStore.cardProviders(key), lore = DirectorLore.list() }
end)

--- The editor back on a scenario it already had open: closing the screen forgot it (`closed`), and
--- the page comes back without opening it again. Seen as having it open once more, for who is
--- editing it and its live pulses.
cb('watch', { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 } }, function(source, player, key, rev)
    local why = off()
    if why then return false, why end
    local row = DirectorStore.get(key)
    if not row then return false, 'No scenario called ' .. key end
    -- As `open`: only the draft is being edited.
    if rev == row.draftRev then
        for k, list in pairs(editing) do list[source] = nil; if next(list) == nil then editing[k] = nil end end
        editing[key] = editing[key] or {}
        editing[key][source] = player.fullName
    end
    return { editors = editorsOf(key, source), lore = DirectorLore.list() }   -- (lore: as `open`'s)
end)

cb('history', { { 'key', 'key', 64 } }, function(_, _, key)
    if not DirectorStore.get(key) then return false, 'No scenario called ' .. key end
    return { revisions = DirectorStore.history(key, 30) }
end)

-- What a mark's card on that map shows of a thing's settings: these, as saved, plain values only.
local PLACE_DEF = { behaviour = true, armour = true, fightBack = true, plate = true, locked = true, secure = true,
                    group = true, collision = true, slots = true, maxWeight = true, prop = true, amount = true }
-- (Made by the run's cards whatever its layer says, a car, a door, a container: its kind's runOnly, things.lua.)

--- Who names each placed thing (DirectorRefs.each: cards, task steps, other things' settings, the Settings).
--- { [id] = { { what, n }, ... } } in the order first met.
local function namersOf(doc)
    local out, at = {}, {}
    local function add(id, what)
        local list = out[id] or {}
        out[id] = list
        local k = id .. '\0' .. what
        if at[k] then list[at[k]].n = list[at[k]].n + 1; return end
        list[#list + 1] = { what = what, n = 1 }
        at[k] = #list
    end
    -- Every variant's cards and things; a card copied into another variant (its id kept) and a thing every variant
    -- shares, counted once. (The Settings once, after.)
    local seenCard, seenThing = {}, {}
    for _, v in ipairs(DirectorGraph.variantsOf(doc)) do
        local d = v.doc
        local cards, things = {}, {}
        DirectorRefs.each({ nodes = d.nodes, world = d.world }, function(r)
            if r.kind ~= 'world' then return end
            if r.node then
                if seenCard[r.node.id] then return end
                cards[r.node.id] = true
            elseif r.thing then
                if seenThing[r.thing.id] then return end
                things[r.thing.id] = true
            end
            add(r.id, DirectorRefs.namerText(r))
        end)
        for id in pairs(cards) do seenCard[id] = true end
        for id in pairs(things) do seenThing[id] = true end
    end
    DirectorRefs.each({ settings = doc.settings }, function(r) if r.kind == 'world' then add(r.id, DirectorRefs.namerText(r)) end end)
    return out
end

--- Every variant's placed things, each once (a shared one in Variant 1's place), with the variant a thing of its
--- own is in when there are more than one: { { w, variant } }.
local function allThings(doc)
    local out, seen = {}, {}
    local list = DirectorGraph.variantsOf(doc)
    for i, v in ipairs(list) do
        for _, w in ipairs(type(v.doc.world) == 'table' and v.doc.world or {}) do
            if type(w) == 'table' and not seen[w.id] then
                seen[w.id] = true
                out[#out + 1] = { w = w, variant = #list > 1 and ((type(v.name) == 'string' and v.name ~= '') and v.name or ('Variant ' .. i)) or nil }
            end
        end
    end
    return out
end

--- One mark of the map: where it is, what it is, and what its card says.
local function placeOf(w, namers)
    local def = w.def
    local c = def.coords
    local x, y = type(c) == 'table' and tonumber(c.x), type(c) == 'table' and tonumber(c.y)
    if not (x and y) then return nil end
    local kind = tostring(w.kind or '')
    local p = { id = tostring(w.id or ''), kind = kind, name = tostring(w.label or w.id or ''), x = x, y = y,
                z = type(c) == 'table' and tonumber(c.z) or nil, uses = namers[w.id] }
    p.model = type(def.model) == 'string' and def.model ~= '' and def.model:sub(1, 64) or nil
    if kind ~= 'spot' then p.layer = (DirectorThings.is(kind, 'runOnly') or w.layer ~= 'standing') and 'run' or 'standing' end
    local facts = {}
    for k in pairs(PLACE_DEF) do
        local v = def[k]
        if type(v) == 'string' then facts[k] = DirectorKit.cut(v, 64)
        elseif type(v) == 'number' or type(v) == 'boolean' then facts[k] = v end
    end
    local cond = type(def.conditions) == 'table' and def.conditions or {}
    if type(cond.invincible) == 'boolean' then facts.invincible = cond.invincible end
    if type(cond.canMove) == 'boolean' then facts.canMove = cond.canMove end
    p.facts = facts
    -- A car's takes (its recorded drives): the page draws the one it plays on the map when it is clicked (takePath).
    if kind == 'vehicle' then
        local takes = DirectorTakes.of(w)
        if #takes > 0 then p.takes = takes end
    end
    if kind == 'npc' then
        local wn = type(def.weapon) == 'table' and def.weapon.name or def.weapon
        if type(wn) == 'string' and wn ~= '' then
            local g = WeaponCatalog.get(wn)
            p.weapon = g and WeaponCatalog.title(g) or wn:sub(1, 64)
        end
        local lore = type(def.lore) == 'string' and def.lore ~= '' and DirectorLore.get(def.lore) or nil
        if lore then
            -- key and portraitAt: the page draws their headshot where they have no picture link (lore-faces.js).
            p.lore = { name = lore.name, retired = lore.retired or nil, key = lore.key, portraitAt = lore.portraitAt }
            -- Their ped as it is now, as a run makes it (Npcs.spawn).
            if type(lore.model) == 'string' and lore.model ~= '' then p.model = lore.model:sub(1, 64) end
            if lore.picture and not DirectorLore.pictureProblem(lore.picture) then
                p.lore.picture, p.lore.pictureFrame = lore.picture, lore.pictureFrame
            end
        end
    elseif kind == 'groundItem' and type(def.item) == 'string' then
        local idef = type(Config.Items) == 'table' and Config.Items[def.item]
        p.item = { key = def.item:sub(1, 64), name = idef and idef.name or nil,
                   img = idef and Inventory.resolveItemImage(def.item, idef) or nil }
    end
    local t = type(def.tasks) == 'table' and def.tasks or nil
    if t and type(t.list) == 'table' and #t.list > 0 then
        local steps = {}
        for _, step in ipairs(t.list) do
            local d = type(step) == 'table' and DirectorTasks.get(step.t)
            if d then steps[#steps + 1] = d.label end
        end
        if #steps > 0 then p.tasks = { steps = steps, loop = t.after == 'loop' or nil } end
    end
    return p
end

-- THE SCENARIOS PAGE'S MAP AND WHO MADE IT: where each of its things is in its newest revision, with what its mark's
-- card says (placeOf: what it is, its settings, its task steps, who names it), and its maker's name and face (the
-- character they play now, else the one they played last, as the Player Manager's list does), and whether they are on.
cb('places', { { 'key', 'key', 64 } }, function(_, _, key)
    local doc, why = DirectorStore.revision(key)
    if not doc then return false, why end
    local places = {}
    local namers = namersOf(doc)
    for _, e in ipairs(allThings(doc)) do
        local w = e.w
        local p = type(w.def) == 'table' and placeOf(w, namers) or nil
        -- (A thing of one variant's own says which: Variant 1's too, when there are more.)
        if p then
            p.variant = e.variant
            places[#places + 1] = p
        end
    end
    local userId, name = DirectorStore.creatorOf(key)
    local creator = { name = name or 'the server' }
    if userId then
        local p = PlayersByUserId[userId]
        if p and p.charId then
            creator.charId, creator.online = p.charId, true
        else
            local ok, rows = pcall(MySQL.query.await, 'SELECT `charId` FROM `characters` WHERE `userId` = ? AND `deleted` IS NULL '
                .. 'ORDER BY `lastPlayed` DESC LIMIT 1', { userId })
            creator.charId = ok and rows and rows[1] and rows[1].charId or nil
        end
    end
    return { places = places, creator = creator }
end, 300)

-- A car's take as a line on the Scenarios page's map: where it drives, { x1, y1, x2, y2, ... } (DirectorTakes.path).
-- Only a take one of the scenario's cars names (in its newest revision).
cb('takePath', { { 'key', 'key', 64 }, { 'take', 'int', 1, 2147483647 } }, function(_, _, key, take)
    local doc, why = DirectorStore.revision(key)
    if not doc then return false, why end
    local named = false
    for _, e in ipairs(allThings(doc)) do
        if e.w.kind == 'vehicle' then
            for _, t in ipairs(DirectorTakes.of(e.w)) do if t.id == take then named = true end end
        end
    end
    if not named then return false, 'That driving event is not one of its cars\'' end
    local t, twhy = DirectorTakes.load(take)
    if not t then return false, twhy end
    return { points = DirectorTakes.path(t) }
end, 300)

-- ============================================
-- Writing
-- ============================================

--- A brand-new scenario's document: something starts it, nothing else yet.
local function emptyDoc(name)
    return {
        format = DirectorDoc.FORMAT, name = name, description = '',
        -- A crew is picked on the team page (Pick Team), never by who stands near. Its Scenario Enabled plays as it is
        -- switched on (main.lua Director.openRun).
        settings = { start = { mode = 'enabled' }, maxConcurrentRuns = 1, teamSize = 4, maxRunSec = 900 },
        vars = {}, world = {},
        nodes = { { id = 'start', type = 'scenario.started', v = 1, x = 0, y = 0, props = {} } },
        links = {},
    }
end

local function exampleDoc(name)
    local raw = LoadResourceFile(CORE, ('server/director/examples/%s.json'):format(name))
    if not raw then return nil, 'No example called ' .. name end
    local ok, doc = pcall(json.decode, raw)
    if not ok or type(doc) ~= 'table' then return nil, 'That example is not readable' end
    -- A file's "spot" means "place me": left unplaced, for the World tab.
    for _, w in ipairs(doc.world or {}) do
        if type(w.def) == 'table' and w.def.coords == 'spot' then w.def.coords = nil end
    end
    doc.id, doc.rev = nil, nil
    return doc
end

cb('create', { { 'key', 'key', 64 }, { 'name', 'string', 80 }, { 'from', 'string', 200, '' } },
function(source, _, key, name, from)
    local why = off()
    if why then return false, why end
    local doc, dwhy
    if from == '' then
        doc = emptyDoc(name)
    elseif from:sub(1, 8) == 'example:' then
        local ex = from:sub(9)
        local known = false
        for _, e in ipairs(EXAMPLES) do if e == ex then known = true end end
        if not known then return false, 'No example called ' .. ex end
        doc, dwhy = exampleDoc(ex)
    elseif from:sub(1, 5) == 'copy:' then
        local other = from:sub(6)
        if not DirectorStore.get(other) then return false, 'No scenario called ' .. other end
        doc, dwhy = DirectorStore.revision(other)
    elseif from:sub(1, 9) == 'template:' and DirectorPacks.template then
        -- Another resource's starting point (Whip.template): the builder's own copy.
        doc, dwhy = DirectorPacks.template(from:sub(10))
    else
        return false, 'Start from nothing, an example, a template or a copy'
    end
    if not doc then return false, dwhy end
    -- A copy cannot carry in a card its maker may not add (a gated card: cards_api.lua).
    local gated = Director.gatedChange and Director.gatedChange(source, doc, nil)
    if gated then return false, gated end
    doc.name = name
    local row, cwhy = DirectorStore.create(key, name, doc, source)
    if not row then return false, cwhy end
    return { scenario = row }
end, 1000)

-- One of the examples New offers, only to look at (the tutorial shows them: nothing is stored).
cb('example', { { 'name', 'key', 64 } }, function(_, _, name)
    local known = false
    for _, e in ipairs(EXAMPLES) do if e == name then known = true end end
    if not known then return false, 'No example called ' .. name end
    local doc, why = exampleDoc(name)
    if not doc then return false, why end
    return { doc = doc }
end, 300)

-- ============================================
-- PROJECT Z PATCH: share codes (Scenarios page: Share code / Import code)
-- ============================================
-- A share code is a whole scenario document, packed by the page (html/js/wp/director.js): nothing is
-- hosted, so a code works on any WHIP server. Share hands the page a scenario's newest revision (or the
-- one asked for); Import makes a NEW draft scenario from a code, switched off, never touching an existing
-- one. What it arrives as goes through the same doors as the editor's Save: the upload is copied as plain
-- data and read by DirectorDoc.load (whip_core:server:directorDoc), and a gated card its importer may not
-- add is refused (Director.gatedChange). What this server lacks to run it (items, cards) is said, not refused:
-- the builder fixes it in the editor before switching it on.

local SHARE_MAX_BYTES = 512 * 1024   -- a shipped file's limit (packs.lua MAX_BYTES)

cb('shareDoc', { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 } }, function(_, _, key, rev)
    local why = off()
    if why then return false, why end
    local row = DirectorStore.get(key)
    if not row then return false, 'No scenario called ' .. key end
    local doc, got = DirectorStore.revision(key, rev > 0 and rev or row.draftRev)
    if not doc then return false, got end
    doc.id, doc.rev = nil, nil
    doc.key = key   -- a suggestion for the importer's key, nothing more
    doc.requires = DirectorPacks.requiresOf(doc)
    local ok, text = pcall(json.encode, doc)
    if not ok or type(text) ~= 'string' then return false, 'That scenario cannot be written down' end
    if #text > SHARE_MAX_BYTES then return false, ('It is over %d KB: too big to share'):format(SHARE_MAX_BYTES // 1024) end
    return { doc = doc, rev = got, name = row.name or key }
end, 2000)

--- What an imported document names that this server has not got: { items = {...}, cards = {...} }.
local function shareMissing(doc)
    local items, cards = {}, {}
    local seenI, seenC = {}, {}
    local req = DirectorPacks.requiresOf(doc) or {}
    for _, it in ipairs(req.items or {}) do
        if not seenI[it] and not DirectorFields.isItem(it) then seenI[it] = true items[#items + 1] = it end
    end
    for _, vr in ipairs(DirectorGraph.variantsOf(doc)) do
        local named = DirectorNodes.applyRenames(vr.doc)
        for _, n in ipairs(type(named) == 'table' and type(named.nodes) == 'table' and named.nodes or {}) do
            local t = type(n) == 'table' and n.type or nil
            if type(t) == 'string' and not seenC[t] and not DirectorNodes.get(t) then seenC[t] = true cards[#cards + 1] = t end
        end
    end
    table.sort(items)
    table.sort(cards)
    return { items = items, cards = cards }
end

cb('importCode', { { 'key', 'key', 64 }, { 'name', 'string', 80 }, { 'token', 'id' } },
function(source, _, key, name, token)
    local why = off()
    if why then return false, why end
    local doc, uwhy = takeUpload(source, token)
    if not doc then return false, uwhy end
    local okSize, text = pcall(json.encode, doc)
    if not okSize or type(text) ~= 'string' or #text > SHARE_MAX_BYTES then return false, 'That code is too big or cannot be read' end
    if DirectorStore.get(key) then return false, key .. ' is taken: pick another key' end
    local gated = Director.gatedChange and Director.gatedChange(source, doc, nil)
    if gated then return false, gated end
    -- (requiresOf is worked out again from what it holds; the code's own list is only the sharer's word.)
    local missing = shareMissing(doc)
    doc.id, doc.rev, doc.key, doc.requires = nil, nil, nil, nil
    doc.name = name
    local row, cwhy = DirectorStore.create(key, name, doc, source)
    if not row then return false, cwhy end
    return { scenario = row, missing = missing }
end, 2000)

-- ---- Script side: other resources import and share codes too ----
--
--   exports.whip_core:ImportScenarioCode(code, opts?) -> true, { key, name, missing } | false, why   WAITS
--     code: a short code (ZX-...), a long code (WDS1./WDS0.), a scenario's JSON text, or a scenario table.
--     opts: { key?, name? }. Without a key, one is made from the code's own (or its name), with _2, _3... on the
--     end when that is taken. A key you name that is taken is refused, never written over.
--   exports.whip_core:GetScenarioShareCode(key, rev?) -> code | false, why   (a WDS0. long code: any page reads it)
--
-- An import is exactly what the page's Import code makes: a NEW draft, switched off, through the same reader
-- (copyPlain + DirectorDoc.load). A script has no permissions, so a gated card in it is refused. The server's
-- console says which resource imported what. Short codes are looked up at the convar zext_share_hub (the same
-- hub as html/js/wp/director.js HUB_URL); set it to "" and only long codes are taken.

local SHARE_HUB_DEFAULT = 'https://zext-scenario-hub.whipshare.workers.dev'
local SHORT_CODE = '^[Zz][Xx]%-?[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]+$'

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
local B64V = {}
for i = 1, 64 do B64V[B64:byte(i)] = i - 1 end
B64V[('+'):byte()], B64V[('/'):byte()] = 62, 63

local function unb64url(s)
    local out, n, acc, bits = {}, 0, 0, 0
    for i = 1, #s do
        local v = B64V[s:byte(i)]
        if not v then return nil end
        acc, bits = (acc << 6) | v, bits + 6
        if bits >= 8 then
            bits = bits - 8
            n = n + 1
            out[n] = string.char((acc >> bits) & 255)
        end
        acc = acc & ((1 << bits) - 1)
    end
    return table.concat(out)
end

local function b64url(s)
    local out, n = {}, 0
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local v = (a << 16) | ((b or 0) << 8) | (c or 0)
        local take = c and 4 or (b and 3 or 2)
        for k = 1, take do
            local d = (v >> (18 - 6 * (k - 1))) & 63
            n = n + 1
            out[n] = B64:sub(d + 1, d + 1)
        end
    end
    return table.concat(out)
end

-- Inflate (RFC 1950/1951), written for this: a page's CompressionStream('deflate') output back into text.
-- Never past maxOut bytes, so a small code cannot unpack into a huge one.
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
    6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

--- Canonical Huffman table from code lengths (index 0..num-1): counts per length and symbols in code order.
local function huffman(lengths, num)
    local counts, offs, syms = {}, {}, {}
    for l = 0, 15 do counts[l] = 0 end
    for i = 0, num - 1 do
        local l = lengths[i] or 0
        counts[l] = counts[l] + 1
    end
    counts[0] = 0
    offs[1] = 0
    for l = 1, 14 do offs[l + 1] = offs[l] + counts[l] end
    for i = 0, num - 1 do
        local l = lengths[i] or 0
        if l ~= 0 then
            syms[offs[l]] = i
            offs[l] = offs[l] + 1
        end
    end
    return { counts = counts, syms = syms }
end

local fixedLit, fixedDist
local function fixedTables()
    if not fixedLit then
        local l, d = {}, {}
        for i = 0, 143 do l[i] = 8 end
        for i = 144, 255 do l[i] = 9 end
        for i = 256, 279 do l[i] = 7 end
        for i = 280, 287 do l[i] = 8 end
        for i = 0, 29 do d[i] = 5 end
        fixedLit, fixedDist = huffman(l, 288), huffman(d, 30)
    end
    return fixedLit, fixedDist
end

local function inflate(src, start, maxOut)
    local pos, buf, cnt = start, 0, 0
    local out, n = {}, 0
    local function bits(k)
        while cnt < k do
            local b = src:byte(pos)
            if not b then error('cut short', 0) end
            pos = pos + 1
            buf = buf | (b << cnt)
            cnt = cnt + 8
        end
        local v = buf & ((1 << k) - 1)
        buf, cnt = buf >> k, cnt - k
        return v
    end
    local function decode(h)
        local code, first, index = 0, 0, 0
        for len = 1, 15 do
            code = code | bits(1)
            local count = h.counts[len]
            if code - count < first then
                local s = h.syms[index + (code - first)]
                if not s then error('bad code', 0) end
                return s
            end
            index = index + count
            first = (first + count) << 1
            code = code << 1
        end
        error('bad code', 0)
    end
    local function put(byte)
        n = n + 1
        if n > maxOut then error('too big', 0) end
        out[n] = byte
    end
    local function codes(lit, dist)
        while true do
            local sym = decode(lit)
            if sym < 256 then
                put(sym)
            elseif sym == 256 then
                return
            else
                sym = sym - 257
                if sym >= 29 then error('bad length', 0) end
                local len = LBASE[sym + 1] + bits(LEXT[sym + 1])
                local d = decode(dist)
                if d >= 30 then error('bad distance', 0) end
                local back = DBASE[d + 1] + bits(DEXT[d + 1])
                if back > n then error('bad distance', 0) end
                for _ = 1, len do put(out[n + 1 - back]) end
            end
        end
    end
    repeat
        local last = bits(1)
        local kind = bits(2)
        if kind == 0 then
            buf, cnt = 0, 0   -- to the next whole byte
            local lo, hi, nlo, nhi = src:byte(pos, pos + 3)
            if not nhi then error('cut short', 0) end
            local len = lo | (hi << 8)
            if (len ~ (nlo | (nhi << 8))) ~= 0xFFFF then error('bad stored block', 0) end
            pos = pos + 4
            if pos + len - 1 > #src then error('cut short', 0) end
            for i = pos, pos + len - 1 do put(src:byte(i)) end
            pos = pos + len
        elseif kind == 1 then
            codes(fixedTables())
        elseif kind == 2 then
            local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
            if nlen > 286 or ndist > 30 then error('bad block', 0) end
            local cl = {}
            for i = 1, 19 do cl[CL_ORDER[i]] = i <= ncode and bits(3) or 0 end
            local clh = huffman(cl, 19)
            local lengths, idx = {}, 0
            while idx < nlen + ndist do
                local sym = decode(clh)
                if sym < 16 then
                    lengths[idx] = sym
                    idx = idx + 1
                else
                    local len, rep = 0, 0
                    if sym == 16 then
                        if idx == 0 then error('bad block', 0) end
                        len, rep = lengths[idx - 1], 3 + bits(2)
                    elseif sym == 17 then
                        rep = 3 + bits(3)
                    else
                        rep = 11 + bits(7)
                    end
                    if idx + rep > nlen + ndist then error('bad block', 0) end
                    for _ = 1, rep do
                        lengths[idx] = len
                        idx = idx + 1
                    end
                end
            end
            local ll, dl = {}, {}
            for i = 0, nlen - 1 do ll[i] = lengths[i] end
            for i = 0, ndist - 1 do dl[i] = lengths[nlen + i] end
            codes(huffman(ll, nlen), huffman(dl, ndist))
        else
            error('bad block', 0)
        end
    until last == 1
    local parts = {}
    for i = 1, n, 4096 do parts[#parts + 1] = string.char(table.unpack(out, i, math.min(i + 4095, n))) end
    return table.concat(parts)
end

--- A zlib stream (what CompressionStream('deflate') makes) into text, or nil and why.
local function unzlib(s)
    local cmf, flg = s:byte(1, 2)
    if not flg or (cmf & 15) ~= 8 or ((cmf << 8) | flg) % 31 ~= 0 or (flg & 32) ~= 0 then return nil, 'That code is broken' end
    local ok, text = pcall(inflate, s, 3, SHARE_MAX_BYTES)
    if not ok then return nil, text == 'too big' and 'That code is too big' or 'That code is broken: part of it is missing' end
    return text
end

--- A short code's long code, from the hub (WAITS).
local function hubLookup(short)
    local base = GetConvar('zext_share_hub', SHARE_HUB_DEFAULT)
    if base == '' then return nil, 'Short codes are off on this server (zext_share_hub is ""): use the long code' end
    local p = promise.new()
    PerformHttpRequest(base:gsub('/+$', '') .. '/v1/codes/' .. short:upper(), function(status, body)
        p:resolve({ status = status, body = body })
    end, 'GET', '', { ['Accept'] = 'application/json' })
    local r = Citizen.Await(p)
    if r.status == 404 then return nil, 'No scenario has the code ' .. short:upper() end
    if r.status ~= 200 or type(r.body) ~= 'string' then return nil, ('The scenario hub did not answer (%s)'):format(tostring(r.status)) end
    local ok, d = pcall(json.decode, r.body)
    if not ok or type(d) ~= 'table' or type(d.code) ~= 'string' then return nil, 'The scenario hub sent back nothing usable' end
    return d.code
end

--- Whatever a script handed over, as a document read the one way (copyPlain + DirectorDoc.load), or nil and why.
local function docFromCode(code)
    if type(code) == 'table' then
        local clean, why = copyPlain(code, 1, { 0 })
        if clean then clean, why = DirectorDoc.load(clean) end
        return clean, why
    end
    if type(code) ~= 'string' or code == '' then return nil, 'code is a share code, a scenario\'s JSON or a scenario table' end
    local text = code:gsub('%s+', '')
    if text:match(SHORT_CODE) and #text <= 12 then
        local long, why = hubLookup(text)
        if not long then return nil, why end
        text = long:gsub('%s+', '')
    end
    local ver, body = text:match('^WDS([01])%.([%w_%-]+)$')
    local raw
    if ver then
        raw = unb64url(body)
        if not raw then return nil, 'That code is broken: part of it is missing' end
        if ver == '1' then
            local why
            raw, why = unzlib(raw)
            if not raw then return nil, why end
        end
    elseif code:match('^%s*{') then
        raw = code
    else
        return nil, 'That is not a scenario code (one starts with ZX- or WDS1.)'
    end
    if #raw > SHARE_MAX_BYTES then return nil, 'That code is too big' end
    local ok, doc = pcall(json.decode, raw)
    if not ok or type(doc) ~= 'table' then return nil, 'That code is broken: it is not a scenario' end
    if type(doc.nodes) ~= 'table' then return nil, 'That is not a scenario (it has no cards)' end
    return docFromCode(doc)
end

--- A key made the page's way (director.js slug): lower case, runs of anything else to one _, trimmed, 40 long.
local function keyFrom(s)
    s = type(s) == 'string' and s:lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', ''):sub(1, 40) or ''
    return #s >= 2 and s or 'imported'
end

exports('ImportScenarioCode', function(code, opts)
    local by = Registry.caller()
    opts = type(opts) == 'table' and opts or {}
    -- A resource importing as it starts usually runs before the Director has read its database: wait a little.
    local until_ = GetGameTimer() + 20000
    while not DirectorStore.ready and not Director.off and GetGameTimer() < until_ do Wait(250) end
    local why = off()
    if why then return false, why end
    local doc, dwhy = docFromCode(code)
    if not doc then return false, dwhy end
    local name = type(opts.name) == 'string' and opts.name ~= '' and DirectorKit.cut(opts.name, 80)
        or (type(doc.name) == 'string' and doc.name ~= '' and DirectorKit.cut(doc.name, 80)) or 'Imported scenario'
    local key = opts.key
    if key ~= nil then
        if type(key) ~= 'string' then return false, 'opts.key is a scenario key' end
        if DirectorStore.get(key) then return false, key .. ' is taken: pick another key' end
    else
        local base = keyFrom(type(doc.key) == 'string' and doc.key or name)
        key = base
        local i = 1
        while DirectorStore.get(key) do
            i = i + 1
            if i > 99 then return false, base .. ' and _2 to _99 are all taken: name a key' end
            key = base .. '_' .. i   -- (the page's Import code does the same: courier, courier_2, ...)
        end
    end
    local gated = Director.gatedChange and Director.gatedChange(nil, doc, nil)
    if gated then return false, gated end
    local missing = shareMissing(doc)
    doc.id, doc.rev, doc.key, doc.requires = nil, nil, nil, nil
    doc.name = name
    local row, cwhy = DirectorStore.create(key, name, doc, nil)
    if not row then return false, cwhy end
    print(('[whip_core:director] %s imported the scenario %s (%s) from a share code: a draft, switched off'):format(by, key, name))
    return true, { key = key, name = name, missing = missing }
end)

exports('GetScenarioShareCode', function(key, rev)
    local why = off()
    if why then return false, why end
    if type(key) ~= 'string' then return false, 'key is the scenario\'s key' end
    local row = DirectorStore.get(key)
    if not row then return false, 'No scenario called ' .. key end
    rev = math.tointeger(tonumber(rev)) or 0
    local doc, got = DirectorStore.revision(key, rev > 0 and rev or row.draftRev)
    if not doc then return false, got end
    doc.id, doc.rev = nil, nil
    doc.key = key
    doc.requires = DirectorPacks.requiresOf(doc)
    local ok, text = pcall(json.encode, doc)
    if not ok or type(text) ~= 'string' then return false, 'That scenario cannot be written down' end
    if #text > SHARE_MAX_BYTES then return false, ('It is over %d KB: too big to share'):format(SHARE_MAX_BYTES // 1024) end
    return 'WDS0.' .. b64url(text)
end)
-- ============================================ (end PROJECT Z PATCH)

cb('save', { { 'key', 'key', 64 }, { 'baseRev', 'int', 0, 1000000000 }, { 'token', 'id' }, { 'note', 'string', 200, '' } },
function(source, _, key, baseRev, token, note)
    local why = off()
    if why then return false, why end
    local doc, uwhy = takeUpload(source, token)
    if not doc then return false, uwhy end
    local pack = DirectorStore.packOf(key)
    if pack then return false, ('A shipped scenario (from %s) is read-only here: Duplicate it to edit'):format(pack) end
    -- A gated card they may not add or change: held to the revision they began from (cards_api.lua).
    local base = baseRev > 0 and DirectorStore.revision(key, baseRev) or nil
    local gated = Director.gatedChange(source, doc, base)
    if gated then return false, gated end
    local rev, swhy = DirectorStore.save(key, baseRev, doc, source, note ~= '' and note or nil)
    if not rev then return false, swhy end
    local _, problems = DirectorGraph.check(doc)
    return { rev = rev, problems = problems }
end, 500)

cb('check', { { 'token', 'id' } }, function(source, _, token)
    local doc, uwhy = takeUpload(source, token)
    if not doc then return false, uwhy end
    local ok, problems = DirectorGraph.check(doc)
    return { ok = ok, problems = problems }
end, 300)

-- SWITCHING OFF ENDS ITS RUNS, and so does switching to another revision (the one on is switched off first:
-- Director.deactivate aborts every run of it). With players in a run, nothing changes until the page has
-- asked: the answer is { ok = false, going = n }, and the page sends the request again with endRuns.
cb('activate', { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 }, { 'endRuns', 'bool', false } },
function(source, _, key, rev, endRuns)
    local why = off()
    if why then return false, why end
    if Director.active[key] and not endRuns then
        local going = runsGoing(key)
        if going > 0 then return { ok = false, going = going } end
    end
    local ok, res = Director.activateStored(key, source, rev > 0 and rev or nil)
    if not ok then
        if type(res) == 'table' then return { ok = false, problems = res } end
        return false, tostring(res)
    end
    return { ok = true, problems = res }
end, 1000)

cb('deactivate', { { 'key', 'key', 64 }, { 'endRuns', 'bool', false } }, function(source, _, key, endRuns)
    local sc = Director.active[key]
    if sc and not endRuns then
        local going = runsGoing(key)
        if going > 0 then return { ok = false, going = going } end
    end
    if not sc then
        -- Off in the world but still meant to be on: a shipped one whose pack is stopped comes back on
        -- with its pack. Switching it off here keeps it off.
        local row = DirectorStore.get(key)
        if row and row.status == 'active' then
            if not DirectorStore.setStatus(key, 'disabled', nil, source) then return false, DB_ERROR end
            Director.scriptSwitched[key] = nil   -- a script had switched it off: a person's choice now
            return { ok = true }
        end
        return false, 'That scenario is not on'
    end
    local ok, why = Director.deactivate(key, 'switched off by an admin', source)
    if not ok then return false, why end
    if sc.dbId then DirectorStore.setStatus(key, 'disabled', nil, source) end
    return { ok = true }
end, 1000)

cb('delete', { { 'key', 'key', 64 } }, function(source, _, key)
    local why = off()
    if why then return false, why end
    if not DirectorStore.get(key) then return false, 'No scenario called ' .. key end
    local sc = Director.active[key]
    if sc and sc.dbId then Director.deactivate(key, 'the scenario was deleted', source) end
    local shipped = DirectorStore.packOf(key)
    local ok, dwhy = DirectorStore.delete(key, source)
    if not ok then return false, dwhy end
    -- Shipped: tombstoned, and never offered again (defaults §10).
    if shipped then DirectorPacks.forget(key, source) end
    editing[key] = nil
    Director.scriptSwitched[key] = nil
    return { ok = true }
end, 1000, ADMIN)

cb('startRun', { { 'key', 'key', 64 } }, function(source, _, key)
    local sc = Director.active[key]
    if not sc then return false, 'Switch it on first' end
    local run, why = Director.startRun(sc, source, { source = source })
    if not run then return false, why end
    return { runId = run.id }
end, 1000)

cb('abort', { { 'runId', 'id' } }, function(_, _, runId)
    if not Director.cutShort(runId, 'stopped by an admin') then return false, 'No such run' end   -- (no cooldown)
    return { ok = true }
end, 500)

-- ============================================
-- A scenario's detail tabs, History restore (the /whip Director section)
-- ============================================

--- Every scenario at once, over the last `days` (the section's Overview: DirectorStore.overview). `scope` narrows it:
--- one scenario (`value` its key), the ones a lore character is in (`value` their key), or the ones a player made
--- (`value` their account's userId).
cb('overview', { { 'days', 'int', 1, 90, 14 }, { 'scope', 'enum', { 'all', 'scenario', 'lore', 'maker' }, 'all' },
                 { 'value', 'string', 64, '' } },
function(_, _, days, scope, value)
    if not DirectorStore.ready then return false, off() or 'The Director is still starting' end
    local ids
    if scope == 'scenario' then
        ids = DirectorStore.idsOf({ value })
    elseif scope == 'lore' then
        if not DirectorLore.scenariosUsing then return false, 'This server cannot say which scenarios a lore character is in' end
        local rows, lwhy = DirectorLore.scenariosUsing(value)
        if not rows then return false, lwhy end
        local keys = {}
        for _, r in ipairs(rows) do keys[#keys + 1] = r.key end
        ids = DirectorStore.idsOf(keys)
    elseif scope == 'maker' then
        local userId = math.tointeger(tonumber(value))
        if not userId then return false, 'That is not a player' end
        ids = DirectorStore.madeBy(userId)
    end
    local o, why = DirectorStore.overview(days, ids)
    if not o then return false, why end
    return o
end, 1000)

cb('players', { { 'key', 'key', 64 } }, function(_, _, key)
    if not DirectorStore.get(key) then return false, 'No scenario called ' .. key end
    return { players = DirectorStore.players(key, 100) }
end, 300)

cb('runs', { { 'key', 'key', 64 }, { 'before', 'int', 0, 2000000000, 0 } }, function(_, _, key, before)
    if not DirectorStore.get(key) then return false, 'No scenario called ' .. key end
    return { runs = DirectorStore.runs(key, before, 50) }
end, 300)

--- The cards of a scenario's draft, by id: what an event's card is called.
local function cardTitles(key)
    local doc = DirectorStore.revision(key)
    local out = {}
    -- (Every variant's: a card copied into another keeps its id, and Variant 1's name for it is kept.)
    for _, v in ipairs(type(doc) == 'table' and DirectorGraph.variantsOf(doc) or {}) do
        for _, n in ipairs(type(v.doc.nodes) == 'table' and v.doc.nodes or {}) do
            if type(n) == 'table' and type(n.id) == 'string' and out[n.id] == nil then
                local def = DirectorNodes.get(n.type)
                out[n.id] = (type(n.label) == 'string' and n.label ~= '' and n.label) or (def and def.title) or n.id
            end
        end
    end
    return out
end

cb('events', { { 'key', 'key', 64 }, { 'runId', 'int', 0, 2000000000, 0 }, { 'before', 'int', 0, 2000000000, 0 } },
function(_, _, key, runId, before)
    if not DirectorStore.get(key) then return false, 'No scenario called ' .. key end
    local list = DirectorStore.events(key, runId, before, 100)
    local titles = cardTitles(key)
    for _, e in ipairs(list) do e.card = e.nodeId and (titles[e.nodeId] or e.nodeId) or nil end
    return { events = list }
end, 300)

--- An old revision back as the draft: a NEW revision with its document (nothing is ever rewritten).
cb('restore', { { 'key', 'key', 64 }, { 'rev', 'int', 1, 1000000000 } }, function(source, _, key, rev)
    local why = off()
    if why then return false, why end
    local row = DirectorStore.get(key)
    if not row then return false, 'No scenario called ' .. key end
    if DirectorStore.packOf(key) then return false, 'A shipped scenario is read-only here: Duplicate it to edit' end
    local doc, dwhy = DirectorStore.revision(key, rev)
    if not doc then return false, dwhy end
    -- Held to the draft it replaces: an old revision cannot bring back a gated card they may not change.
    local gated = Director.gatedChange(source, doc, (DirectorStore.revision(key, row.draftRev)))
    if gated then return false, gated end
    local newRev, swhy = DirectorStore.save(key, row.draftRev, doc, source, ('restored revision %d'):format(rev))
    if not newRev then return false, swhy end
    return { rev = newRev }
end, 1000)

-- ============================================
-- Access: who are builders, Director admins and Dungeon Masters (Director admins only)
-- ============================================

local LIVE = 'director.live'   -- (server/director/live.lua)
local LEVELS = { build = BUILD, admin = ADMIN, live = LIVE }

cb('access', {}, function()
    return { builders = Permissions.holders(BUILD), admins = Permissions.holders(ADMIN), live = Permissions.holders(LIVE),
             ready = Permissions.ready }
end, 500, ADMIN)

--- The account a character is on: the online player's, or the database's.
local function accountOf(charId)
    local p = PlayersByCharId and PlayersByCharId[charId]
    if p and p.userId then return p.userId, p.fullName end
    local ok, rows = pcall(MySQL.query.await,
        'SELECT `userId`, `firstName`, `lastName` FROM `characters` WHERE `charId` = ? AND `deleted` IS NULL', { charId })
    if not ok or not rows or not rows[1] then return nil end
    return tonumber(rows[1].userId), ((rows[1].firstName or '') .. ' ' .. (rows[1].lastName or ''))
end

cb('grant', { { 'charId', 'id' }, { 'level', 'enum', { 'build', 'admin', 'live' } } }, function(source, _, charId, level)
    local name = LEVELS[level]
    if not Permissions.mayGrant(source, name) then return false, 'You may not give that' end
    local userId, who = accountOf(charId)
    if not userId then return false, 'No character with that id' end
    local ok, why = Permissions.grant(userId, name, source)
    if not ok then return false, why end
    return { ok = true, name = who, userId = userId }
end, 1000, ADMIN)

cb('revoke', { { 'userId', 'id' }, { 'level', 'enum', { 'build', 'admin', 'live' } } }, function(source, _, userId, level)
    local name = LEVELS[level]
    if not Permissions.mayGrant(source, name) then return false, 'You may not take that away' end
    local ok, why = Permissions.revoke(userId, name, source)
    if not ok then return false, why end
    return { ok = true }
end, 1000, ADMIN)

-- ============================================
-- Shipped scenarios (server/director/packs.lua)
-- ============================================

local function validRes(s) return type(s) == 'string' and #s >= 1 and #s <= 64 and s:match('^[%w_%-%.]+$') ~= nil end

cb('packs', {}, function()
    return { packs = DirectorPacks.list(), trusted = DirectorPacks.trustedList and DirectorPacks.trustedList() or {} }
end, 300)

cb('accept', { { 'resource', 'string', 64 }, { 'file', 'string', 128 } }, function(source, _, res, file)
    local why = off()
    if why then return false, why end
    if not validRes(res) then return false, 'That is not a resource' end
    local row, awhy, offWhy = DirectorPacks.accept(res, file, source)
    if not row then return false, awhy end
    return { scenario = row, warning = offWhy and ('Accepted, but it is off now: it did not come back on (%s)'):format(offWhy) or nil }
end, 1000, ADMIN)

-- Trust a resource once: its new and changed scenarios are accepted by themselves
-- when they pass Check (still read-only). Or stop trusting it.
cb('trust', { { 'resource', 'string', 64 }, { 'on', 'bool' } }, function(source, _, res, on)
    local why = off()
    if why then return false, why end
    if not validRes(res) then return false, 'That is not a resource' end
    local ok, twhy = DirectorPacks.setTrust(res, on == true, source)
    if not ok then return false, twhy end
    return { ok = true }
end, 1000, ADMIN)

cb('refuse', { { 'resource', 'string', 64 }, { 'file', 'string', 128 } }, function(source, _, res, file)
    if not validRes(res) then return false, 'That is not a resource' end
    local ok, why = DirectorPacks.refuse(res, file, source)
    if not ok then return false, why end
    return { ok = true }
end, 1000, ADMIN)

cb('export', { { 'key', 'key', 64 }, { 'rev', 'int', 0, 1000000000, 0 } }, function(_, _, key, rev)
    local res, why = DirectorPacks.export(key, rev > 0 and rev or nil)
    if not res then return false, why end
    return res
end, 2000, ADMIN)

-- ============================================
-- Test mode
-- ============================================
--
-- The editor's document as it is now (saved or not), played by the admin alone:
--   * its STANDING things are made again for the test, under its own tag (test:<key>:<serial>), so
--     a scenario that is on is refused (its live quest giver would stand where the test's does);
--   * the run is a TEST run: the tester alone, no pay (the Pay card says what it would have paid),
--     and the items it hands out (stamped with the run) are taken back when it ends, as every run's are;
--   * the test map on the tester's screen (client/director.lua, html/js/director/testwin.js) follows the run;
--   * Reset ends the run, takes back what it gave, puts the tester back where the test began, and
--     starts it again; Stop does the same without the restart, and answers the run's trace, which
--     the editor shows as the cards and wires that ran.

local tests = {}        -- [src] = { key, doc, dbId, rev, home, sc, run, flow, dropped, flushing }
local STEP_EVERY_MS = 250

--- Is this player in Test mode (their run going or not)? The Systems Creator asks: one editor's test at
--- a time, as the two share F5 / F9 (server/systems/hub.lua).
function Director.hasTest(src) return tests[src] ~= nil end

--- Is a builder testing this scenario (its Test open, being made or going), or a script testing it
--- (TestDirectorScenario)? Test and switched on shut each other out: a test of one that is on is refused (below), and so
--- is switching on one being tested (Director.activate).
function Director.isTesting(key)
    for _, t in pairs(tests) do if t.key == key then return true end end
    for _, run in ipairs(DirectorRuntime.list()) do
        if run.scenarioId == key and run.test then return true end
    end
    return false
end

--- What a pin is called on its card, for the test window: an answer's text, the card's label, its name.
local function pinText(node, pin)
    if type(pin) ~= 'string' then return nil end
    local def = node and node.def
    -- (An outcome called by a field's words, its card's pinText: a Dialog Line's answer.)
    local by = def and def.pinText and def.pinText[pin]
    local words = by and node.props[by.key]
    if type(words) == 'string' and words ~= '' then return words .. (by.after or '') end
    if def and def.labels and def.labels[pin] then return def.labels[pin] end
    return pin
end

--- One step as the test window has it (client/director.lua, html/js/director/testwin.js): which, when (ms into the run),
--- along which wire, what its outcome is called and why (or what the card said, for a 'log').
local FLOW_MAX = 120   -- steps a flush carries; past that a runaway's are counted, not sent
local function flowOf(run, e)
    local node = run.graph.nodes[e.node]
    return { n = e.n, node = e.node, kind = e.kind, pin = e.pin, from = e.from, fromPin = e.fromPin, text = e.text,
             ms = math.max(0, (e.t or 0) - (run.startedAt or 0)), pinText = e.pin and pinText(node, e.pin) or nil }
end

--- The cards waiting now (each one's outcomes the tester may take), in a fixed order.
local function waitingOf(run)
    local out = {}
    for id, tok in pairs(run.active or {}) do if not tok.dead then out[#out + 1] = id end end
    table.sort(out)
    return out
end

--- The cards a run has yet to enter, its queue between passes (a long chain goes on over several): with the waiting
--- ones, where the run can still go from (the test window greys what it can no longer reach).
local function queuedOf(run)
    local out, seen, q = {}, {}, run.q
    if type(q) ~= 'table' then return out end
    for i = q.first or 1, q.last or 0 do
        local p = q[i]
        if p and p.node and not seen[p.node] then seen[p.node] = true; out[#out + 1] = p.node end
    end
    return out
end

--- Start (or start again) a test's run. Answers true, or false, why and the placed thing it failed on.
local function beginTest(src, t)
    -- Check first, a Reset too: another resource's card that has gone since
    -- the test began is said, never half-run.
    -- (A run that can never succeed is tested all the same: a job half made: DirectorGraph.testable.)
    local _, probs = DirectorGraph.check(t.doc)
    if not DirectorGraph.testable(probs) then
        for _, p in ipairs(probs or {}) do if p.severity == 'error' and not p.live then return false, p.message end end
        return false, 'it no longer passes Check'
    end
    -- A builder in a world of their own (Isolate world, below) tests in it: its NPCs and cars are made
    -- there, its props shown to them alone.
    local bucket = Director.isolated[src]
    local sc, why, worldId = Director.build(t.key, t.doc, { dbId = t.dbId, rev = t.rev, prefix = 'test',
        bucket = bucket, audience = bucket and { people = { src } } or nil })
    if not sc then return false, why, worldId end
    -- (The variant open in their editor: its own cards and things.)
    local run, rwhy = Director.startRun(sc, src, { source = src }, { test = true, variant = t.variant })
    if not run then
        Registry.releaseTag(CORE, sc.tag)
        return false, rwhy
    end
    t.sc, t.run = sc, run
    -- The test window follows every step, what the cards said, which wait now and which are queued: at most four times
    -- a second. The steps up to now are the first send (Scenario Enabled went before this).
    t.flow, t.dropped = {}, 0
    for _, e in ipairs(DirectorRuntime.trace(run)) do t.flow[#t.flow + 1] = flowOf(run, e) end
    local function flush()
        t.flushing = false
        if tests[src] ~= t or t.run ~= run then return end
        local list, dropped = t.flow, t.dropped
        t.flow, t.dropped = {}, 0
        TriggerClientEvent('whip_core:client:directorTestFlow', src, { steps = list, dropped = dropped, waiting = waitingOf(run),
                                                                       queued = queuedOf(run), status = run.status, runId = run.id })
    end
    run.onTrace = function(e)
        if #t.flow < FLOW_MAX then t.flow[#t.flow + 1] = flowOf(run, e) else t.dropped = t.dropped + 1 end
        if t.flushing then return end
        t.flushing = true
        SetTimeout(STEP_EVERY_MS, flush)
    end
    t.flushing = true
    SetTimeout(STEP_EVERY_MS, flush)
    return true
end

--- End what a test made: its run (which takes back what it handed out, as every run's end does:
--- Director.runEnded), and its standing things.
local function endTest(_, t, why)
    local run = t.run
    -- Ended on purpose (Reset, Stop): the test map is told by what asked, not as a run's own end.
    t.ending = true
    if run and run.status == 'running' then DirectorRuntime.abort(run.id, why) end
    t.ending = false
    if t.sc then Registry.releaseTag(CORE, t.sc.tag) end
    t.sc = nil
end

--- A test run ended by itself (Succeed, Fail, a fault): the test map says so; the session stays for
--- Reset or Stop. Called from Director.runEnded.
function Director.testEnded(run, outcome, reason)
    for src, t in pairs(tests) do
        if t.run == run and not t.ending then
            local node = run.faultNode and run.graph.nodes[run.faultNode]
            TriggerClientEvent('whip_core:client:directorTestEnded', src, { outcome = outcome, reason = reason,
                card = node and node.def and node.def.title or run.faultNode, node = run.faultNode })
        end
    end
end

-- The test window (client/director.lua, html/js/director/testwin.js): the tester takes a waiting card's outcome
-- themselves, or goes back to an earlier step and on from another of its outcomes. Their own test's run only.

SecureEvent('whip_core:server:directorTestTake', {
    permission = BUILD, whileDead = true, rateLimit = 300, burst = 4,
    params = { { 'node', 'key', 64 }, { 'pin', 'string', 32 } },
}, function(source, _, node, pin)
    local t = tests[source]
    if not (t and t.run) then return false, 'No test is running' end
    if not DirectorRuntime.take(t.run, node, pin) then return false, 'That card is not waiting now' end
end)

-- ============================================
-- NPC debug in a test (J): what each of the test's NPCs is doing, and why
-- ============================================
--
-- On while a tester has it on and their test runs: once a second, each NPC of their test within NPC_DEBUG_M of them
-- (the run's and the test's standing ones), as Npcs.explain words it, with what the run adds (a talk card waiting on
-- it, the card a task Wait waits for). Their game draws it over the NPC (client/director_npcdebug.lua). Their test
-- ending, or their leaving, ends it.

local npcDebug = {}   -- [src] = true
local npcDebugLooping = false
local NPC_DEBUG_M = 90.0

local function shortText(s, n)
    s = tostring(s or '')
    if #s > n then s = DirectorKit.cut(s, n - 3) .. '...' end
    return s
end

--- The run's say over what Npcs.explain words: a talk card waiting on it, a task Wait's card.
local function refineNpcLine(e, run, wid, talks, src)
    local talk = talks[wid]
    if talk and (e.state == 'idle' or e.state == 'walking' or e.state == 'patrol') then
        local conv = run.convs and run.convs[src]
        e.what = conv and 'Talking with you' or 'Waiting to be talked to'
        -- (A talking card's own words, those that have them: What they say.)
        e.why = talk.def.title .. ((type(talk.props.line) == 'string' and talk.props.line ~= '')
            and (' "' .. shortText(talk.props.line, 40) .. '"') or '')
    end
    local p = e.step and type(e.step.p) == 'table' and e.step.p or nil
    if p and DirectorSteps.waitsOnCard(e.step.t, p) then
        local n = type(p.card) == 'string' and run.graph.nodes[p.card] or nil
        e.what = ('Waiting for a card: %s'):format(n and n.def and n.def.title or tostring(p.card))
    end
end

--- The lines for one tester: { { net, name, what, why, state, reacts } } of their test's NPCs near them.
local function npcDebugList(src, t)
    local run = t.run
    if not run or run.status ~= 'running' then return {} end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return {} end
    local me = GetEntityCoords(ped)
    local function name(s)
        if s == src then return 'you' end
        local p = Players[s]
        return p and p.fullName or ('player ' .. tostring(s))
    end
    local talks = {}
    for nodeId, tok in pairs(run.active or {}) do
        local n = not tok.dead and run.graph.nodes[nodeId] or nil
        if n and n.def and n.def.talks and type(n.props.npc) == 'string' then talks[n.props.npc] = n end   -- (a card that talks)
    end
    local out, seen = {}, {}
    local function add(wid, h)
        local w = run.graph.world[wid]
        if not (w and w.kind == 'npc' and type(h) == 'table') then return end
        for _, id in ipairs(DirectorNodes.npcIds(h)) do
            local info = not seen[id] and Npcs.get(id) or nil
            seen[id] = true
            local c = info and info.coords
            if info and c and info.netId and #(vector3(c.x, c.y, c.z) - me) <= NPC_DEBUG_M then
                local e = Npcs.explain(id, name)
                if e then
                    refineNpcLine(e, run, wid, talks, src)
                    out[#out + 1] = { net = info.netId, name = shortText(w.label or wid, 32), what = e.what, why = e.why,
                                      state = e.state, reacts = e.reacts }
                end
            end
        end
    end
    for wid, h in pairs(run.world or {}) do add(wid, h) end
    for wid, h in pairs(t.sc and t.sc.standing or {}) do add(wid, h) end
    return out
end

local function npcDebugTick()
    if next(npcDebug) == nil then npcDebugLooping = false return end
    for src in pairs(npcDebug) do
        local t = tests[src]
        if not (t and t.run) then
            npcDebug[src] = nil
            TriggerClientEvent('whip_core:client:directorNpcDebug', src, false)
        else
            local ok, list = pcall(npcDebugList, src, t)
            if not ok then print(('[whip_core:director] NPC debug for %d: %s'):format(src, tostring(list))) list = {} end
            TriggerClientEvent('whip_core:client:directorNpcDebug', src, list)
        end
    end
    SetTimeout(1000, npcDebugTick)
end

SecureEvent('whip_core:server:directorNpcDebug', {
    permission = BUILD, whileDead = true, rateLimit = 300, burst = 4,
    params = { { 'on', 'bool' } },
}, function(source, _, on)
    if on and not tests[source] then return false, 'No test is running' end
    npcDebug[source] = on == true or nil
    if not on then TriggerClientEvent('whip_core:client:directorNpcDebug', source, false) return end
    if not npcDebugLooping then
        npcDebugLooping = true
        SetTimeout(0, npcDebugTick)
    end
end)

AddEventHandler('playerDropped', function() npcDebug[source] = nil end)

--- Back to step `seq` (where the run reached `node`), on from its `pin`. What cards after it made goes from the world
--- (Josh: the run can make it again); variables, what was handed out and the player stay. { ok, removed }.
cb('testRewind', { { 'seq', 'int', 1, 1000000000, 1 }, { 'node', 'key', 64 }, { 'pin', 'string', 32, '' } },
function(source, _, seq, node, pin)
    local t = tests[source]
    local run = t and t.run
    if not run then return false, 'No test is running' end
    if run.status ~= 'running' then return false, 'The run is over: F5 starts the test again' end
    local ok, made = DirectorRuntime.rewind(run, seq, node, pin)
    if not ok then return false, made end
    local ctx = DirectorRuntime.ctxOf(run, node)
    local removed = 0
    for _, m in ipairs(made) do
        -- (A car claimed is the player's own now: it stays, as Remove leaves it.)
        if not m.h.claimed then
            removed = removed + 1
            CreateThread(function() DirectorNodes.removeMade(ctx, m.id, m.h) end)
        end
    end
    return { ok = true, removed = removed }
end, 500)

cb('test', { { 'key', 'key', 64 }, { 'token', 'id' }, { 'variant', 'string', 16, '' } }, function(source, _, key, token, variant)
    local why = off()
    if why then return false, why end
    local doc, uwhy = takeUpload(source, token)
    if not doc then return false, uwhy end
    local row = DirectorStore.get(key)
    if not row then return false, 'No scenario called ' .. key end
    -- A Systems Creator test of theirs owns the strip and F5 / F9 too: one at a time.
    if Systems and Systems.tests and Systems.tests[source] then
        return false, 'A Systems test is running: stop it first (in /systems)'
    end
    if Director.active[key] then
        return false, 'It is on: switch it off to test it (its live things stand where the test\'s would)'
    end
    -- A gated card they may not add or change, tested as changed: held to the draft (cards_api.lua).
    local gated = Director.gatedChange(source, doc, (DirectorStore.revision(key, row.draftRev)))
    if gated then return false, gated end
    -- (Asked again after that read: switched on meanwhile.)
    if Director.active[key] then
        return false, 'It is on: switch it off to test it (its live things stand where the test\'s would)'
    end
    local _, problems = DirectorGraph.check(doc)
    if not DirectorGraph.testable(problems) then return { ok = false, problems = problems } end
    if tests[source] then
        endTest(source, tests[source], 'a new test started')
        tests[source] = nil
    end
    local ped = GetPlayerPed(source)
    local c = GetEntityCoords(ped)
    local t = { key = key, doc = doc, dbId = row.id, rev = row.draftRev, variant = variant ~= '' and variant or nil,
                home = { x = c.x, y = c.y, z = c.z, heading = GetEntityHeading(ped) } }
    tests[source] = t
    local started, swhy, worldId = beginTest(source, t)
    if not started then
        tests[source] = nil
        -- As a problem, tied to the placed thing and the cards that name it.
        return { ok = false, problems = Director.buildProblem(doc, swhy, worldId) }
    end
    return { ok = true, runId = t.run.id, name = doc.name or key }
end, 1000)

cb('testStop', {}, function(source)
    local t = tests[source]
    if not t then return { trace = {} } end
    local run = t.run
    endTest(source, t, 'the test was stopped')
    tests[source] = nil
    return { trace = run and DirectorRuntime.trace(run) or {}, outcome = run and run.status or nil,
             reason = run and run.reason or nil, faultNode = run and run.faultNode or nil }
end, 300, false)   -- their own test: ended even if they no longer build

-- No permission key: a builder who lost access mid-test still gets their test ENDED by F5 (its NPCs
-- and cars go), only not started again.
SecureEvent('whip_core:server:directorTestReset', { whileDead = true, rateLimit = 1000, burst = 2 }, function(source)
    local t = tests[source]
    if not t then return false, 'No test is running' end
    if not Permissions.has(source, BUILD) then
        endTest(source, t, 'they no longer have Director access')
        tests[source] = nil
        -- What a reset that could not start again says: their game leaves Test mode.
        TriggerClientEvent('whip_core:client:directorTestReset', source, false, 'you no longer have Director access')
        return
    end
    -- One reset at a time: a second F5 inside the 1.2 s would schedule a second start and leave the
    -- first one's run and standing things with nothing to end them.
    if t.resetting then return false, 'It is starting again already' end
    t.resetting = true
    endTest(source, t, 'reset')
    t.run = nil
    local h = t.home
    -- The client's own teleport (client/main.lua): a fade, and the ground loaded first.
    TriggerClientEvent('whip_core:client:fadeTeleport', source, h.x, h.y, h.z, h.heading)
    SetTimeout(1200, function()
        t.resetting = nil
        if tests[source] ~= t then return end
        local ok, why = beginTest(source, t)
        if not ok then tests[source] = nil end
        TriggerClientEvent('whip_core:client:directorTestReset', source, ok, why)
    end)
end)

local function stopTestOf(src)
    local t = tests[src]
    if not t then return end
    endTest(src, t, 'the tester left')
    tests[src] = nil
end

-- ============================================
-- Isolate world
-- ============================================
--
-- The builder goes to a routing bucket of their own (ISOLATE_BASE + their server id, clear of
-- character select's 1000 + it), with no traffic or pedestrians: other players, their voices and the
-- shared world's NPCs and cars are gone. Director.isolated[src] holds it (main.lua).
--   * A test there is made in it (beginTest: Director.build's bucket): its NPCs and cars at birth, its
--     props shown to them alone. What has no bucket stays the shared world's: ground items, containers
--     and doors.
--   * No live run while isolated (Director.startRun), and nobody isolated is put in one.
--   * Builders are trusted: the shared world's stashes, doors and shops still work.
--   * In only from the shared world (bucket 0), on foot and in no job: a car does not follow its driver
--     across, and a job's things stay where they are. A held prop never follows a bucket move (FiveM
--     #912), so it is dropped first, both ways.
--   * Not to slip away: never while down, being escorted or escorting someone (mid-robbery or
--     mid-arrest). Coming BACK is allowed in every state.
--   * Back to the shared world when they press it again or close the Director, and always on logout,
--     leaving, losing Director access, and whip_core stopping. A test
--     keeps it: the editor is only hidden. Only someone still in their bucket is moved: one moved since
--     (logout's character screen, another resource) is left where they are.

local ISOLATE_BASE = 100000

--- Back to the shared world. `leaving`: they are going (no move, nobody to tell).
local function unisolate(src, leaving)
    local bucket = Director.isolated[src]
    if not bucket then return end
    Director.isolated[src] = nil
    if leaving then return end
    if GetPlayerRoutingBucket(src) == bucket then
        if HeldProps then HeldProps.drop(src) end
        SetPlayerRoutingBucket(src, 0)
    end
    TriggerClientEvent('whip_core:client:directorIsolated', src, false)
end

cb('isolate', { { 'on', 'bool' } }, function(source, player, on)
    if not on then
        unisolate(source)
        return { isolated = false }
    end
    if Director.isolated[source] then return { isolated = true } end
    if tests[source] then return false, 'Stop the test first' end
    if GetPlayerRoutingBucket(source) ~= 0 then return false, 'You are not in the shared world just now' end
    -- Not to slip away: the server's own word on each, never a bag a client could write.
    if player and player.isDead then return false, 'Not while you are down' end
    if Sentinel.getTruth(source, PLAYER_ESCORTED_KEY) then return false, 'Not while you are being escorted' end
    for s in pairs(Players) do
        if s ~= source and Sentinel.getTruth(s, PLAYER_ESCORTER_KEY) == source then
            return false, 'Not while you are escorting someone'
        end
    end
    local ped = GetPlayerPed(source)
    if ped and ped ~= 0 and GetVehiclePedIsIn(ped, false) ~= 0 then
        return false, 'Get out of the car first: it would stay behind'
    end
    for _, run in ipairs(DirectorRuntime.list()) do
        if run.players[source] and not run.test then return false, 'You are in a job: finish it first' end
    end
    local bucket = ISOLATE_BASE + source
    if HeldProps then HeldProps.drop(source) end
    SetRoutingBucketPopulationEnabled(bucket, false)
    SetPlayerRoutingBucket(source, bucket)
    Director.isolated[source] = bucket
    TriggerClientEvent('whip_core:client:directorIsolated', source, true)
    return { isolated = true }
end, 1000)

-- Every couple of seconds, while anyone is isolated: one who lost Director access (any way: a
-- permission taken, dev tools taken back) comes back, their test ended; one moved out of their bucket
-- by something else is no longer counted as isolated.
Every('director-isolated', 2000, function()
    for src, bucket in pairs(Director.isolated) do
        if not Players[src] then
            Director.isolated[src] = nil
        elseif GetPlayerRoutingBucket(src) ~= bucket then
            Director.isolated[src] = nil
            TriggerClientEvent('whip_core:client:directorIsolated', src, false)
        elseif not Permissions.has(src, BUILD) then
            if tests[src] then
                stopTestOf(src)
                TriggerClientEvent('whip_core:client:directorTestReset', src, false, 'you no longer have Director access')
            end
            unisolate(src)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= CORE then return end
    for src in pairs(Director.isolated) do unisolate(src) end
end)

-- ============================================
-- Live pulses
-- ============================================
--
-- A builder with a scenario open sees its LIVE runs go: each card a run enters lights, and the wire
-- it came along pulses. The run's trace steps are gathered per scenario and sent to whoever has it
-- open at most four times a second, the newest PULSE_MAX of them (a busy run sends the latest, not a
-- backlog). Nothing is gathered while nobody has it open. Card ids are the active revision's: in a
-- draft that has moved on, a card that is not there any more lights nothing.

local PULSE_MAX = 40
local pulses = {}   -- [key] = { steps = { ... }, flushing }

function Director.livePulse(run, e)
    local key = run.scenarioId
    local watching = editing[key]
    -- (What a card said is the test window's, not a card lighting.)
    if not watching or next(watching) == nil or type(e) ~= 'table' or e.kind == 'log' then return end
    local p = pulses[key]
    if not p then p = { steps = {} }; pulses[key] = p end
    local steps = p.steps
    -- (Which variant's cards: the editor lights only the one open.)
    steps[#steps + 1] = { node = e.node, pin = e.pin, kind = e.kind, from = e.from, fromPin = e.fromPin, run = run.id,
                          variant = run.variant }
    if #steps > PULSE_MAX then table.remove(steps, 1) end
    if p.flushing then return end
    p.flushing = true
    SetTimeout(STEP_EVERY_MS, function()
        p.flushing = false
        local list = p.steps
        p.steps = {}
        if #list == 0 then return end
        for src in pairs(editing[key] or {}) do
            -- A builder whose access was taken away while the editor was open sees no more.
            if Players[src] and Permissions.has(src, BUILD) then
                TriggerClientEvent('whip_core:client:directorPulse', src, key, list)
            end
        end
        if not editing[key] then pulses[key] = nil end
    end)
end

-- ============================================
-- Who has what open
-- ============================================

local function closed(src)
    uploads[src] = nil
    for k, list in pairs(editing) do
        list[src] = nil
        if next(list) == nil then editing[k] = nil end
    end
end

-- No permission needed: it only forgets what the sender had open (a builder whose access was taken
-- away while the editor was open must still be able to close it). Closing the Director ends Isolate
-- world too; a test does not send this (the editor is only hidden).
SecureEvent('whip_core:server:directorClosed', { whileDead = true, rateLimit = 200, burst = 5 }, function(source)
    closed(source)
    unisolate(source)
end)

AddEventHandler('playerDropped', function()
    closed(source)
    stopTestOf(source)
    unisolate(source, true)
end)
Character.onLife('logout', function(e)
    if e and e.source then
        closed(e.source)
        stopTestOf(e.source)
        unisolate(e.source)
    end
end)

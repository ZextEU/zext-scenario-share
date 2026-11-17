-- Share codes, read and written: base64url, and inflate for "WDS1." codes (what a page's
-- CompressionStream('deflate') makes). Nothing here talks to whip_core; server/main.lua does.
--
--   WDS1.<base64url(zlib(JSON))>   what the screen makes
--   WDS0.<base64url(JSON)>         not deflated: what GetScenarioShareCode makes (no deflate in Lua)
--   ZX-XXXXXXX                     a short code: the hub (convar zext_share_hub) holds the long one

Codec = {}

Codec.MAX_BYTES = 512 * 1024   -- a scenario document's limit (whip_core's shipped-file limit)
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
    local ok, text = pcall(inflate, s, 3, Codec.MAX_BYTES)
    if not ok then return nil, text == 'too big' and 'That code is too big' or 'That code is broken: part of it is missing' end
    return text
end

Codec.b64url = b64url

local SHORT_CODE = '^[Zz][Xx]%-?[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z]+$'
local HUB_DEFAULT = 'https://zext-scenario-hub.whipshare.workers.dev'

--- The hub short codes are looked up at ('' = short codes off).
function Codec.hubUrl()
    return (GetConvar('zext_share_hub', HUB_DEFAULT):gsub('/+$', ''))
end

--- A short code's long code, from the hub (WAITS).
local function hubLookup(short)
    local base = Codec.hubUrl()
    if base == '' then return nil, 'Short codes are off on this server (zext_share_hub is ""): use the long code' end
    local p = promise.new()
    PerformHttpRequest(base .. '/v1/codes/' .. short:upper(), function(status, body)
        p:resolve({ status = status, body = body })
    end, 'GET', '', { ['Accept'] = 'application/json' })
    local r = Citizen.Await(p)
    if r.status == 404 then return nil, 'No scenario has the code ' .. short:upper() end
    if r.status ~= 200 or type(r.body) ~= 'string' then return nil, ('The scenario hub did not answer (%s)'):format(tostring(r.status)) end
    local ok, d = pcall(json.decode, r.body)
    if not ok or type(d) ~= 'table' or type(d.code) ~= 'string' then return nil, 'The scenario hub sent back nothing usable' end
    return d.code
end

--- A short code, a long code or a scenario's JSON text into a document table, or nil and why. WAITS for a short code.
function Codec.decode(code)
    if type(code) ~= 'string' or code == '' then return nil, 'A code is a share code (ZX-... or WDS1....) or a scenario\'s JSON' end
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
    if #raw > Codec.MAX_BYTES then return nil, 'That code is too big' end
    local ok, doc = pcall(json.decode, raw)
    if not ok or type(doc) ~= 'table' then return nil, 'That code is broken: it is not a scenario' end
    if type(doc.nodes) ~= 'table' then return nil, 'That is not a scenario (it has no cards)' end
    return doc
end

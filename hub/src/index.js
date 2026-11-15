// Zext Scenario Hub: short codes for WHIP Director share codes.
//
// A share code (WDS1. + deflated JSON, base64url; see whip_core html/js/wp/director.js, PROJECT Z PATCH) is long.
// The hub stores one and hands back a short code like ZX-4F9K2QH that any WHIP server's Scenarios > Import code
// turns back into the long one. The game's page (NUI) calls the hub straight from the builder's game.
//
//   POST   /v1/codes        body: the long code (text). -> 201 { id, name, cards, things, existed }
//   GET    /v1/codes/:id    -> 200 { id, code, name, description, cards, things, createdAt } | 404
//   DELETE /v1/codes/:id    Authorization: Bearer <ADMIN_TOKEN>. Takes one down (abuse).
//   GET    /                a line saying what this is
//
// Codes never change once stored, and the same long code always gets the same short one.
// Uploads are limited per address (UPLOADS_PER_HOUR) and in size (MAX_CODE_CHARS).

const ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';   // Crockford base32: no I, L, O, U
const ID_LEN = 7;
const ID_RE = /^ZX-?([0-9A-HJKMNP-TV-Z]{7})$/;
const CODE_RE = /^WDS([01])\.([A-Za-z0-9_-]+)$/;
const MAX_CODE_CHARS = 1_000_000;
const MAX_JSON_BYTES = 512 * 1024;   // whip_core's own limit for a scenario document
const UPLOADS_PER_HOUR = 20;

const CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    'Access-Control-Max-Age': '86400',
};

function json(status, body) {
    return new Response(JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json; charset=utf-8', ...CORS },
    });
}
const fail = (status, error) => json(status, { error });

function unb64url(text) {
    const s = atob(text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4));
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
}

/** Inflate, refusing to grow past `limit` bytes (a small code must not unpack into gigabytes). */
async function inflate(bytes, limit) {
    const reader = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate')).getReader();
    const parts = [];
    let size = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.length;
        if (size > limit) { await reader.cancel(); throw new Error('too big'); }
        parts.push(value);
    }
    const out = new Uint8Array(size);
    let at = 0;
    for (const p of parts) { out.set(p, at); at += p.length; }
    return out;
}

/** The scenario a long code holds, or throws with the words to send back. */
async function readCode(code) {
    const m = CODE_RE.exec(code);
    if (!m) throw new Error('That is not a scenario code (one starts with WDS1.)');
    let bytes;
    try { bytes = unb64url(m[2]); } catch { throw new Error('That code is broken'); }
    if (m[1] === '1') {
        try { bytes = await inflate(bytes, MAX_JSON_BYTES); } catch (e) {
            throw new Error(e.message === 'too big' ? 'That scenario is over 512 KB' : 'That code is broken');
        }
    } else if (bytes.length > MAX_JSON_BYTES) throw new Error('That scenario is over 512 KB');
    let doc;
    try { doc = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new Error('That code does not read as a scenario'); }
    if (!doc || typeof doc !== 'object' || Array.isArray(doc) || !Array.isArray(doc.nodes)) throw new Error('That code does not hold a scenario');
    return doc;
}

const text = (v, n) => (typeof v === 'string' ? v.slice(0, n) : '');

async function sha256(textIn) {
    const d = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(textIn)));
    return [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function newId() {
    const r = crypto.getRandomValues(new Uint8Array(ID_LEN));
    let s = '';
    for (const b of r) s += ALPHABET[b & 31];
    return s;
}

const show = (id) => 'ZX-' + id;

async function upload(request, env) {
    const len = Number(request.headers.get('Content-Length') || 0);
    if (len > MAX_CODE_CHARS + 1024) return fail(413, 'That code is too big');
    const body = (await request.text()).replace(/\s+/g, '');
    if (!body) return fail(400, 'Send a scenario code');
    if (body.length > MAX_CODE_CHARS) return fail(413, 'That code is too big');

    let doc;
    try { doc = await readCode(body); } catch (e) { return fail(400, e.message); }

    const hash = await sha256(body);
    const same = await env.DB.prepare('SELECT id, name, cards, things FROM codes WHERE hash = ?').bind(hash).first();
    if (same) return json(200, { id: show(same.id), name: same.name, cards: same.cards, things: same.things, existed: true });

    // Per address, by a hash of it (the address itself is never stored).
    const who = await sha256((request.headers.get('CF-Connecting-IP') || 'unknown') + '|' + (env.IP_SALT || ''));
    const since = Date.now() - 3600_000;
    const recent = await env.DB.prepare('SELECT COUNT(*) AS n FROM codes WHERE uploader = ? AND created_at > ?').bind(who, since).first();
    if (recent && recent.n >= UPLOADS_PER_HOUR) return fail(429, 'Too many uploads from here: try again in an hour');

    const name = text(doc.name, 80) || 'A scenario';
    const description = text(doc.description, 500);
    const cards = doc.nodes.length;
    const things = Array.isArray(doc.world) ? doc.world.length : 0;
    for (let tries = 0; tries < 5; tries++) {
        const id = newId();
        try {
            await env.DB.prepare(`INSERT INTO codes (id, hash, code, name, description, cards, things, uploader, created_at)
                                  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`)
                .bind(id, hash, body, name, description, cards, things, who, Date.now()).run();
            return json(201, { id: show(id), name, cards, things, existed: false });
        } catch (e) {
            // The same code stored a moment ago by someone else: theirs is the one.
            const raced = await env.DB.prepare('SELECT id, name, cards, things FROM codes WHERE hash = ?').bind(hash).first();
            if (raced) return json(200, { id: show(raced.id), name: raced.name, cards: raced.cards, things: raced.things, existed: true });
            // Otherwise the id was taken: try another.
        }
    }
    return fail(500, 'Could not store it: try again');
}

async function fetchOne(idText, env) {
    const m = ID_RE.exec(idText.toUpperCase());
    if (!m) return fail(400, 'A short code looks like ZX-4F9K2QH');
    const row = await env.DB.prepare('SELECT id, code, name, description, cards, things, created_at FROM codes WHERE id = ?')
        .bind(m[1]).first();
    if (!row) return fail(404, 'No scenario has that code');
    return json(200, { id: show(row.id), code: row.code, name: row.name, description: row.description,
        cards: row.cards, things: row.things, createdAt: new Date(row.created_at).toISOString() });
}

async function remove(idText, request, env) {
    const auth = request.headers.get('Authorization') || '';
    if (!env.ADMIN_TOKEN || auth !== 'Bearer ' + env.ADMIN_TOKEN) return fail(401, 'Not allowed');
    const m = ID_RE.exec(idText.toUpperCase());
    if (!m) return fail(400, 'A short code looks like ZX-4F9K2QH');
    const r = await env.DB.prepare('DELETE FROM codes WHERE id = ?').bind(m[1]).run();
    return json(200, { removed: (r.meta && r.meta.changes) || 0 });
}

export default {
    async fetch(request, env) {
        if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
        const url = new URL(request.url);
        const path = url.pathname.replace(/\/+$/, '');
        try {
            if (path === '' && request.method === 'GET') {
                return new Response('Zext Scenario Hub: short codes for WHIP Director scenarios.\n', { headers: CORS });
            }
            if (path === '/v1/codes' && request.method === 'POST') return await upload(request, env);
            const one = /^\/v1\/codes\/([^/]+)$/.exec(path);
            if (one && request.method === 'GET') return await fetchOne(decodeURIComponent(one[1]), env);
            if (one && request.method === 'DELETE') return await remove(decodeURIComponent(one[1]), request, env);
            return fail(404, 'Nothing here');
        } catch (e) {
            return fail(500, 'The hub went wrong: try again');
        }
    },
};

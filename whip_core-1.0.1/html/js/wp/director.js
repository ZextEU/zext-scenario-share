// ========================================
// /whip GROUP — Director
//
// Managing the Director lives here, whole, as a group of its own in /whip's header; building a scenario is the
// world builder's (Edit opens it on one, the Blueprint window's Fullscreen the full editor). Its pages are the
// group's tabs, one section each (ids below), sharing one state:
//
//   Overview         (director) every scenario at once, over a period, or only some (Showing: one scenario, the
//                    ones a lore character is in, the ones a player made): what it paid, runs and how they went,
//                    who plays, a run a day, the most run, who plays most, why runs fail, and the newest runs
//                    (one opens what its players did in it)
//   Scenarios        (directorScenarios) every scenario, and one's page: its description, who made it, its things
//                    on the map, Active (on or off), and its Previous Versions (with Restore). New scenario and
//                    Duplicate make one.
//   Lore characters  (directorLore) the story's named people: wp/lore.js, a page of its own (each one's dashboard)
//   Shipped          (directorShipped) scenarios resources bring (server/director/packs.lua): found, pending,
//                    accepted, and what a server is missing to run one
//   Live runs        (directorRuns) going now, with Stop, and scenarios switched on from a file (/director load)
//   Access           (directorAccess) Director builders, admins and Dungeon Masters: a Director admin's tab
//   Dungeon Mode     (directorLive) a Dungeon Master's (director.live): Start Dungeon Mode opens the world builder on
//                    the live world (client/director_live.lua), and what I made is listed, with Remove; an admin sees
//                    everyone's (server/director/live.lua)
//
// A Director BUILDER sees this group and nothing else in /whip (server/permissions.lua panelSections), and a Dungeon
// Master its Dungeon Mode page alone; every action here is gated on the server by the same permissions, so a button
// shown is only a convenience.
// Every request goes through tools/panel_sections/director.lua (wpDirector) to the hub's callbacks.
// ========================================

import { WhipPanel, WP } from '../whip-panel.js';
import { nuiCallback } from '../utils.js';
import { dateTime, ago, money, plural } from './format.js';
import { avatar } from './pickers.js';
import { loreLinks } from './lore.js';
import { placeMarks, placeCard, takeLines } from './places.js';
import { primeLorePortraits } from '../lore-faces.js';

// The group's section ids, by page.
const SEC = { overview: 'director', scenarios: 'directorScenarios', lore: 'directorLore', shipped: 'directorShipped',
              runs: 'directorRuns', access: 'directorAccess', live: 'directorLive' };

const st = {
    hub: null,          // the list answer
    sel: null,          // the scenario key shown
    search: '',         // the Scenarios page's search
    days: 14,           // the Overview's period
    ovScope: 'all',     // ...and what it shows: all, scenario, lore or maker
    ovValue: '',        // which (a scenario's key, a lore character's key, a maker's account id)
    ov: null,           // the Overview's answer
    ovWhy: null,        // why there is none
    places: {},         // [key] = { rev, data: { places, creator } | null, why }: a scenario's map, by its newest revision
    placesFor: null,    // 'key:rev' being read now
    takePaths: {},      // ['key:takeId'] = a promise of its drive as a line ({ x1, y1, ... }), read once (takeLines)
};
// Every page's pieces, each set by its own section's render (they live as long as the panel's skeleton).
const els = {};
const showing = (page) => WhipPanel.activeSection() === SEC[page];

async function call(op, args) {
    const r = await nuiCallback('wpDirector', { op, args: args || {} });
    if (r && r.ok) return { ok: true, data: r.data || {} };
    return { ok: false, why: (r && r.why) || 'No answer from the server' };
}

const arr = (v) => (Array.isArray(v) ? v : (v && typeof v === 'object' ? Object.values(v) : []));

function took(s) {
    if (typeof s !== 'number') return '—';
    return s >= 60 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${s}s`;
}

/** A key from a name: letters, digits and _ (what the server takes). */
function slug(text) {
    return String(text || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
}
const KEY_OK = /^[A-Za-z0-9_-]{2,64}$/;

const OUTCOME = { succeeded: 'Succeeded', failed: 'Failed', aborted: 'Called off', faulted: 'Went wrong', running: 'Going', left: 'Left' };
const OUTCOME_PILL = { succeeded: 'wp-pill-ok', failed: 'wp-pill-err', faulted: 'wp-pill-err', aborted: 'wp-pill-warn', running: 'wp-pill-accent' };

function pill(text, cls) { return WP.el('span', 'wp-pill ' + (cls || ''), text); }

/** A table: headers, and rows of cells (text or an element). `rowAction` makes rows clickable, and its first cell a
 *  button doing the same, so the keyboard reaches each row too. */
function table(headers, rows, rowAction) {
    const wrap = WP.el('div', 'wp-table-wrap');
    const t = WP.el('table', 'wp-table');
    const head = WP.el('tr');
    for (const h of headers) head.appendChild(WP.el('th', null, h));
    const thead = WP.el('thead');
    thead.appendChild(head);
    t.appendChild(thead);
    const body = WP.el('tbody');
    rows.forEach((cells, i) => {
        const tr = WP.el('tr');
        if (rowAction) {
            tr.className = 'wp-table-row-click';
            tr.dataset.action = rowAction.action;
            tr.dataset.arg = String(rowAction.arg(i));
        }
        cells.forEach((c, n) => {
            const td = WP.el('td');
            if (c instanceof Node) td.appendChild(c);
            else {
                const text = c === undefined || c === null ? '' : String(c);
                if (rowAction && n === 0) {
                    const go = WP.el('button', 'wd-row-go', text);
                    go.type = 'button';
                    go.dataset.action = rowAction.action;
                    go.dataset.arg = tr.dataset.arg;
                    td.appendChild(go);
                } else td.textContent = text;
                td.title = text;   // a cut-off cell is read in full on hover
            }
            tr.appendChild(td);
        });
        body.appendChild(tr);
    });
    t.appendChild(body);
    wrap.appendChild(t);
    return wrap;
}

function pct(s) {
    const finished = (s.runs || 0) - (s.calledOff || 0);
    return finished > 0 ? Math.round((s.succeeded / finished) * 100) + '%' : '—';
}

const admin = () => !!(st.hub && st.hub.admin);

// ============================================================
// Overview: every scenario at once
// ============================================================

const PERIODS = [{ key: 7, label: '7 days' }, { key: 14, label: '14 days' }, { key: 30, label: '30 days' }, { key: 90, label: '90 days' }];
const WEEKDAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** A name, its number, a line under it, and a bar for its share of the biggest. `action`: a click goes there. */
function tallies(list, name, value, sub, action, arg) {
    const box = WP.el('div', 'wp-tallies');
    const max = list.reduce((m, x) => Math.max(m, value(x)), 0) || 1;
    for (const x of list) {
        const go = action && arg(x) !== null;
        const el = WP.el(go ? 'button' : 'div', 'wp-tally');
        if (go) {
            el.type = 'button';
            el.dataset.action = action;
            el.dataset.arg = arg(x);
        }
        el.appendChild(WP.el('span', 'wp-tally-name', name(x)));
        el.appendChild(WP.el('span', 'wp-tally-value', String(value(x))));
        if (sub) el.appendChild(WP.el('span', 'wp-tally-sub', sub(x)));
        const bar = WP.el('span', 'wp-tally-bar');
        const fill = WP.el('span');
        fill.style.width = Math.max(2, Math.round((value(x) / max) * 100)) + '%';
        bar.appendChild(fill);
        el.appendChild(bar);
        box.appendChild(el);
    }
    return box;
}

const two = (n) => String(n).padStart(2, '0');
const dayKey = (d) => `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())}`;

/** Every day of the period, oldest first, a quiet one a zero: { label, runs, succeeded, failed, calledOff }. Counted
 *  back from the database's today (o.today, 'YYYY-MM-DD': its days are grouped in its own time zone), else this PC's. */
function everyDay(o) {
    const byDay = new Map(arr(o.days).map((x) => [x.day, x]));
    const out = [];
    const m = typeof o.today === 'string' && o.today.match(/^(\d{4})-(\d{2})-(\d{2})$/);
    const now = new Date();
    const [ty, tm, td] = m ? [Number(m[1]), Number(m[2]) - 1, Number(m[3])] : [now.getFullYear(), now.getMonth(), now.getDate()];
    for (let i = (o.period || st.days) - 1; i >= 0; i--) {
        const d = new Date(ty, tm, td - i, 12);
        const x = byDay.get(dayKey(d)) || {};
        out.push({ label: `${WEEKDAY[d.getDay()]} ${d.getDate()}`, runs: x.runs || 0, succeeded: x.succeeded || 0,
                   failed: x.failed || 0, calledOff: x.calledOff || 0 });
    }
    return out;
}

/** A run a day, as stacked bars: succeeded, failed, the rest (called off, still going). Pointing at a day says it; so
 *  do the arrow keys while the chart has focus. */
function runsChart(host, days, readout, idle) {
    const say = (d) => d.runs ? `${d.label}:  ${plural(d.runs, 'run')}  ·  ${d.succeeded} succeeded  ·  ${d.failed} failed`
        + `  ·  ${d.calledOff} called off` : `${d.label}:  no runs`;
    const hits = [];
    const W = Math.max(320, host.clientWidth || 900), H = 180;
    const L = 40, R = 8, T = 10, B = 24;
    const max = Math.max(1, ...days.map((d) => d.runs));
    const plotH = H - T - B, k = plotH / max, bw = (W - L - R) / days.length, gap = Math.min(3, bw * 0.15);
    const root = WP.svg('svg', { class: 'wp-chart', viewBox: `0 0 ${W} ${H}`, width: W, height: H });
    root.appendChild(WP.svg('line', { class: 'wp-chart-grid', x1: L, x2: W - R, y1: T, y2: T }));
    root.appendChild(WP.svg('text', { x: L - 8, y: T + 4, 'text-anchor': 'end' }, String(max)));
    root.appendChild(WP.svg('text', { x: L - 8, y: H - B + 4, 'text-anchor': 'end' }, '0'));
    const step = days.length <= 8 ? 1 : days.length <= 16 ? 2 : days.length <= 31 ? 4 : Math.ceil(days.length / 8);
    days.forEach((d, i) => {
        const x = L + i * bw;
        let y = H - B;
        const rest = Math.max(0, d.runs - d.succeeded - d.failed);
        for (const [n, cls] of [[d.succeeded, 'wd-chart-ok'], [d.failed, 'wd-chart-bad'], [rest, 'wd-chart-off']]) {
            if (n <= 0) continue;
            root.appendChild(WP.svg('rect', { class: cls, x: x + gap, y: y - n * k, width: Math.max(1, bw - gap * 2), height: n * k }));
            y -= n * k;
        }
        if (i % step === 0) root.appendChild(WP.svg('text', { x: x + bw / 2, y: H - 6, 'text-anchor': 'middle' }, d.label));
        const hit = WP.svg('rect', { class: 'wp-chart-hit', x, y: T, width: bw, height: plotH });
        hit.addEventListener('mouseenter', () => { readout.textContent = say(d); });
        hit.addEventListener('mouseleave', () => { readout.textContent = idle; });
        hits.push(hit);
        root.appendChild(hit);
    });
    root.appendChild(WP.svg('line', { class: 'wp-chart-zero', x1: L, x2: W - R, y1: H - B, y2: H - B }));
    host.appendChild(root);
    // The keyboard: Tab onto the chart, then Left and Right walk the days (the newest first), the day lit.
    let at = -1;
    const show = (i) => {
        if (hits[at]) hits[at].classList.remove('on');
        at = Math.max(0, Math.min(days.length - 1, i));
        hits[at].classList.add('on');
        readout.textContent = say(days[at]);
    };
    host.tabIndex = 0;
    host.className = 'wd-chart-keys';
    host.setAttribute('aria-label', 'Runs a day');
    host.addEventListener('focus', () => { if (days.length) show(at < 0 ? days.length - 1 : at); });
    host.addEventListener('blur', () => { if (hits[at]) hits[at].classList.remove('on'); readout.textContent = idle; });
    host.addEventListener('keydown', (ev) => {
        if (ev.key !== 'ArrowLeft' && ev.key !== 'ArrowRight') return;
        ev.preventDefault();
        ev.stopPropagation();
        if (!days.length) return;
        show(at < 0 ? days.length - 1 : at + (ev.key === 'ArrowLeft' ? -1 : 1));
    });
    readout.setAttribute('aria-live', 'polite');
}

let ovDraw = 0;
async function loadOverview() {
    const draw = ++ovDraw;
    const r = await call('overview', { days: st.days, scope: st.ovScope, value: st.ovValue });
    if (draw !== ovDraw) return;
    st.ov = r.ok ? r.data : null;
    st.ovWhy = r.ok ? null : r.why;
    if (showing('overview')) renderOverview();
}

/** Who made scenarios in the list, once each: { id (their account), name (as they were then) }, by name. */
function makers() {
    const seen = new Map();
    for (const s of scenarios()) {
        if (s.makerId && !s.pack && !seen.has(s.makerId)) seen.set(s.makerId, s.createdBy || 'account ' + s.makerId);
    }
    return [...seen].map(([id, name]) => ({ id, name })).sort((a, b) => a.name.localeCompare(b.name));
}

/** What the Overview shows, as its title says it (a pick no longer in the list is every scenario again). */
function ovTitle() {
    const v = st.ovValue;
    if (st.ovScope === 'scenario') { const s = scenarios().find((x) => x.key === v); if (s) return s.name || s.key; }
    if (st.ovScope === 'lore') { const c = arr(st.hub && st.hub.lore).find((x) => x.key === v); if (c) return 'With ' + c.name; }
    if (st.ovScope === 'maker') { const m = makers().find((x) => String(x.id) === v); if (m) return 'Made by ' + m.name; }
    return 'Every scenario';
}

/** The Overview's Showing: every scenario, one, the ones a lore character is in, or the ones a player made. */
function showingPick() {
    const sel = WP.el('select', 'wp-select');
    sel.dataset.change = 'wdShowing';
    const add = (parent, value, label) => { const o = WP.el('option', null, label); o.value = value; parent.appendChild(o); };
    const group = (label, list) => {
        if (!list.length) return;
        const g = WP.el('optgroup');
        g.label = label;
        for (const [value, text] of list) add(g, value, text);
        sel.appendChild(g);
    };
    add(sel, 'all|', 'All scenarios');
    group('One scenario', scenarios().map((s) => ['scenario|' + s.key, s.name || s.key]));
    group('With a lore character', arr(st.hub && st.hub.lore).map((c) => ['lore|' + c.key, 'With ' + c.name]));
    group('Made by', makers().map((m) => ['maker|' + m.id, 'Made by ' + m.name]));
    sel.value = st.ovScope + '|' + st.ovValue;
    if (sel.selectedIndex < 0) sel.value = 'all|';
    return WP.field('Showing', sel);
}

function renderOverview() {
    const pane = els.overview;
    if (!pane) return;
    pane.innerHTML = '';
    const head = WP.el('div', 'wp-actions-row wp-head-row');
    head.appendChild(WP.el('div', 'wp-pane-title', ovTitle()));
    head.appendChild(WP.el('span', 'wp-actions-split'));
    if (st.hub) head.appendChild(showingPick());
    head.appendChild(WP.toggles('wdDays', PERIODS, st.days));
    pane.appendChild(head);
    if (st.hub && st.hub.off) pane.appendChild(WP.empty(st.hub.off));
    if (st.ovWhy) { pane.appendChild(WP.empty(st.ovWhy)); return; }
    const o = st.ov;
    if (!o) { pane.appendChild(WP.empty('Adding it up…')); return; }

    // The numbers: what it paid out first and biggest, the rest smaller beside it, each its name and number only.
    const t = o.totals || {};
    const bad = (t.failed || 0) + (t.faulted || 0);
    const finished = (t.succeeded || 0) + bad;
    const shown = st.ovScope === 'all' ? null : new Set(arr(o.scenarios).map((x) => x.key));
    const live = st.hub ? arr(st.hub.runs).filter((x) => !x.test && (!shown || shown.has(x.scenario))).length : 0;
    const stats = WP.el('div', 'wp-stats wd-stats');
    const lead = WP.stat('Payout', money(t.paid || 0));
    lead.classList.add('wd-stat-lead');
    stats.appendChild(lead);
    stats.appendChild(WP.stat('Runs', String(t.runs || 0)));
    stats.appendChild(WP.stat('Succeed', finished ? Math.round(((t.succeeded || 0) / finished) * 100) + '%' : '—'));
    stats.appendChild(WP.stat('Players', String(t.players || 0)));
    stats.appendChild(WP.stat('Going now', String(live)));
    pane.appendChild(stats);

    const days = everyDay(o);
    const busiest = days.reduce((m, d) => (d.runs > m.runs ? d : m), { runs: 0 });
    const idle = busiest.runs ? `Point at a day for its runs. Busiest: ${busiest.label}, ${plural(busiest.runs, 'run')}` : 'No runs in this period';
    const card = WP.el('div', 'wp-chart-card');
    const ch = WP.el('div', 'wp-chart-head');
    ch.appendChild(WP.el('div', 'wp-section-title', 'Runs a day'));
    const lg = WP.el('div', 'wp-chart-legend');
    for (const [cls, text] of [['wd-chart-ok', 'succeeded'], ['wd-chart-bad', 'failed'], ['wd-chart-off', 'called off']]) {
        const s = WP.el('span');
        s.appendChild(WP.el('span', 'wp-chart-key ' + cls));
        s.appendChild(document.createTextNode(text));
        lg.appendChild(s);
    }
    ch.appendChild(lg);
    card.appendChild(ch);
    const host = WP.el('div');
    card.appendChild(host);
    const readout = WP.el('div', 'wp-chart-readout', idle);
    card.appendChild(readout);
    pane.appendChild(card);
    runsChart(host, days, readout, idle);   // in the page now, so it can be measured

    const cols = WP.el('div', 'wp-cols-2');
    cols.style.alignItems = 'start';
    const most = WP.el('div');
    most.appendChild(WP.el('div', 'wp-section-title', 'Most run'));
    const sc = arr(o.scenarios);
    if (sc.length) {
        most.appendChild(tallies(sc, (x) => x.name + (x.deleted ? ' (deleted)' : ''), (x) => x.runs,
            (x) => `${pct(x)} succeed · ${plural(x.players, 'player')} · ${money(x.paid)} paid`,
            'wdOpenScenario', (x) => (x.deleted ? null : x.key)));
    } else most.appendChild(WP.empty('No runs in this period'));
    cols.appendChild(most);
    const who = WP.el('div');
    who.appendChild(WP.el('div', 'wp-section-title', 'Who plays most'));
    const pl = arr(o.players);
    if (pl.length) {
        who.appendChild(tallies(pl, (x) => x.name || ('#' + x.charId), (x) => x.times,
            (x) => `${x.account || 'no account'} · ${x.succeeded} succeeded · last ${ago(x.lastAt)}`));
    } else who.appendChild(WP.empty('Nobody played in this period'));
    cols.appendChild(who);
    pane.appendChild(cols);

    const reasons = arr(o.reasons);
    if (reasons.length) {
        pane.appendChild(WP.el('div', 'wp-section-title', 'Why runs failed'));
        pane.appendChild(tallies(reasons, (x) => x.reason || 'no reason given', (x) => x.n));
    }

    pane.appendChild(WP.el('div', 'wp-section-title', 'Newest runs'));
    const recent = arr(o.recent);
    if (!recent.length) { pane.appendChild(WP.empty('No runs yet')); return; }
    pane.appendChild(table(['Run', 'Scenario', 'Started', 'Took', 'How it went', 'Players', 'Paid'],
        recent.map((x) => [`${x.id}${x.test ? ' (test)' : ''} · revision ${x.rev}`, x.name || x.key, dateTime(x.startedAt), took(x.durationS),
            pill((OUTCOME[x.outcome] || x.outcome) + (x.reason ? `: ${x.reason}` : ''), OUTCOME_PILL[x.outcome]),
            x.players || '—', x.payout ? money(x.payout) : '—']),
        { action: 'wdRecentRun', arg: (i) => `${recent[i].key}|${recent[i].id}` }));
}

// ============================================================
// Scenarios: the list
// ============================================================

function scenarios() { return st.hub ? arr(st.hub.scenarios) : []; }

function statusPill(s) {
    // A script switched it (SwitchScenario, in memory only): said by its name.
    const sw = s.switchedBy && typeof s.switchedBy === 'object' ? s.switchedBy : null;
    if (s.on) return ['On · revision ' + s.onRev + (sw && sw.on ? ' · by ' + sw.by : ''), 'wp-pill-ok'];
    if (sw && !sw.on) return ['Off · by ' + sw.by, ''];
    if (s.status === 'disabled') return ['Off', ''];
    // Meant to be on, but not in the world: a shipped one waits for its pack to start again; any other
    // did not come back on (its check, a missing model: the console says).
    if (s.status === 'active') return [s.pack ? 'Waits for its pack' : 'Not on: see the console', 'wp-pill-warn'];
    return ['Draft', ''];
}

function renderList() {
    if (!els.list) return;
    els.list.innerHTML = '';
    const q = st.search.toLowerCase();
    const list = scenarios().filter((s) => !q || (s.name + ' ' + s.key + ' ' + (s.createdBy || '')).toLowerCase().includes(q));
    for (const s of list) {
        const [p, cls] = statusPill(s);
        const nv = arr(s.variants).length;
        const sub = (s.pack ? 'Shipped · ' : '') + (s.runs ? `${s.runs} run${s.runs === 1 ? '' : 's'} · ${pct(s)}` : 'Never run')
            + (s.live ? ` · ${s.live} going` : '') + (nv > 1 ? ` · ${nv} variants` : '');
        const item = WP.listItem({ title: s.name || s.key, sub, pill: p, pillClass: cls, id: s.key, action: 'wdSelect' });
        if (st.sel === s.key) item.classList.add('active');
        els.list.appendChild(item);
    }
    if (!list.length) els.list.appendChild(WP.empty(q ? `No scenarios match "${st.search}"` : 'No scenarios yet: New scenario makes one'));
    els.count.textContent = `${list.length} of ${scenarios().length}`;
}

// ============================================================
// Scenarios: one, in detail
// ============================================================

function selected() { return scenarios().find((s) => s.key === st.sel) || null; }

function renderDetail() {
    const d = els.detail;
    if (!d) return;
    d.innerHTML = '';
    const s = selected();
    if (!s) {
        d.appendChild(WP.empty(st.hub && st.hub.off ? st.hub.off : 'Pick a scenario on the left'));
        return;
    }
    d.appendChild(WP.el('div', 'wp-pane-title', s.name || s.key));
    // On the left what it is (the Blueprint's description) and whether it is on; on the right, who made it and
    // where its things are (drawSide).
    const head = WP.el('div', 'wd-head');
    const about = WP.el('div', 'wd-head-about');
    about.appendChild(WP.el('div', 'wd-desc' + (s.description ? '' : ' wd-desc-none'),
        s.description || (s.pack ? 'No description.' : 'No description yet: the Blueprint\'s Description field gives it one.')));
    // Its variants (Multi Run Variants), when it has more than one: each run plays one of them.
    const vs = arr(s.variants);
    if (vs.length > 1) about.appendChild(WP.el('div', 'wd-desc', `${vs.length} variants: ${vs.join(', ')}`));
    about.appendChild(activeSwitch(s));
    head.appendChild(about);
    els.side = WP.el('div', 'wd-head-side');
    head.appendChild(els.side);
    d.appendChild(head);
    drawSide(s);

    // Far right, the main one last (Delete is up in its maker's bar: drawSide).
    const row = WP.el('div', 'wp-actions-row');
    row.appendChild(WP.el('span', 'wp-actions-split'));
    if (admin()) row.appendChild(WP.btn('Export as a pack', 'wdExport', null, s.key));
    row.appendChild(WP.btn('Share code', 'wdShare', null, s.key));   // PROJECT Z PATCH (share codes, below)
    row.appendChild(WP.btn('Duplicate', 'wdCopy', null, s.key));
    if (s.on) row.appendChild(WP.btn('Start a run', 'wdRun', null, s.key));
    row.appendChild(WP.btn('Open Editor', 'wdEdit', 'primary', s.key));
    d.appendChild(row);

    d.appendChild(WP.el('div', 'wp-section-title', 'Previous Versions'));
    els.versions = WP.el('div', 'wd-versions');
    d.appendChild(els.versions);
    loadVersions();
}

/** ACTIVE: the scenario on or off, a switch (white on, grey off). On is its newest revision; a note under it says
 *  what the switch alone does not show (a script switched it, its pack is stopped, it did not come back on, newer
 *  edits are not live yet). */
function activeSwitch(s) {
    const meant = s.on || s.status === 'active';   // meant to be on, even while it is not (its pack is stopped)
    const box = WP.el('div', 'wd-active');
    const b = WP.el('button', 'wd-sw');
    b.type = 'button';
    b.setAttribute('role', 'switch');
    b.setAttribute('aria-checked', String(meant));
    b.dataset.action = meant ? 'wdOff' : 'wdOn';
    b.dataset.arg = s.key;
    b.appendChild(WP.el('span', 'wd-sw-name', 'Active'));
    b.appendChild(WP.el('span', 'wd-switch' + (meant ? ' on' : '')));
    box.appendChild(b);
    const sw = s.switchedBy && typeof s.switchedBy === 'object' ? s.switchedBy : null;
    let note = '';
    if (s.on && s.onRev !== s.draftRev) note = `Revision ${s.onRev} is live: switch it off and on to use your newest edits (revision ${s.draftRev}).`;
    else if (!s.on && s.status === 'active') note = s.pack ? 'Waits for its pack to start again.' : 'Meant to be on, but it is not: the server console says why.';
    if (sw) note = (note ? note + ' ' : '') + `Switched ${sw.on ? 'on' : 'off'} by ${sw.by}.`;
    if (s.pack) note = (note ? note + ' ' : '') + `Shipped by ${s.pack}: read-only here.`;
    if (note) box.appendChild(WP.el('div', 'wp-hint', note));
    return box;
}

/** A car's takes as lines for the map (WP.place's linesFor: wp/places.js), each drive read once (takePath) and kept. */
function takeLinesOf(key, p) {
    return takeLines(p, (t) => {
        const id = key + ':' + t.id;
        if (!st.takePaths[id]) {
            st.takePaths[id] = call('takePath', { key, take: t.id }).then((r) => (r.ok ? arr(r.data.points) : null));
        }
        return st.takePaths[id];
    });
}

/** The page's right side: who made it (their face and name, as the Player Manager's list shows a player) and its
 *  things on the map, each by its kind. Read once per revision (places); only this side is drawn again when it comes. */
function drawSide(s) {
    const side = els.side;
    if (!side) return;
    side.innerHTML = '';
    const got = st.places[s.key];
    const ready = got && got.rev === s.draftRev;
    // Its maker's bar, at once (their face comes with the places answer): who, when, and Delete far right.
    const c = (!s.pack && ready && got.data && got.data.creator) || {};   // a shipped one's maker is its resource
    const name = s.pack || c.name || s.createdBy || 'the server';
    const maker = WP.el('div', 'wd-maker');
    const face = avatar(name, c.charId ? !!c.online : undefined, c.charId || null);
    const dot = face.querySelector('.wp-dot');
    if (dot) dot.title = c.online ? 'Online' : 'Offline';
    maker.appendChild(face);
    const words = WP.el('div', 'wd-maker-words');
    words.appendChild(WP.el('span', 'wp-item-title', name));
    words.appendChild(WP.el('span', 'wp-item-sub', dateTime(s.createdAt)));
    maker.appendChild(words);
    if (admin()) {
        maker.appendChild(WP.el('span', 'wp-actions-split'));
        maker.appendChild(WP.btn('Delete', 'wdDelete', 'danger', s.key));
    }
    side.appendChild(maker);
    if (!ready) {
        side.appendChild(WP.empty('Reading where its things are…'));
        loadPlaces(s);
        return;
    }
    if (!got.data) { side.appendChild(WP.empty(got.why || 'Where its things are could not be read')); return; }
    const places = arr(got.data.places);
    if (!places.length) { side.appendChild(WP.empty('Nothing of it is placed in the world yet')); return; }
    const map = WP.place({
        name: s.name || s.key,
        marks: placeMarks(places),
        card: (m) => placeCard(m.place),
        linesFor: (m) => takeLinesOf(s.key, m.place),   // a car picked: its takes' drives, drawn on the map
    });
    map.classList.add('wd-map');
    side.appendChild(map);
}

async function loadPlaces(s) {
    const key = s.key, rev = s.draftRev;
    if (st.placesFor === key + ':' + rev) return;
    st.placesFor = key + ':' + rev;
    const r = await call('places', { key });
    if (st.placesFor === key + ':' + rev) st.placesFor = null;
    st.places[key] = { rev, data: r.ok ? r.data : null, why: r.ok ? null : r.why };
    // Lore characters' headshots for their marks (wp/places.js placePic), before the map is drawn.
    if (r.ok) await primeLorePortraits(arr(r.data.places).map((p) => p && p.lore).filter(Boolean));
    const now = selected();
    if (now && now.key === key && showing('scenarios')) drawSide(now);
}

/** PREVIOUS VERSIONS: its revisions, newest first, each but the newest with Restore. */
async function loadVersions() {
    const key = st.sel;
    const body = els.versions;
    if (!key || !body) return;
    body.innerHTML = '';
    body.appendChild(WP.empty('Loading…'));
    const r = await call('history', { key });
    // Moved on meanwhile: this answer is for another scenario.
    if (st.sel !== key || els.versions !== body) return;
    body.innerHTML = '';
    if (!r.ok) { body.appendChild(WP.empty(r.why)); return; }
    const list = arr(r.data.revisions);
    if (!list.length) { body.appendChild(WP.empty('No revisions')); return; }
    const s = selected();
    body.appendChild(table(['Revision', 'By', 'When', 'Note', ''],
        list.map((x) => {
            const cell = WP.el('span');
            if (s && !s.pack && x.rev !== s.draftRev) cell.appendChild(WP.btn('Restore', 'wdRestore', 'ghost', x.rev));
            const tag = s && x.rev === s.draftRev ? ' (newest)' : '';
            const on = s && s.on && x.rev === s.onRev ? ' (live)' : '';
            return [`${x.rev}${tag}${on}`, x.editedBy || 'the server', dateTime(x.createdAt), x.note || '', cell];
        })));
}

/** One run, from the Overview's newest runs: what its players did in it, in a window. */
async function showRun(key, runId) {
    const r = await call('events', { key, runId, before: 0 });
    if (!r.ok) { WP.result(r.why, 'err'); return; }
    const list = arr(r.data.events);
    const box = WP.el('div', 'wd-run-events');
    if (!list.length) box.appendChild(WP.empty('Nothing on record for this run'));
    else {
        box.appendChild(table(['When', 'Who', 'Card', 'What', 'Detail'],
            list.map((x) => [dateTime(x.at), x.name || (x.charId ? '#' + x.charId : '—'), x.card || '—', x.kind, x.detail || ''])));
    }
    const s = scenarios().find((x) => x.key === key);
    await WP.confirm({ title: `Run ${runId}${s ? ' of ' + (s.name || s.key) : ''}`, confirmLabel: 'Done', content: box,
        wide: true, noCancel: true });
}

/** NEW SCENARIO and DUPLICATE: a name, a key (made from the name unless typed), and for a new one where it starts
 *  (nothing, an example, another resource's template). Answers { key, name, from } once confirmed, or null. */
async function askScenario(copyOf) {
    const s = copyOf ? scenarios().find((x) => x.key === copyOf) : null;
    const used = new Set(scenarios().map((x) => x.key));
    const box = WP.el('div', 'wd-form');
    const name = WP.input({ value: s ? (s.name || s.key) + ' (copy)' : '', placeholder: 'The bank job' });
    const key = WP.input({ placeholder: 'from the name' });
    if (s) {
        let k = slug(s.key + '_copy') || 'copy', i = 2;
        while (used.has(k)) k = slug(s.key + '_copy') + (i++);
        key.value = k;
    }
    box.appendChild(WP.field('Name', name, true));
    box.appendChild(WP.field('Key', key, true));
    let start = null;
    if (!s) {
        const h = st.hub || {};
        start = WP.select([{ value: '', label: 'Nothing' }]
            .concat(arr(h.examples).map((x) => ({ value: 'example:' + x, label: 'Example: ' + String(x).replace(/_/g, ' ') })))
            // Other resources' starting points (Whip.template): the copy is yours.
            .concat(arr(h.templates).map((t) => ({ value: 'template:' + t.id, label: `${t.name} (${t.resource})` }))));
        box.appendChild(WP.field('Start from', start, true));
    }
    const keyOf = () => key.value.trim() || slug(name.value);
    // Why it cannot be made yet, under the fields (none while it can).
    const why = WP.el('div', 'wd-form-why');
    box.appendChild(why);
    const whyNot = () => {
        if (!name.value.trim()) return '';
        if (!KEY_OK.test(keyOf())) return 'A key is 2 to 64 letters, digits, _ and -';
        if (used.has(keyOf())) return `${keyOf()} is taken`;
        return '';
    };
    name.addEventListener('input', () => { key.placeholder = slug(name.value) || 'from the name'; });
    const ok = await WP.confirm({
        title: s ? `Duplicate ${s.name || s.key}` : 'New scenario', confirmLabel: s ? 'Duplicate' : 'Make it', content: box,
        canConfirm: () => {
            why.textContent = whyNot();
            return name.value.trim() !== '' && !why.textContent;
        },
    });
    if (!ok) return null;
    return { key: keyOf(), name: name.value.trim(), from: s ? 'copy:' + s.key : (start ? start.value : '') };
}

// ============================================================
// Shipped, Live runs, Access
// ============================================================

function requiresText(p) {
    if (p.broken) return 'Cannot be read: ' + p.broken;
    const req = p.requires || {};
    const m = req.missing || {};
    const parts = [];
    if (arr(m.resources).length) parts.push('resources: ' + arr(m.resources).join(', '));
    if (arr(m.items).length) parts.push('items: ' + arr(m.items).join(', '));
    if (arr(m.cards).length) parts.push('cards: ' + arr(m.cards).join(', '));
    if (req.format) parts.push('format ' + req.format);
    let text = parts.length ? 'Missing ' + parts.join('; ') : 'Everything it needs is here';
    if (arr(req.models).length) text += ' · models: ' + arr(req.models).join(', ');
    if (!p.passes) text += ` · ${p.problems || 'some'} thing${p.problems === 1 ? '' : 's'} to fix before it can go on (place it from a copy)`;
    return text;
}

const PACK_STATUS = { pending: ['Waiting', 'wp-pill-warn'], accepted: ['Accepted', 'wp-pill-ok'], refused: ['Refused', ''],
    deleted: ['Deleted here', ''], broken: ['Broken', 'wp-pill-err'] };

// Each of the two tables below asks the server, so two draws can overlap (a refresh while the tab
// opens): only the newest one draws, or the table comes out twice.
let shippedDraw = 0, accessDraw = 0;

async function renderShipped() {
    const pane = els.shipped;
    if (!pane) return;
    const draw = ++shippedDraw;
    pane.innerHTML = '';
    pane.appendChild(WP.empty('Loading…'));
    const r = await call('packs');
    if (draw !== shippedDraw || !showing('shipped')) return;
    pane.innerHTML = '';
    if (!r.ok) { pane.appendChild(WP.empty(r.why)); return; }
    const list = arr(r.data.packs);
    if (!list.length) { pane.appendChild(WP.empty('No running resource ships a scenario')); return; }
    // Trust, once per resource that ships one (admins): its scenarios accepted by themselves.
    if (admin()) {
        const trusted = r.data.trusted && typeof r.data.trusted === 'object' ? r.data.trusted : {};
        const row = WP.el('div', 'wp-actions-row');
        for (const res of [...new Set(list.map((p) => p.resource))].sort()) {
            const t = trusted[res];
            const b = WP.btn(t ? `Stop trusting ${res}` : `Trust ${res}`, 'wdTrust', t ? 'ghost' : '');
            b.dataset.res = res;
            b.dataset.on = t ? '0' : '1';
            if (t) b.title = `Trusted by ${t.by || 'someone'}: its scenarios are accepted by themselves`;
            row.appendChild(b);
        }
        pane.appendChild(row);
    }
    pane.appendChild(table(['Resource', 'Scenario', 'Status', 'Needs', ''],
        list.map((p) => {
            const [label, cls] = PACK_STATUS[p.status] || [p.status, ''];
            const cell = WP.el('span', 'wp-actions-row');
            if (admin() && !p.broken && p.status !== 'deleted') {
                if (p.status !== 'accepted' || p.changed) {
                    const b = WP.btn(p.changed ? 'Accept the new version' : 'Accept', 'wdAccept', 'primary');
                    b.dataset.res = p.resource; b.dataset.file = p.file;
                    cell.appendChild(b);
                }
                if (p.status === 'pending') {
                    const b = WP.btn('Refuse', 'wdRefuse', 'ghost');
                    b.dataset.res = p.resource; b.dataset.file = p.file;
                    cell.appendChild(b);
                }
            }
            // One built in its code (Whip.scenario) has no file: said so.
            return [`${p.resource} · ${p.fromCode ? 'from its code' : p.file}${p.trusted ? ' · trusted' : ''}`, `${p.name || '?'} (${p.key || '?'})`,
                pill(label + (p.changed ? ' · changed' : ''), cls), WP.el('span', 'wd-wrap', requiresText(p)), cell];
        })));
}

function renderRuns() {
    const pane = els.runs;
    if (!pane) return;
    pane.innerHTML = '';
    const list = st.hub ? arr(st.hub.runs) : [];
    const nameOf = (key) => { const s = scenarios().find((x) => x.key === key); return (s && s.name) || key; };
    if (!list.length) pane.appendChild(WP.empty('Nothing is going now'));
    else {
        pane.appendChild(table(['Run', 'Scenario', 'Players', 'For', ''],
            list.map((x) => [`${x.id}${x.test ? ' (test)' : ''}`, `${nameOf(x.scenario)} · revision ${x.rev}${x.variant ? ` · ${x.variant}` : ''}`, arr(x.players).join(', ') || 'nobody',
                took(x.seconds), WP.btn('Stop', 'wdAbort', 'danger', x.id)])));
    }
    // Switched on from a file (/director load): live, but not one of the list's.
    const files = st.hub ? arr(st.hub.files) : [];
    if (files.length) {
        pane.appendChild(WP.el('div', 'wp-section-title', 'On from a file'));
        pane.appendChild(table(['Scenario', 'Key', ''],
            files.map((f) => [f.name || f.key, f.key, WP.btn('Switch off', 'wdOff', null, f.key)])));
    }
}

// ============================================================
// Dungeon Mode: a Dungeon Master's page
// ============================================================

const LIVE_KIND = { npc: 'NPC', vehicle: 'Car', prop: 'Prop', hide: 'Map prop hidden' };
let liveDraw = 0;

/** A live thing's row: what it is, its model, where, when, whose (`by`: everyone's table), and Remove (a map prop
 *  hidden for everyone: Put back). */
function liveRow(v, by) {
    const what = v.weapon ? 'Fixed Weapon' : (LIVE_KIND[v.kind] || v.kind);
    const c = v.coords || {};
    const where = typeof c.x === 'number' ? `${Math.round(c.x)}, ${Math.round(c.y)}` : '—';
    const cells = [pill(what, v.kind === 'npc' ? 'wp-pill-accent' : ''), v.label || v.model, v.weapon || v.model, where, ago(v.made)];
    if (by) cells.splice(1, 0, v.by || '—');
    cells.push(v.kind === 'hide' ? WP.btn('Put back', 'wdLiveRemove', null, v.id) : WP.btn('Remove', 'wdLiveRemove', 'danger', v.id));
    return cells;
}

async function renderLive() {
    const pane = els.live;
    if (!pane) return;
    const draw = ++liveDraw;
    pane.innerHTML = '';
    const head = WP.el('div', 'wp-actions-row wp-head-row');
    head.appendChild(WP.el('div', 'wp-pane-title', 'Dungeon Mode'));
    head.appendChild(WP.el('span', 'wp-actions-split'));
    head.appendChild(WP.btn('Refresh', 'wdLiveRefresh', 'ghost'));
    head.appendChild(WP.btn('Start Dungeon Mode', 'wdLive', 'primary'));
    pane.appendChild(head);
    pane.appendChild(WP.el('p', 'wd-live-lead',
        'The world builder on the live world. What you put down is made for everyone at once, and a click on anything '
        + '(a prop, a car, an NPC, a player) opens its options. It all lasts until the server restarts, or until you remove it. '
        + 'Options that would last past a restart are an admin\'s only.'));

    const r = await call('liveList');
    if (draw !== liveDraw || !showing('live')) return;
    if (!r.ok) { pane.appendChild(WP.empty(r.why)); return; }
    const mine = arr(r.data.mine), others = arr(r.data.others);
    const stats = WP.el('div', 'wp-stats');
    stats.appendChild(WP.stat('Yours up', `${mine.length}${r.data.max ? ' of ' + r.data.max : ''}`));
    if (r.data.admin) stats.appendChild(WP.stat('Everyone else\'s', String(others.length)));
    pane.appendChild(stats);

    const yours = WP.el('div', 'wp-actions-row');
    yours.appendChild(WP.el('div', 'wp-section-title', 'What you made'));
    yours.appendChild(WP.el('span', 'wp-actions-split'));
    if (mine.length || arr(r.data.effects).some((e) => e.mine)) {
        yours.appendChild(WP.btn('Clear everything I made', 'wdLiveClear', 'danger', 'mine'));
    }
    pane.appendChild(yours);
    pane.appendChild(mine.length
        ? table(['What', 'Name', 'Model', 'Where', 'Made', ''], mine.map((v) => liveRow(v, false)))
        : WP.empty('Nothing yet: Start Dungeon Mode, pick something and put it down'));

    // Effects on (smoke, flames ...): theirs, and an admin's everyone's. Clear takes them with the things.
    const fx = arr(r.data.effects);
    if (fx.length) {
        const fxHead = WP.el('div', 'wp-actions-row');
        fxHead.appendChild(WP.el('div', 'wp-section-title', `Effects on (${fx.filter((e) => e.mine).length}`
            + `${r.data.maxEffects ? ' of ' + r.data.maxEffects : ''} yours)`));
        pane.appendChild(fxHead);
        const cols = r.data.admin ? ['Effect', 'On', 'By', 'Where', ''] : ['Effect', 'On', 'Where', ''];
        pane.appendChild(table(cols, fx.map((e) => {
            const at = e.at ? `${Math.round(e.at.x)}, ${Math.round(e.at.y)}` : '—';
            const row = [e.kind, e.what || '—'];
            if (r.data.admin) row.push(e.mine ? 'You' : (e.by || '—'));
            row.push(at, WP.btn('Turn off', 'wdLiveFxOff', 'ghost', e.key));
            return row;
        })));
    }

    if (!r.data.admin) return;
    const all = WP.el('div', 'wp-actions-row');
    all.appendChild(WP.el('div', 'wp-section-title', 'Everyone else\'s'));
    all.appendChild(WP.el('span', 'wp-actions-split'));
    if (others.length) all.appendChild(WP.btn('Clear everyone\'s', 'wdLiveClear', 'danger', 'all'));
    pane.appendChild(all);
    pane.appendChild(others.length
        ? table(['What', 'By', 'Name', 'Model', 'Where', 'Made', ''], others.map((v) => liveRow(v, true)))
        : WP.empty('Nobody else has anything up'));
}

async function renderAccess() {
    const pane = els.access;
    if (!pane) return;
    const draw = ++accessDraw;
    pane.innerHTML = '';
    if (st.hub && !admin()) { pane.appendChild(WP.empty('Only a Director admin manages access')); return; }

    // Giving it: a character (per account: every character on it has it), and which. The choices say what each
    // may do; full admins (whip.devtools) are all of them already.
    const form = WP.el('div', 'wp-actions-row wp-head-row wd-grant');
    els.grantChar = WP.attachCharPicker(WP.input({ placeholder: 'Character name or id' }));
    els.grantLevel = WP.select([{ value: 'build', label: 'Builder: make, test, switch on and off' },
                                { value: 'admin', label: 'Director admin: also delete, packs, access' },
                                { value: 'live', label: 'Dungeon Mode: change the live world, nothing lasts' }]);
    form.appendChild(WP.field('Character', els.grantChar));
    form.appendChild(WP.field('Give', els.grantLevel));
    form.appendChild(WP.btn('Give access', 'wdGrant', 'primary'));
    pane.appendChild(form);

    const r = await call('access');
    if (draw !== accessDraw || !showing('access')) return;
    if (!r.ok) { pane.appendChild(WP.empty(r.why)); return; }
    // One table, admins first, then builders, then Dungeon Masters, so the columns line up.
    const people = arr(r.data.admins).map((h) => [h, 'admin']).concat(arr(r.data.builders).map((h) => [h, 'build']),
        arr(r.data.live).map((h) => [h, 'live']));
    if (!people.length) { pane.appendChild(WP.empty('Nobody has Director access yet')); return; }
    const LEVEL_NAME = { admin: 'Director admin', build: 'Builder', live: 'Dungeon Mode' };
    pane.appendChild(table(['Who', 'Access', 'Account', 'Given by', 'When', ''],
        people.map(([h, level]) => {
            const b = WP.btn('Take away', 'wdRevoke', 'danger', h.userId);
            b.dataset.level = level;
            return [person(h.name || ('account ' + h.userId), h.charId, h.online),
                pill(LEVEL_NAME[level], level === 'admin' ? 'wp-pill-accent' : level === 'live' ? 'wp-pill-warn' : ''),
                h.account || '—', h.grantedBy || '—', dateTime(h.grantedAt), b];
        })));
}

/** A person as the Player Manager's list and a scenario's maker show one: their face (with the online dot), their name. */
function person(name, charId, online) {
    const el = WP.el('span', 'wd-person');
    const face = avatar(name, charId ? !!online : undefined, charId || null);
    const dot = face.querySelector('.wp-dot');
    if (dot) dot.title = online ? 'Online' : 'Offline';
    el.appendChild(face);
    el.appendChild(WP.el('span', 'wd-person-name', name));
    el.title = name + (online ? ' · online' : '');
    return el;
}

/** A list page's toolbar: what it makes, Refresh, and its search (the shell docks it in the list column). */
function listBar(newLabel, newAction, placeholder, searchAction) {
    return WP.toolbar({
        left: [WP.btn(newLabel, newAction, 'primary'), WP.btn('Refresh', 'wdRefresh', 'ghost')],
        search: { inputAction: searchAction, placeholder },
    });
}

/** Show a scenario on the Scenarios page. */
function openScenario(key) {
    if (!scenarios().some((s) => s.key === key)) { WP.result('That scenario is not in the list any more', 'err'); return; }
    st.sel = key;
    if (showing('scenarios')) { renderList(); renderDetail(); }
    else WhipPanel.switchTo(SEC.scenarios);
}

// ============================================================
// Loading and the actions
// ============================================================

async function refresh(say) {
    const r = await call('list');
    if (!r.ok) { WP.result(r.why, 'err'); return; }
    st.hub = r.data;
    if (st.sel && !selected()) st.sel = null;
    // Shipped's count of waiting files (the group word in the header adds it up).
    WhipPanel.setBadge(SEC.shipped, showing('shipped') ? null : (st.hub.pendingPacks || null));
    // The page showing, drawn again with it.
    if (showing('scenarios')) { renderList(); renderDetail(); }
    if (showing('overview')) loadOverview();
    if (showing('runs')) renderRuns();
    if (showing('shipped')) renderShipped();
    if (showing('access')) renderAccess();
    if (say) WP.result('Up to date', 'ok');
}

/** A request, and the panel's word on it. A switch that would end players' runs changes nothing and answers
 *  { going = n } (server/director/hub.lua): `ending(n)` asks, and on yes the request goes again with endRuns. */
async function act(op, args, okText, ending) {
    let r = await call(op, args);
    if (r.ok && r.data && r.data.going && ending) {
        if (!(await ending(r.data.going))) return null;
        r = await call(op, Object.assign({}, args, { endRuns: true }));
    }
    if (!r.ok) { WP.result(r.why, 'err'); return null; }
    if (r.data && r.data.ok === false) {
        // Its first error, said here (with its variant when it has more than one); the rest are Check's, in its editor.
        const errs = arr(r.data.problems).filter((p) => p && p.severity === 'error');
        const first = errs[0];
        WP.result(first
            ? `It did not pass its check: ${first.variantName ? first.variantName + ': ' : ''}${first.message}`
                + (errs.length > 1 ? ` (and ${errs.length - 1} more: Check in its editor lists them)` : '')
            : 'It did not pass its check: Check in its editor says why', 'err');
        return null;
    }
    // Done, with a "but": its words instead of the plain ones (an accepted pack whose scenario did not come back on).
    if (r.data && r.data.warning) WP.result(r.data.warning, 'warn');
    else if (okText) WP.result(okText, 'ok');
    await refresh();
    return r.data;
}

// ============================================================
// PROJECT Z PATCH: share codes
// ============================================================
// A share code is a whole scenario document: "WDS1." then the document's JSON, deflated and in URL-safe
// base64 (or "WDS0." and the JSON not deflated, on a page without CompressionStream). Nothing is hosted,
// so a code works on any WHIP server; whitespace in a pasted code is ignored. The server side is
// server/director/hub.lua (shareDoc, importCode); an import is always a NEW draft, switched off.

const CODE_RE = /^WDS([01])\.([A-Za-z0-9_-]+)$/;

// The short-code hub (Project Z/scenario-hub, a Cloudflare Worker): it stores a long code and hands back one like
// ZX-4F9K2QH. Empty: no hub, so Share shows only the long code and Import takes only long ones. No trailing slash.
const HUB_URL = 'https://zext-scenario-hub.whipshare.workers.dev';
const SHORT_RE = /^ZX-?[0-9A-HJKMNP-TV-Z]{7}$/i;

async function hub(path, init) {
    let r;
    try { r = await fetch(HUB_URL + path, init); } catch (e) { throw new Error('The scenario hub cannot be reached'); }
    let body = null;
    try { body = await r.json(); } catch (e) { body = null; }
    if (!r.ok) throw new Error((body && body.error) || `The scenario hub said no (${r.status})`);
    return body || {};
}

/** A short code into its long one, or throws with the words to show. */
async function longCodeOf(short) {
    const d = await hub('/v1/codes/' + encodeURIComponent(short.toUpperCase()));
    if (typeof d.code !== 'string') throw new Error('The scenario hub sent back nothing usable');
    return d.code;
}

function b64url(bytes) {
    let s = '';
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function unb64url(text) {
    const s = atob(text.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((text.length + 3) % 4));
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
}
async function streamBytes(bytes, stream) {
    const res = new Response(new Blob([bytes]).stream().pipeThrough(stream));
    return new Uint8Array(await res.arrayBuffer());
}

async function packCode(doc) {
    const raw = new TextEncoder().encode(JSON.stringify(doc));
    if (typeof CompressionStream === 'function') return 'WDS1.' + b64url(await streamBytes(raw, new CompressionStream('deflate')));
    return 'WDS0.' + b64url(raw);
}

/** A code back into a document, or throws with the words to show. */
async function unpackCode(text) {
    const m = CODE_RE.exec(String(text || '').replace(/\s+/g, ''));
    if (!m) throw new Error('That is not a scenario code (one starts with WDS1.)');
    let bytes;
    try { bytes = unb64url(m[2]); } catch (e) { throw new Error('That code is broken: part of it is missing'); }
    if (m[1] === '1') {
        if (typeof DecompressionStream !== 'function') throw new Error('This game cannot unpack that code');
        try { bytes = await streamBytes(bytes, new DecompressionStream('deflate')); }
        catch (e) { throw new Error('That code is broken: part of it is missing'); }
    }
    let doc;
    try { doc = JSON.parse(new TextDecoder().decode(bytes)); } catch (e) { throw new Error('That code is broken: it does not read as a scenario'); }
    if (!doc || typeof doc !== 'object' || !Array.isArray(doc.nodes)) throw new Error('That code does not hold a scenario');
    return doc;
}

function copyText(area) {
    area.focus();
    area.select();
    let done = false;
    try { done = document.execCommand('copy'); } catch (e) { done = false; }
    if (!done && navigator.clipboard) navigator.clipboard.writeText(area.value).then(() => {}, () => {});
    return done || !!navigator.clipboard;
}

function codeArea(value, placeholder) {
    const a = WP.el('textarea', 'wp-input');
    a.rows = 6;
    a.spellcheck = false;
    a.style.cssText = 'width:100%;min-height:120px;resize:vertical;font-family:monospace;font-size:11px;word-break:break-all;';
    if (placeholder) a.placeholder = placeholder;
    if (value !== undefined) { a.value = value; a.readOnly = true; }
    return a;
}

async function shareScenario(key) {
    const r = await call('shareDoc', { key, rev: 0 });
    if (!r.ok) { WP.result(r.why, 'err'); return; }
    let code;
    try { code = await packCode(r.data.doc); } catch (e) { WP.result('That scenario could not be packed into a code', 'err'); return; }
    const box = WP.el('div', 'wd-form');
    const area = codeArea(code);
    box.appendChild(WP.field(`Code (${code.length.toLocaleString()} characters)`, area, true));
    const copy = WP.btn('Copy code', null, 'primary');
    copy.type = 'button';
    copy.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        WP.result(copyText(area) ? 'Code copied' : 'Select the code and press Ctrl+C', 'ok');
    });
    box.appendChild(copy);
    if (HUB_URL) {
        // A short code: the long one goes up to the hub, where anyone with the short code can fetch it. Only on a press.
        const shortBox = WP.el('div', 'wd-desc');
        shortBox.textContent = 'Or get a short code: it puts this scenario on the public scenario hub.';
        const get = WP.btn('Get short code', null, 'ghost');
        get.type = 'button';
        get.addEventListener('click', async (e) => {
            e.preventDefault();
            e.stopPropagation();
            get.disabled = true;
            shortBox.textContent = 'Uploading…';
            try {
                const d = await hub('/v1/codes', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: code });
                shortBox.textContent = '';
                const shortIn = WP.input({ value: d.id });
                shortIn.readOnly = true;
                shortIn.style.cssText = 'font-family:monospace;font-size:20px;letter-spacing:2px;text-align:center;';
                shortBox.appendChild(WP.field('Short code', shortIn, true));
                const copyShort = WP.btn('Copy short code', null, 'primary');
                copyShort.type = 'button';
                copyShort.addEventListener('click', (ev) => {
                    ev.preventDefault();
                    ev.stopPropagation();
                    WP.result(copyText(shortIn) ? 'Short code copied' : 'Select the code and press Ctrl+C', 'ok');
                });
                shortBox.appendChild(copyShort);
                get.remove();
            } catch (err) {
                shortBox.textContent = err.message;
                get.disabled = false;
            }
        });
        box.appendChild(shortBox);
        box.appendChild(get);
    }
    const shown = WP.confirm({ title: `Share ${r.data.name}`, confirmLabel: 'Done', noCancel: true, wide: true, content: box,
        body: `Revision ${r.data.rev}, with where its things are placed. Anyone with Director access on a WHIP server `
            + 'pastes it into Scenarios > Import code. Recorded drives and lore characters stay on this server.' });
    setTimeout(() => { area.focus(); area.select(); }, 50);
    await shown;
}

async function importScenario() {
    const used = new Set(scenarios().map((s) => s.key));
    const box = WP.el('div', 'wd-form');
    const area = codeArea(undefined, HUB_URL ? 'Paste a code here (ZX-… or WDS1.…)' : 'Paste a code here (WDS1.…)');
    box.appendChild(WP.field('Code', area, true));
    const about = WP.el('div', 'wd-desc');
    box.appendChild(about);
    const name = WP.input({ placeholder: 'from the code' });
    const key = WP.input({ placeholder: 'from the name' });
    box.appendChild(WP.field('Name', name, true));
    box.appendChild(WP.field('Key', key, true));
    const why = WP.el('div', 'wd-form-why');
    box.appendChild(why);
    let doc = null, reading = 0;
    const keyOf = () => key.value.trim() || slug(name.value);
    area.addEventListener('input', async () => {
        const mine = ++reading;
        doc = null;
        about.textContent = '';
        why.dataset.code = '';
        if (!area.value.trim()) { why.textContent = ''; return; }
        let d = null, err = '';
        try {
            let long = area.value.replace(/\s+/g, '');
            if (SHORT_RE.test(long)) {
                if (!HUB_URL) throw new Error('This server has no scenario hub set up for short codes');
                about.textContent = 'Looking it up…';
                long = await longCodeOf(long);
            }
            d = await unpackCode(long);
        } catch (e) { err = e.message; }
        if (mine !== reading) return;   // (a newer paste is being read)
        doc = d;
        if (!d) about.textContent = '';
        if (d) {
            const world = Array.isArray(d.world) ? d.world.length : 0;
            const vars = Array.isArray(d.variants) && d.variants.length > 1 ? ` · ${d.variants.length} variants` : '';
            about.textContent = `${d.name || 'A scenario'}: ${plural(d.nodes.length, 'card')}, ${plural(world, 'placed thing')}${vars}`
                + (d.description ? ` — ${d.description}` : '');
            if (!name.value.trim()) name.value = String(d.name || '').slice(0, 80);
            if (!key.value.trim()) {
                let k = slug(d.key || d.name || 'imported') || 'imported', i = 2;
                const base = k;
                while (used.has(k)) k = base + '_' + (i++);
                key.value = k;
            }
        }
        why.dataset.code = err;
        // (The dialog asks canConfirm again on a change: the reading finished after its own input check.)
        area.dispatchEvent(new Event('change', { bubbles: true }));
    });
    const whyNot = () => {
        if (why.dataset.code) return why.dataset.code;
        if (!doc) return '';
        if (!name.value.trim()) return 'It needs a name';
        if (!KEY_OK.test(keyOf())) return 'A key is 2 to 64 letters, digits, _ and -';
        if (used.has(keyOf())) return `${keyOf()} is taken`;
        return '';
    };
    const ok = await WP.confirm({
        title: 'Import a scenario', confirmLabel: 'Import', wide: true, content: box,
        body: 'It arrives as a new scenario, switched off. Look through its cards (Pay, Give Item, Charge) and run a Test before you switch it on.',
        canConfirm: () => { why.textContent = whyNot(); return !!doc && !why.textContent; },
    });
    if (!ok || !doc) return;
    const r = await nuiCallback('wpDirectorImport', { doc, key: keyOf(), name: name.value.trim() });
    if (!r || !r.ok) { WP.result((r && r.why) || 'No answer from the server', 'err'); return; }
    await refresh();
    openScenario(keyOf());
    const m = (r.data && r.data.missing) || {};
    const lacks = [];
    if (arr(m.items).length) lacks.push('items: ' + arr(m.items).join(', '));
    if (arr(m.cards).length) lacks.push('cards: ' + arr(m.cards).join(', '));
    if (lacks.length) WP.result(`Imported, but this server has no ${lacks.join('; ')}. Fix those in its editor before switching it on.`, 'warn');
    else WP.result(`${name.value.trim()} imported, switched off`, 'ok');
}
// ============================================================ (end PROJECT Z PATCH)

/** Make one (New scenario, Duplicate), and show it. A new one opens in the world at once. */
async function makeScenario(copyOf) {
    const a = await askScenario(copyOf);
    if (!a) return;
    const r = await call('create', a);
    if (!r.ok) { WP.result(r.why, 'err'); return; }
    await refresh();
    openScenario(a.key);
    if (copyOf) WP.result(`${a.name} made`, 'ok');
    else nuiCallback('wpDirectorEdit', { key: a.key });
}

const actions = {
    wdRefresh: () => refresh(true),
    wdNew: () => makeScenario(null),
    wdCopy: (el) => makeScenario(el.dataset.arg),
    wdShare: (el) => shareScenario(el.dataset.arg),   // PROJECT Z PATCH
    wdImport: () => importScenario(),                 // PROJECT Z PATCH
    wdSearch: (el) => { st.search = el.value || ''; renderList(); },
    wdSelect: (el) => { st.sel = el.dataset.id; renderList(); renderDetail(); },
    wdEdit: (el) => nuiCallback('wpDirectorEdit', { key: el.dataset.arg }),
    wdRun: async (el) => {
        const r = await call('startRun', { key: el.dataset.arg });
        if (!r.ok) { WP.result(r.why, 'err'); return; }
        WP.result(`Run ${r.data.runId} started for you: close the panel to play it`, 'ok');
        refresh();
    },
    wdOn: (el) => {
        const s = scenarios().find((x) => x.key === el.dataset.arg);
        const name = s ? s.name || s.key : el.dataset.arg;
        const rev = s ? s.draftRev : 0;
        // On is its newest revision (Previous Versions' Restore makes an older one the newest).
        return act('activate', { key: el.dataset.arg, rev }, 'Switched on', (n) => WP.confirm({
            title: `Make revision ${rev} live?`, danger: true, confirmLabel: `Make revision ${rev} live`,
            body: `${name} has ${plural(n, 'run')} going now. ${n === 1 ? 'It ends for its players' : 'They end for their players'}, `
                + `and new runs use revision ${rev}${s && s.onRev ? ` instead of revision ${s.onRev}` : ''}.` }));
    },
    wdOff: (el) => {
        const s = scenarios().find((x) => x.key === el.dataset.arg)
            || arr(st.hub && st.hub.files).find((x) => x.key === el.dataset.arg);
        const name = s ? s.name || s.key : el.dataset.arg;
        return act('deactivate', { key: el.dataset.arg }, 'Switched off', (n) => WP.confirm({
            title: `Switch off ${name}?`, danger: true, confirmLabel: 'Switch off',
            body: `${name} has ${plural(n, 'run')} going now. ${n === 1 ? 'It ends for its players' : 'They end for their players'}.` }));
    },
    wdDelete: async (el) => {
        const key = el.dataset.arg;
        const s = scenarios().find((x) => x.key === key);
        const name = s ? s.name || key : key;
        const going = s && s.live ? ` ${plural(s.live, 'run')} going now ${s.live === 1 ? 'ends' : 'end'} for ${s.live === 1 ? 'its' : 'their'} players.` : '';
        const ok = await WP.confirm({ title: 'Delete this scenario?', danger: true, confirmLabel: 'Delete',
            body: `${name} goes from the list, and switches off if it is on.${going} Its run history is kept. A shipped one is not offered again.` });
        if (ok && await act('delete', { key }, 'Deleted')) { st.sel = null; renderDetail(); }
    },
    wdExport: async (el) => {
        const r = await call('export', { key: el.dataset.arg, rev: 0 });
        if (!r.ok) { WP.result(r.why, 'err'); return; }
        const d = r.data;
        await WP.confirm({ title: 'Exported', confirmLabel: 'Done',
            body: `Revision ${d.rev} is written to ${d.path}`
                + (d.manifestPath ? `, with its manifest beside it (${d.manifestPath}).` : '.')
                + `\n\nTo share it as a resource: make a folder for it, put the scenario file in it as ${d.file}`
                + `, and the manifest as fxmanifest.lua. Any server running whip that ensures it offers the scenario to its Director admins.` });
    },
    wdRestore: async (el) => {
        const rev = Number(el.dataset.arg);
        const ok = await WP.confirm({ title: `Restore revision ${rev}?`, confirmLabel: 'Restore',
            body: 'It becomes the newest again, as a new revision (nothing is lost: the one it replaces stays in Previous Versions). '
                + 'What is live does not change until you switch it off and on.' });
        if (ok) await act('restore', { key: st.sel, rev }, `Revision ${rev} is the newest again`);   // (refresh draws it)
    },
    // ---- the Overview ----
    wdDays: (el) => {
        st.days = Number(el.dataset.arg) || 14;
        st.ov = null;
        renderOverview();
        loadOverview();
    },
    wdShowing: (el) => {
        const v = String(el.value || 'all|');
        const at = v.indexOf('|');
        st.ovScope = at > 0 ? v.slice(0, at) : 'all';
        st.ovValue = at > 0 ? v.slice(at + 1) : '';
        st.ov = null;
        renderOverview();
        loadOverview();
    },
    wdOpenScenario: (el) => openScenario(el.dataset.arg),
    wdRecentRun: (el) => {
        const [key, id] = String(el.dataset.arg).split('|');
        showRun(key, Number(id) || 0);
    },
    // ---- Shipped, Live runs, Access ----
    wdAccept: (el) => act('accept', { resource: el.dataset.res, file: el.dataset.file }, 'Accepted: it is in the list now'),
    wdRefuse: (el) => act('refuse', { resource: el.dataset.res, file: el.dataset.file }, 'Refused'),
    // Trust a resource once (the Director API): its new and changed scenarios are accepted by
    // themselves when they pass Check. Asked first, as it is the gate it opens.
    wdTrust: async (el) => {
        const res = el.dataset.res, on = el.dataset.on === '1';
        if (on) {
            const ok = await WP.confirm({ title: `Trust ${res}?`, confirmLabel: 'Trust it',
                body: `Every scenario ${res} brings, now and when it updates, is accepted by itself when it passes Check and this `
                    + 'server has what it needs. They stay read-only here, and switching one on is still a builder\'s.' });
            if (!ok) return;
        }
        await act('trust', { resource: res, on }, on ? `${res} is trusted` : `${res} is no longer trusted`);
    },
    wdAbort: async (el) => {
        const ok = await WP.confirm({ title: 'Stop this run?', danger: true, confirmLabel: 'Stop it',
            body: 'Everything it made goes, and its players are told it was called off.' });
        if (ok) act('abort', { runId: Number(el.dataset.arg) }, 'Stopped');
    },
    wdGrant: async () => {
        const charId = parseInt(els.grantChar.value, 10);
        if (!charId) { WP.fieldError(els.grantChar, 'Pick a character'); return; }
        const r = await call('grant', { charId, level: els.grantLevel.value });
        if (!r.ok) { WP.result(r.why, 'err'); return; }
        WP.result(`Given to ${r.data.name || 'them'}`, 'ok');
        els.grantChar.value = '';
        renderAccess();
    },
    wdRevoke: async (el) => {
        const ok = await WP.confirm({ title: 'Take this access away?', danger: true, confirmLabel: 'Take it away',
            body: 'Every character on that account loses it at once.' });
        if (!ok) return;
        const r = await call('revoke', { userId: Number(el.dataset.arg), level: el.dataset.level });
        if (!r.ok) { WP.result(r.why, 'err'); return; }
        WP.result('Taken away', 'ok');
        renderAccess();
    },
    // ---- Live ----
    wdLive: async () => {
        const r = await nuiCallback('wpDirectorLive', {});
        if (!r || r.ok === false) WP.result((r && r.why) || 'Dungeon Mode could not open', 'err');
    },
    wdLiveRefresh: () => renderLive(),
    wdLiveRemove: async (el) => {
        const r = await call('liveRemove', { id: Number(el.dataset.arg) });
        if (!r.ok) { WP.result(r.why, 'err'); return; }
        WP.result('Removed', 'ok');
        renderLive();
    },
    wdLiveClear: async (el) => {
        const all = el.dataset.arg === 'all';
        const ok = await WP.confirm({ title: all ? 'Clear everyone\'s?' : 'Clear everything you made?', danger: true,
            confirmLabel: 'Clear it',
            body: all ? 'Every NPC, car, prop and effect anyone made in Dungeon Mode goes from the world, for everyone.'
                : 'Every NPC, car, prop and effect you made goes from the world, for everyone.' });
        if (!ok) return;
        const r = await call('liveClear', { all });
        if (!r.ok) { WP.result(r.why, 'err'); return; }
        WP.result(`${plural(r.data.removed || 0, 'thing')} removed`
            + (r.data.effects ? `, ${plural(r.data.effects, 'effect')} off` : ''), 'ok');
        renderLive();
    },
    wdLiveFxOff: async (el) => {
        const r = await call('liveFxOff', { key: el.dataset.arg });
        if (!r.ok) { WP.result(r.why, 'err'); return; }
        WP.result('Turned off', 'ok');
        renderLive();
    },
};

/** A list page: its toolbar right above a list on the left and its detail on the right (the shell docks the toolbar
 *  in the list column, as every list page's). */
function split(root, bar) {
    root.appendChild(bar);
    const s = WP.el('div', 'wp-split');
    const col = WP.el('div', 'wp-list-col');
    const count = WP.el('div', 'wp-list-count', '');
    const list = WP.el('div', 'wp-list');
    col.appendChild(count);
    col.appendChild(list);
    s.appendChild(col);
    const detail = WP.el('div', 'wp-detail');
    s.appendChild(detail);
    root.appendChild(s);
    return { count, list, detail };
}

/** A page of one pane (the Overview, Shipped, Live runs, Access). */
function pane(root) {
    const p = WP.el('div', 'wp-detail');
    root.appendChild(p);
    return p;
}

const escape = () => WP.dismissDialog();

// The group's pages, in the order of its tabs. Every page shares the one action map (a page's buttons reach the
// others': the Overview opens a scenario on the Scenarios page). Lore characters is wp/lore.js's, at 30.
const PAGES = [
    { id: SEC.overview, label: 'Overview', order: 10,
      render(root) { els.overview = pane(root); renderOverview(); },
      onEnter() { renderOverview(); refresh(false); } },   // (the list, then the Overview's numbers: refresh)
    // (Its own list only: a Dungeon Master may hold nothing else, and the scenarios' list is a builder's.)
    { id: SEC.live, label: 'Dungeon Mode', order: 15,
      render(root) { els.live = pane(root); },
      onEnter() { renderLive(); } },
    { id: SEC.scenarios, label: 'Scenarios', order: 20,
      render(root) {
          const bar = listBar('New scenario', 'wdNew', 'Search scenarios…', 'wdSearch');
          bar.insertBefore(WP.btn('Import code', 'wdImport', 'ghost'), bar.children[1] || null);   // PROJECT Z PATCH
          const sc = split(root, bar);
          els.count = sc.count;
          els.list = sc.list;
          els.detail = sc.detail;
          renderList();
          renderDetail();
      },
      onEnter() { renderList(); renderDetail(); refresh(false); } },
    { id: SEC.shipped, label: 'Shipped', order: 40,
      render(root) { els.shipped = pane(root); },
      onEnter() { refresh(false); } },   // (each of these three is drawn once the list is in: refresh)
    { id: SEC.runs, label: 'Live runs', order: 50,
      render(root) { els.runs = pane(root); },
      onEnter() { renderRuns(); refresh(false); } },
    { id: SEC.access, label: 'Access', order: 60,
      render(root) { els.access = pane(root); },
      onEnter() { refresh(false); } },
];

// The Lore page's Interactions open a scenario here.
loreLinks.openScenario = (key) => {
    if (st.hub) { openScenario(key); return; }
    refresh(false).then(() => openScenario(key));
};

PAGES.forEach((p) => {
    WhipPanel.registerSection({
        id: p.id,
        group: 'director',
        label: p.label,
        order: p.order,
        render: p.render,
        onEnter: p.onEnter,
        onEscape: p.onEscape || escape,
        actions,
    });
});

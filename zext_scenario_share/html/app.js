// Scenario Share's page. A share code is a whole scenario document: "WDS1." then its JSON, deflated and in
// URL-safe base64 (or "WDS0." and the JSON not deflated, where CompressionStream is missing). Nothing is hosted,
// so a code works on any WHIP server. A short code (ZX-XXXXXXX) is the long one kept on the hub (the server's
// zext_share_hub convar; "" = no hub, so no short codes).

const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'zext_scenario_share';
const CODE_RE = /^WDS([01])\.([A-Za-z0-9_-]+)$/;
const SHORT_RE = /^ZX-?[0-9A-HJKMNP-TV-Z]{7}$/i;

const $ = (id) => document.getElementById(id);
const state = { scenarios: [], imports: [], hub: '', code: '', doc: null, reading: 0 };

// ---- talking to the game ----

async function post(name, body) {
  try {
    const r = await fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
    return await r.json();
  } catch (e) {
    return { ok: false, why: 'No answer from the game' };
  }
}

function status(text, kind) {
  const s = $('status');
  s.textContent = text || '';
  s.className = kind || '';
}

// ---- codes ----

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
/** A long code back into a document, or throws with the words to show. */
async function unpackCode(text) {
  const m = CODE_RE.exec(String(text || '').replace(/\s+/g, ''));
  if (!m) throw new Error('That is not a scenario code (one starts with ZX- or WDS1.)');
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

async function hub(path, init) {
  let r;
  try { r = await fetch(state.hub + path, init); } catch (e) { throw new Error('The scenario hub cannot be reached'); }
  let body = null;
  try { body = await r.json(); } catch (e) { body = null; }
  if (!r.ok) throw new Error((body && body.error) || `The scenario hub said no (${r.status})`);
  return body || {};
}

function copyText(el) {
  el.focus();
  el.select();
  let done = false;
  try { done = document.execCommand('copy'); } catch (e) { done = false; }
  if (!done && navigator.clipboard) navigator.clipboard.writeText(el.value).then(() => {}, () => {});
  return done || !!navigator.clipboard;
}

const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;

// ---- drawing ----

function row(main, sub, right) {
  const li = document.createElement('li');
  const grow = document.createElement('div');
  grow.className = 'grow';
  const name = document.createElement('div');
  name.className = 'name';
  name.textContent = main;
  grow.appendChild(name);
  if (sub) {
    const s = document.createElement('div');
    s.className = 'sub';
    s.textContent = sub;
    grow.appendChild(s);
  }
  li.appendChild(grow);
  for (const el of right) li.appendChild(el);
  return li;
}
function button(label, kind, onClick) {
  const b = document.createElement('button');
  b.className = 'btn' + (kind ? ' ' + kind : '');
  b.textContent = label;
  b.addEventListener('click', onClick);
  return b;
}
function empty(text) {
  const li = document.createElement('li');
  li.className = 'empty';
  li.textContent = text;
  return li;
}

function drawScenarios() {
  const list = $('scenarios');
  const f = $('filter').value.trim().toLowerCase();
  list.textContent = '';
  const shown = state.scenarios.filter((s) => !f || `${s.name} ${s.key}`.toLowerCase().includes(f));
  if (!shown.length) list.appendChild(empty(state.scenarios.length ? 'Nothing matches' : 'This server has no scenarios yet'));
  for (const s of shown) {
    const badge = document.createElement('span');
    badge.className = 'badge' + (s.on ? ' on' : '');
    badge.textContent = s.on ? 'on' : 'off';
    const shareBtn = button('Share', '', () => share(s));
    if (!s.stored) { shareBtn.disabled = true; shareBtn.title = 'Loaded with /director load: save it first'; }
    list.appendChild(row(s.name, s.key + (s.source && s.source.startsWith('pack:') ? ` · shipped by ${s.source.slice(5)}` : ''), [badge, shareBtn]));
  }
}

function drawImports() {
  const list = $('imports');
  list.textContent = '';
  if (!state.imports.length) list.appendChild(empty('Nothing imported yet'));
  for (const it of state.imports) {
    const when = it.at ? new Date(it.at * 1000).toLocaleDateString() : '';
    list.appendChild(row(it.name, [it.by, when].filter(Boolean).join(' · '), [button('Remove', '', () => remove(it.name))]));
  }
}

function take(data) {
  if (!data) return;
  state.scenarios = Array.isArray(data.scenarios) ? data.scenarios : [];
  state.imports = Array.isArray(data.imports) ? data.imports : [];
  state.hub = typeof data.hub === 'string' ? data.hub : '';
  $('code-in').placeholder = state.hub ? 'Paste a code here (ZX-… or WDS1.…)' : 'Paste a code here (WDS1.…)';
  drawScenarios();
  drawImports();
}

function tab(which) {
  for (const t of document.querySelectorAll('.tab')) t.setAttribute('aria-selected', String(t.dataset.tab === which));
  $('tab-share').hidden = which !== 'share';
  $('tab-import').hidden = which !== 'import';
  status('');
  (which === 'share' ? $('filter') : $('code-in')).focus();
}

// ---- share ----

async function share(s) {
  status('Packing…');
  const r = await post('share', { key: s.key });
  if (!r.ok) { status(r.why, 'err'); return; }
  let code;
  try { code = await packCode(r.data.doc); } catch (e) { status('That scenario could not be packed into a code', 'err'); return; }
  state.code = code;
  $('share-name').textContent = r.data.name;
  $('share-about').textContent = `Revision ${r.data.rev}, with where its things are placed. Anyone with Director access on a WHIP server `
    + 'running Scenario Share pastes it into Import. Recorded drives and lore characters stay on this server.';
  $('code-out').value = code;
  $('code-len').textContent = `(${code.length.toLocaleString()} characters)`;
  $('get-short').hidden = !state.hub;
  $('get-short').disabled = false;
  $('short').hidden = true;
  $('short-note').textContent = state.hub ? 'A short code puts this scenario on the public scenario hub.' : '';
  $('share-list').hidden = true;
  $('share-code').hidden = false;
  status('');
  $('code-out').select();
}

async function getShort() {
  const b = $('get-short');
  b.disabled = true;
  $('short-note').textContent = 'Uploading…';
  try {
    const d = await hub('/v1/codes', { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: state.code });
    $('short-out').value = d.id;
    $('short').hidden = false;
    b.hidden = true;
    $('short-note').textContent = 'Anyone with this code can fetch the scenario from the hub.';
  } catch (e) {
    $('short-note').textContent = e.message;
    b.disabled = false;
  }
}

// ---- import ----

async function readCode() {
  const mine = ++state.reading;
  state.doc = null;
  $('import').disabled = true;
  const text = $('code-in').value.replace(/\s+/g, '');
  if (!text) { $('preview').textContent = ''; return; }
  let doc = null, err = '', long = text;
  try {
    if (SHORT_RE.test(text)) {
      if (!state.hub) throw new Error('This server has no scenario hub set up for short codes');
      $('preview').textContent = 'Looking it up…';
      const d = await hub('/v1/codes/' + encodeURIComponent(text.toUpperCase()));
      if (typeof d.code !== 'string') throw new Error('The scenario hub sent back nothing usable');
      long = d.code.replace(/\s+/g, '');
    }
    doc = await unpackCode(long);
  } catch (e) { err = e.message; }
  if (mine !== state.reading) return;   // a newer paste is being read
  if (!doc) { $('preview').textContent = err; $('preview').style.color = 'var(--err)'; return; }
  state.doc = doc;
  state.long = long;
  $('preview').style.color = '';
  const world = Array.isArray(doc.world) ? doc.world.length : 0;
  const variants = Array.isArray(doc.variants) && doc.variants.length > 1 ? ` · ${doc.variants.length} variants` : '';
  $('preview').textContent = `${doc.name || 'A scenario'}: ${plural(doc.nodes.length, 'card')}, ${plural(world, 'placed thing')}${variants}`
    + (doc.description ? ` — ${doc.description}` : '');
  if (!$('name-in').value.trim()) $('name-in').value = String(doc.name || '').slice(0, 60);
  $('import').disabled = false;
}

async function doImport() {
  if (!state.doc) return;
  $('import').disabled = true;
  status('Importing…');
  const r = await post('import', { code: state.long, name: $('name-in').value.trim() });
  if (!r.ok) { status(r.why, 'err'); $('import').disabled = false; return; }
  take(r.data);
  const done = r.data.done || {};
  $('code-in').value = '';
  $('name-in').value = '';
  $('preview').textContent = '';
  state.doc = null;
  const problems = Array.isArray(done.problems) ? done.problems : [];
  if (problems.length) status(`"${done.name}" imported. Check found: ${problems.join('; ')}. Fix these in the editor before switching it on.`, 'warn');
  else status(`"${done.name}" imported: Director > New > ${done.name}`, 'ok');
}

async function remove(name) {
  const r = await post('remove', { name });
  if (!r.ok) { status(r.why, 'err'); return; }
  take(r.data);
  status(`"${name}" removed. Scenarios already made from it stay.`, 'ok');
}

// ---- wiring ----

function show(data) {
  take(data);
  $('share-list').hidden = false;
  $('share-code').hidden = true;
  $('app').hidden = false;
  tab('share');
}
function hide() { $('app').hidden = true; }

window.addEventListener('message', (e) => {
  const m = e.data || {};
  if (m.action === 'open') show(m.data);
  else if (m.action === 'close') hide();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && !$('app').hidden) { hide(); post('close'); }
});
$('close').addEventListener('click', () => { hide(); post('close'); });
for (const t of document.querySelectorAll('.tab')) t.addEventListener('click', () => tab(t.dataset.tab));
$('filter').addEventListener('input', drawScenarios);
$('back').addEventListener('click', () => { $('share-code').hidden = true; $('share-list').hidden = false; status(''); $('filter').focus(); });
$('copy').addEventListener('click', () => status(copyText($('code-out')) ? 'Code copied' : 'Select the code and press Ctrl+C', 'ok'));
$('copy-short').addEventListener('click', () => status(copyText($('short-out')) ? 'Short code copied' : 'Select the code and press Ctrl+C', 'ok'));
$('get-short').addEventListener('click', getShort);
$('code-in').addEventListener('input', readCode);
$('import').addEventListener('click', doImport);

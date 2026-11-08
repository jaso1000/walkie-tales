// WalkieTales companion: serves the remote-control page (installable as an app) and forwards
// /p/<player id>/api/* to that player. Several players can be added, found on the Wi-Fi, renamed and removed.
// No dependencies. Configure with environment variables (all optional):
//   PLAYERS       starting list, e.g. "Riv=http://192.168.1.222:8080,Sam=http://192.168.1.223:8080"
//   PLAYER_URL    a single starting player (older setups)
//   PLAYER_PIN    PIN for the PLAYER_URL player (if set, the page won't ask for it)
//   SCAN_SUBNETS  extra /24 networks to search, e.g. "192.168.1,10.0.0" (the players' own networks are always searched)
//   DATA_DIR      where the player list is saved (default /data, falls back to ./data)
//   PORT          port to listen on (default 8090)
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 8090);
const WEB = path.join(__dirname, 'web');
const STATIC = {
  '/manifest.json': 'application/manifest+json',
  '/icon-192.png': 'image/png',
  '/icon-512.png': 'image/png',
  '/icon-maskable-512.png': 'image/png',
  '/apple-touch-icon.png': 'image/png',
  '/favicon.png': 'image/png',
};

// ------------------------------------------------------------------ player list

function dataDir() {
  for (const d of [process.env.DATA_DIR, '/data', path.join(__dirname, 'data')].filter(Boolean)) {
    try { fs.mkdirSync(d, { recursive: true }); fs.accessSync(d, fs.constants.W_OK); return d; } catch (e) { /* try the next */ }
  }
  return null;
}
const DATA = dataDir();
const LIST = DATA ? path.join(DATA, 'players.json') : null;

/** Players live on the home network: only plain http(s) to private addresses or local host names. */
function cleanUrl(u) {
  let x;
  try { x = new URL(/^https?:\/\//i.test(u) ? u : 'http://' + u); } catch (e) { return null; }
  if (!/^https?:$/.test(x.protocol) || x.username || x.password) return null;
  const h = x.hostname;
  const ip = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  const priv = ip ? (+ip[1] === 10 || (+ip[1] === 172 && +ip[2] >= 16 && +ip[2] <= 31) || (+ip[1] === 192 && +ip[2] === 168))
    : (!h.includes('.') || /\.(local|lan|home|internal|home\.arpa)$/i.test(h));
  if (!priv) return null;
  if (!x.port) x.port = '8080';
  return x.protocol + '//' + x.host;
}

let players = [];
function load() {
  try { players = JSON.parse(fs.readFileSync(LIST, 'utf8')).filter(p => p && p.id && cleanUrl(p.url)); } catch (e) { players = []; }
  const seed = [];
  for (const part of (process.env.PLAYERS || '').split(',').map(s => s.trim()).filter(Boolean)) {
    const i = part.indexOf('=');
    seed.push(i > 0 ? { name: part.slice(0, i).trim(), url: part.slice(i + 1).trim() } : { name: '', url: part });
  }
  if (process.env.PLAYER_URL) seed.push({ name: '', url: process.env.PLAYER_URL, pin: process.env.PLAYER_PIN || '' });
  for (const s of seed) {
    const url = cleanUrl(s.url);
    if (!url) { console.log('Ignoring player address (not on the home network):', s.url); continue; }
    const have = players.find(p => p.url === url);
    if (have) { if (s.pin) have.pin = s.pin; continue; }
    players.push({ id: newId(), name: s.name || '', url, pin: s.pin || '' });
  }
  save();
}
function save() {
  if (!LIST) return;
  try { fs.writeFileSync(LIST + '.tmp', JSON.stringify(players, null, 2)); fs.renameSync(LIST + '.tmp', LIST); } catch (e) { console.log('Could not save players:', e.message); }
}
function newId() { return crypto.randomBytes(4).toString('hex'); }
const pub = (p) => ({ id: p.id, name: p.name, url: p.url, pinSaved: !!p.pin });

// ------------------------------------------------------------------ finding players on the Wi-Fi

function looksLikePlayer(url, timeout) {
  return new Promise((resolve) => {
    const r = http.get(url + '/', { timeout }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (c) => { if (body.length < 4096) body += c; });
      res.on('end', () => resolve(res.statusCode === 200 && /Walkie ?Tales/i.test(body)));
    });
    r.on('timeout', () => r.destroy());
    r.on('error', () => resolve(false));
  });
}

async function scan() {
  const nets = new Set((process.env.SCAN_SUBNETS || '').split(',').map(s => s.trim()).filter(s => /^\d+\.\d+\.\d+$/.test(s)));
  for (const p of players) { const m = p.url.match(/\/\/(\d+\.\d+\.\d+)\.\d+/); if (m) nets.add(m[1]); }
  if (!nets.size) nets.add('192.168.1');
  const urls = [];
  for (const n of nets) for (let i = 1; i < 255; i++) urls.push('http://' + n + '.' + i + ':8080');
  const found = [];
  let next = 0;
  await Promise.all(Array.from({ length: 64 }, async () => {
    while (next < urls.length) {
      const u = urls[next++];
      if (await looksLikePlayer(u, 1500)) found.push(u);
    }
  }));
  const added = [];
  for (const u of found) {
    if (players.some(p => p.url === u)) continue;
    const p = { id: newId(), name: '', url: u, pin: '' };
    players.push(p);
    added.push(pub(p));
  }
  if (added.length) save();
  return { searched: [...nets].map(n => n + '.x'), found: found.length, added };
}

// ------------------------------------------------------------------ http

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(obj));
}
function readJson(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', (c) => { if (b.length < 10000) b += c; });
    req.on('end', () => { try { resolve(JSON.parse(b || '{}')); } catch (e) { resolve({}); } });
  });
}

function proxy(req, res, p, rest) {
  let target;
  try { target = new URL(p.url + rest); } catch (e) { return json(res, 500, { error: 'Bad player address' }); }
  if (p.pin) target.searchParams.delete('pin');
  const headers = { ...req.headers };
  delete headers.host;
  delete headers.connection;
  if (p.pin) headers['x-pin'] = p.pin;
  const upstream = http.request(target, { method: req.method, headers, timeout: req.method === 'PUT' ? 0 : 15000 }, (pr) => {
    const h = { ...pr.headers };
    delete h.connection;
    res.writeHead(pr.statusCode || 502, h);
    pr.pipe(res);
  });
  upstream.on('timeout', () => upstream.destroy(new Error('timed out')));
  upstream.on('error', (e) => {
    if (!res.headersSent) json(res, 502, { error: 'Player unreachable (' + e.message + ')' });
    else res.end();
  });
  req.pipe(upstream);
}

let scanning = null;

// ------------------------------------------------------------------ app updates

// The newest GitHub release, kept in the data folder. A file named local.apk with a local.txt holding its version,
// put in <data>/update, is used instead (for trying a build before it's released).
const REPO = process.env.UPDATE_REPO || 'jaso1000/walkie-tales';
const UPDATES = DATA ? path.join(DATA, 'update') : null;
let latestInfo = null, latestAt = 0;

async function latest() {
  if (!UPDATES) throw new Error('No writable data folder');
  fs.mkdirSync(UPDATES, { recursive: true });
  const local = path.join(UPDATES, 'local.apk');
  if (fs.existsSync(local)) {
    return { version: fs.readFileSync(path.join(UPDATES, 'local.txt'), 'utf8').trim(), file: local };
  }
  if (latestInfo && Date.now() - latestAt < 5 * 60000) return latestInfo;
  const r = await fetch('https://api.github.com/repos/' + REPO + '/releases/latest', { headers: { 'User-Agent': 'walkietales-companion', Accept: 'application/vnd.github+json' } });
  if (!r.ok) throw new Error('GitHub answered ' + r.status);
  const rel = await r.json();
  const asset = (rel.assets || []).find(a => /\.apk$/i.test(a.name));
  if (!asset) throw new Error('The latest release has no app file');
  const version = String(rel.tag_name || '').replace(/^v/i, '');
  if (!/^[0-9][0-9.]*$/.test(version)) throw new Error('Unexpected release name');
  const file = path.join(UPDATES, 'v' + version + '.apk');
  if (!fs.existsSync(file)) {
    const d = await fetch(asset.browser_download_url, { headers: { 'User-Agent': 'walkietales-companion' } });
    if (!d.ok) throw new Error('Download failed (' + d.status + ')');
    fs.writeFileSync(file + '.tmp', Buffer.from(await d.arrayBuffer()));
    fs.renameSync(file + '.tmp', file);
    for (const f of fs.readdirSync(UPDATES)) if (/^v.*\.apk$/.test(f) && f !== path.basename(file)) fs.unlinkSync(path.join(UPDATES, f));
  }
  latestInfo = { version, file };
  latestAt = Date.now();
  return latestInfo;
}

/** Send the newest version to one player. Android on the player checks it's newer and signed with the same key. */
async function pushUpdate(req, res, p, force) {
  let info;
  try { info = await latest(); } catch (e) { return json(res, 502, { error: e.message }); }
  const body = fs.readFileSync(info.file);
  const headers = { 'Content-Type': 'application/vnd.android.package-archive', 'Content-Length': body.length, 'x-pin': p.pin || req.headers['x-pin'] || '' };
  const up = http.request(new URL(p.url + '/api/update' + (force ? '?force=1' : '')), { method: 'PUT', headers, timeout: 120000 }, (pr) => {
    res.writeHead(pr.statusCode || 502, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    pr.pipe(res);
  });
  up.on('timeout', () => up.destroy(new Error('timed out')));
  up.on('error', (e) => { if (!res.headersSent) json(res, 502, { error: 'Player unreachable (' + e.message + ')' }); else res.end(); });
  up.end(body);
}

const server = http.createServer(async (req, res) => {
  const url = req.url || '/';
  const pathname = url.split('?')[0];
  if (req.method === 'GET' && (pathname === '/' || pathname === '/index.html')) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
    return res.end(fs.readFileSync(path.join(WEB, 'index.html')));
  }
  if (req.method === 'GET' && STATIC[pathname]) {
    try {
      const body = fs.readFileSync(path.join(WEB, pathname.slice(1)));
      res.writeHead(200, { 'Content-Type': STATIC[pathname], 'Cache-Control': 'public, max-age=86400' });
      return res.end(body);
    } catch (e) { return json(res, 404, { error: 'Not found' }); }
  }
  if (pathname === '/healthz') return json(res, 200, { ok: true, players: players.length });

  // ---- the player list
  if (pathname === '/players') {
    if (req.method === 'GET') return json(res, 200, { players: players.map(pub) });
    if (req.method === 'POST') {
      const b = await readJson(req);
      const u = cleanUrl(String(b.url || '').trim());
      if (!u) return json(res, 400, { error: 'Use the address shown on the player, like 192.168.1.50:8080' });
      if (players.some(p => p.url === u)) return json(res, 409, { error: 'That player is already in the list' });
      const p = { id: newId(), name: String(b.name || '').trim().slice(0, 40), url: u, pin: '' };
      players.push(p); save();
      return json(res, 200, { player: pub(p) });
    }
  }
  if (pathname === '/players/scan' && req.method === 'POST') {
    if (!scanning) scanning = scan().finally(() => { scanning = null; });
    try { return json(res, 200, await scanning); } catch (e) { return json(res, 500, { error: e.message }); }
  }
  let m = pathname.match(/^\/players\/([0-9a-f]{8})$/);
  if (m) {
    const i = players.findIndex(p => p.id === m[1]);
    if (i < 0) return json(res, 404, { error: 'No such player' });
    if (req.method === 'DELETE') { players.splice(i, 1); save(); return json(res, 200, { ok: true }); }
    if (req.method === 'PATCH' || req.method === 'POST') {
      const b = await readJson(req);
      if (typeof b.name === 'string') players[i].name = b.name.trim().slice(0, 40);
      if (typeof b.url === 'string') {
        const u = cleanUrl(b.url.trim());
        if (!u) return json(res, 400, { error: 'Use the address shown on the player, like 192.168.1.50:8080' });
        players[i].url = u;
      }
      save();
      return json(res, 200, { player: pub(players[i]) });
    }
  }

  // ---- app updates
  if (pathname === '/update/info' && req.method === 'GET') {
    try { return json(res, 200, { version: (await latest()).version }); } catch (e) { return json(res, 502, { error: e.message }); }
  }
  m = pathname.match(/^\/p\/([0-9a-f]{8})\/update$/);
  if (m && req.method === 'POST') {
    const p = players.find(x => x.id === m[1]);
    if (!p) return json(res, 404, { error: 'That player was removed' });
    return pushUpdate(req, res, p, /[?&]force=1/.test(url));
  }

  // ---- /p/<id>/api/... goes to that player
  m = url.match(/^\/p\/([0-9a-f]{8})(\/api\/.*)$/);
  if (m) {
    const p = players.find(x => x.id === m[1]);
    if (!p) return json(res, 404, { error: 'That player was removed' });
    return proxy(req, res, p, m[2]);
  }
  // older pages: /api/... goes to the first player
  if (url.startsWith('/api/')) {
    if (!players.length) return json(res, 500, { error: 'No players added yet' });
    return proxy(req, res, players[0], url);
  }
  return json(res, 404, { error: 'Not found' });
});

load();
server.requestTimeout = 0; // allow long uploads
server.listen(PORT, () => {
  console.log(`WalkieTales companion on :${PORT}, ${players.length} player(s)${DATA ? ', list in ' + LIST : ' (list not saved: no writable data folder)'}`);
});
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => server.close(() => process.exit(0)));

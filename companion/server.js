// WalkieTales companion: serves the remote-control page (installable as an app) and forwards
// /p/<player id>/api/* to that player. Several players can be added, found on the Wi-Fi, renamed and removed.
// No dependencies. Configure with environment variables (all optional):
//   PLAYERS       starting list, e.g. "Ruby=http://192.168.1.50:8480,Sam=http://192.168.1.51:8480"
//   PLAYER_URL    a single starting player (older setups)
//   PLAYER_PIN    PIN for the PLAYER_URL player (if set, the page won't ask for it)
//   SCAN_SUBNETS  extra /24 networks to search, e.g. "192.168.1,10.0.0" (the players' own networks are always searched)
//   DATA_DIR      where the player list is saved (default /data, falls back to ./data)
//   PORT          port to listen on (default 8480)
'use strict';
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 8480);
// Players answer on 8480 from version 1.45; older ones on 8080. A saved player that has moved is followed automatically.
const PLAYER_PORT = '8480', OLD_PLAYER_PORT = '8080';
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
  if (!x.port) x.port = PLAYER_PORT;
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
    const have = players.find(p => p.url === url || sameHost(p.url, url)); // same phone, maybe on its new port
    if (have) { if (s.pin) have.pin = s.pin; continue; }
    players.push({ id: newId(), name: s.name || '', url, pin: s.pin || '' });
  }
  save();
}
function save() {
  if (!LIST) return;
  try { fs.writeFileSync(LIST + '.tmp', JSON.stringify(players, null, 2)); fs.renameSync(LIST + '.tmp', LIST); } catch (e) { console.log('Could not save players:', e.message); }
}
function sameHost(a, b) { try { return new URL(a).hostname === new URL(b).hostname; } catch (e) { return false; } }
/** A player saved on the old port that now answers on the new one (it was updated): follow it. */
async function followMove(p) {
  let u; try { u = new URL(p.url); } catch (e) { return false; }
  if (u.port !== OLD_PLAYER_PORT) return false;
  const moved = u.protocol + '//' + u.hostname + ':' + PLAYER_PORT;
  if (!(await looksLikePlayer(moved, 4000))) return false;
  console.log('Player ' + (p.name || p.url) + ' moved to ' + moved);
  p.url = moved; save();
  return true;
}
function newId() { return crypto.randomBytes(4).toString('hex'); }
// When each player was last heard from (kept in memory; the all-players page shows "Seen 5 min ago").
const seen = {};
const pub = (p) => ({ id: p.id, name: p.name, url: p.url, pinSaved: !!p.pin, lastSeen: seen[p.id] || 0 });

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
  for (const n of nets) for (let i = 1; i < 255; i++) for (const port of [PLAYER_PORT, OLD_PLAYER_PORT]) urls.push('http://' + n + '.' + i + ':' + port);
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
    const same = players.find(p => sameHost(p.url, u)); // a saved player that has moved to the new port
    if (same) { if (u.endsWith(':' + PLAYER_PORT)) { same.url = u; save(); } continue; }
    if (found.some(o => o !== u && sameHost(o, u) && o.endsWith(':' + PLAYER_PORT))) continue; // answers on both: keep the new one
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
    seen[p.id] = Date.now();
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

// ------------------------------------------------------------------ iPhone-proof audio
// iPhones can't play Ogg (Vorbis/Opus) at all, and audiobook tools often save it under an .mp3 name. Android
// plays it fine, so only an iPhone's copy is converted: fetched from the player, turned into a real MP3 with
// ffmpeg, and put back under an .mp3 name.
const { spawn } = require('child_process');
const IPHONE_CANT = new Set(['ogg']);

function playerCall(p, pin, method, apiPath, body, type) {
  return new Promise((resolve, reject) => {
    const headers = { 'x-pin': p.pin || pin || '' };
    if (body != null) { headers['Content-Type'] = type || 'application/json'; headers['Content-Length'] = body.length; }
    const r = http.request(new URL(p.url + apiPath), { method, headers, timeout: 300000 }, (pr) => {
      const chunks = [];
      pr.on('data', (c) => chunks.push(c));
      pr.on('end', () => resolve({ status: pr.statusCode, body: Buffer.concat(chunks) }));
    });
    r.on('timeout', () => r.destroy(new Error('timed out')));
    r.on('error', reject);
    r.end(body == null ? undefined : body);
  });
}
const pjson = async (p, pin, method, apiPath, obj) => {
  const r = await playerCall(p, pin, method, apiPath, obj == null ? null : Buffer.from(JSON.stringify(obj)));
  let j = {}; try { j = JSON.parse(r.body.toString('utf8') || '{}'); } catch (e) { /* not JSON */ }
  if (r.status !== 200) { const e = new Error(j.error || 'Player answered ' + r.status); e.status = r.status; throw e; }
  return j;
};
function toMp3(input) {
  return new Promise((resolve, reject) => {
    const ff = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-i', 'pipe:0', '-vn', '-map_metadata', '0',
      '-c:a', 'libmp3lame', '-b:a', '128k', '-id3v2_version', '3', '-f', 'mp3', 'pipe:1']);
    const out = [], err = [];
    ff.stdout.on('data', (c) => out.push(c));
    ff.stderr.on('data', (c) => err.push(c));
    ff.on('error', (e) => reject(new Error(e.code === 'ENOENT' ? 'ffmpeg is missing on the server' : e.message)));
    ff.on('close', (code) => code === 0 && out.length ? resolve(Buffer.concat(out)) : reject(new Error('Couldn’t convert (' + Buffer.concat(err).toString().trim().slice(0, 120) + ')')));
    ff.stdin.on('error', () => {});
    ff.stdin.end(input);
  });
}
// ---- Library thumbnails. Covers come from the player at full size (often 600-1300 px, no caching), which made the
// remote's Library slow to scroll. The server fetches each cover once, shrinks it to 360 px, keeps it, and lets the
// browser keep it for a week (the page asks with the folder's stamp, so a new cover gets a new address).
// The PIN is part of the key, so a wrong PIN never gets a kept picture: it goes to the player and is refused there.
const THUMB_MAX = 500;
const thumbs = new Map(); // key -> Buffer (null = no cover), oldest first
function thumbKey(id, pin, folder, v) { return crypto.createHash('sha256').update([id, pin, folder, v].join('\n')).digest('hex'); }
function keepThumb(k, buf) {
  thumbs.delete(k); thumbs.set(k, buf);
  while (thumbs.size > THUMB_MAX) thumbs.delete(thumbs.keys().next().value);
}
function shrink(input) {
  return new Promise((resolve, reject) => {
    const ff = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-i', 'pipe:0', '-vf',
      "scale='if(gt(iw,ih),-2,min(360,iw))':'if(gt(iw,ih),min(360,ih),-2)'", '-frames:v', '1', '-q:v', '5',
      '-f', 'image2pipe', '-c:v', 'mjpeg', 'pipe:1']);
    const out = [];
    ff.stdout.on('data', (c) => out.push(c));
    ff.stderr.on('data', () => {});
    ff.on('error', reject);
    ff.on('close', (code) => code === 0 && out.length ? resolve(Buffer.concat(out)) : reject(new Error('shrink failed')));
    ff.stdin.on('error', () => {});
    ff.stdin.end(input);
  });
}
async function serveThumb(req, res, p, q) {
  const folder = q.get('folder') || '', v = q.get('v') || '';
  const pin = p.pin || req.headers['x-pin'] || q.get('pin') || '';
  const k = thumbKey(p.id, pin, folder, v);
  const cache = v ? 'private, max-age=604800, immutable' : 'private, max-age=600';
  if (thumbs.has(k)) {
    const b = thumbs.get(k); keepThumb(k, b);
    if (!b) { res.writeHead(404, { 'Cache-Control': cache }); return res.end(); }
    res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Content-Length': b.length, 'Cache-Control': cache });
    return res.end(b);
  }
  let r;
  try { r = await playerCall(p, pin, 'GET', '/api/cover?folder=' + encodeURIComponent(folder)); }
  catch (e) { return json(res, 502, { error: 'Player unreachable' }); }
  seen[p.id] = Date.now();
  if (r.status === 404) { keepThumb(k, null); res.writeHead(404, { 'Cache-Control': cache }); return res.end(); }
  if (r.status !== 200) return json(res, r.status, { error: 'Player answered ' + r.status });
  let b;
  try { b = await shrink(r.body); } catch (e) { b = r.body; } // fall back to the full picture
  keepThumb(k, b);
  res.writeHead(200, { 'Content-Type': 'image/jpeg', 'Content-Length': b.length, 'Cache-Control': cache });
  return res.end(b);
}

/** Make one folder play on an iPhone. Android players are left alone (they play Ogg). */
async function fixForIphone(p, pin, folder) {
  const st = await pjson(p, pin, 'GET', '/api/status');
  if (!/ios/i.test(String(st.version || ''))) return { iphone: false, converted: [], failed: [] };
  const q = '/api/folder?name=' + encodeURIComponent(folder);
  const files = (await pjson(p, pin, 'GET', q + '&tags=1')).files || [];
  const bad = files.filter(f => IPHONE_CANT.has(f.kind));
  const converted = [], failed = [];
  for (const f of bad) {
    try {
      const got = await playerCall(p, pin, 'GET', '/api/file?folder=' + encodeURIComponent(folder) + '&name=' + encodeURIComponent(f.name));
      if (got.status !== 200) throw new Error(got.status === 404 ? 'this iPhone can’t send files yet (update it)' : 'download failed');
      const mp3 = await toMp3(got.body);
      const name = f.name.replace(/\.[^.]+$/, '') + '.mp3';
      const up = await playerCall(p, pin, 'PUT', '/api/upload?folder=' + encodeURIComponent(folder) + '&name=' + encodeURIComponent(name), mp3, 'application/octet-stream');
      if (up.status !== 200) throw new Error('upload failed');
      if (name !== f.name) await pjson(p, pin, 'POST', '/api/file/delete', { folder, name: f.name }).catch(() => {});
      converted.push(name);
    } catch (e) { failed.push(f.name + ': ' + e.message); }
  }
  return { iphone: true, checked: files.length, converted, failed };
}

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

// Voice messages: any recording (WebM/Opus from Chrome, MP4/AAC from Safari, a phone recorder file) → MP3,
// which every player (Android and iPhone) can play.
function readBody(req, max) {
  return new Promise((resolve, reject) => {
    const chunks = []; let n = 0;
    req.on('data', (c) => { n += c.length; if (n > max) { reject(new Error('Too long')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}
function toVoiceMp3(input) {
  return new Promise((resolve, reject) => {
    const ff = spawn('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-i', 'pipe:0', '-vn', '-ac', '1', '-ar', '44100',
      '-af', 'loudnorm=I=-16:TP=-1.5', '-c:a', 'libmp3lame', '-b:a', '96k', '-f', 'mp3', 'pipe:1']);
    const out = [], err = [];
    ff.stdout.on('data', (c) => out.push(c));
    ff.stderr.on('data', (c) => err.push(c));
    ff.on('error', (e) => reject(new Error(e.code === 'ENOENT' ? 'ffmpeg is missing on the server' : e.message)));
    ff.on('close', (code) => code === 0 && out.length ? resolve(Buffer.concat(out)) : reject(new Error('Couldn’t read that recording')));
    ff.stdin.on('error', () => {});
    ff.stdin.end(input);
  });
}

const handler = async (req, res) => {
  // No framing (tap-tricks), no type sniffing, no referrer leaks (PINs can be in cover image links).
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Referrer-Policy', 'no-referrer');
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
  if (pathname === '/walkietales-home.crt' && req.method === 'GET') { // the home authority, to trust on a phone
    try {
      const der = caDer();
      res.writeHead(200, { 'Content-Type': 'application/x-x509-ca-cert', 'Content-Length': der.length,
        'Content-Disposition': 'attachment; filename="walkietales-home.crt"', 'Cache-Control': 'no-store' });
      return res.end(der);
    } catch (e) { return json(res, 404, { error: 'No https certificate on this server' }); }
  }

  // ---- the player list
  if (pathname === '/players') {
    if (req.method === 'GET') return json(res, 200, { players: players.map(pub) });
    if (req.method === 'POST') {
      const b = await readJson(req);
      const u = cleanUrl(String(b.url || '').trim());
      if (!u) return json(res, 400, { error: 'Use the address shown on the player, like 192.168.1.50:8480' });
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
        if (!u) return json(res, 400, { error: 'Use the address shown on the player, like 192.168.1.50:8480' });
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

  // ---- voice message: recording in, MP3 out
  if (pathname === '/convert-audio' && req.method === 'POST') {
    try {
      const mp3 = await toVoiceMp3(await readBody(req, 50 * 1024 * 1024));
      res.writeHead(200, { 'Content-Type': 'audio/mpeg', 'Content-Length': mp3.length, 'Cache-Control': 'no-store' });
      return res.end(mp3);
    } catch (e) { return json(res, 400, { error: e.message }); }
  }

  // ---- make a folder play on an iPhone (converts Ogg to MP3 on that player only)
  m = pathname.match(/^\/p\/([0-9a-f]{8})\/fix-audio$/);
  if (m && req.method === 'POST') {
    const p = players.find(x => x.id === m[1]);
    if (!p) return json(res, 404, { error: 'That player was removed' });
    const b = await readJson(req);
    if (!b.folder) return json(res, 400, { error: 'Which folder?' });
    try { return json(res, 200, await fixForIphone(p, req.headers['x-pin'], String(b.folder))); }
    catch (e) { return json(res, e.status === 401 ? 401 : 502, { error: e.message }); }
  }

  // ---- small cached cover for a Library tile
  m = pathname.match(/^\/p\/([0-9a-f]{8})\/thumb$/);
  if (m && req.method === 'GET') {
    const p = players.find(x => x.id === m[1]);
    if (!p) return json(res, 404, { error: 'That player was removed' });
    return serveThumb(req, res, p, new URL(url, 'http://x').searchParams);
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
};
const server = http.createServer(handler);

// Check on every player once a minute (its PIN-free front page), so "last seen" stays right even when nobody has the remote open.
function checkAll() {
  for (const p of players) looksLikePlayer(p.url, 5000).then(async ok => {
    if (ok || await followMove(p)) seen[p.id] = Date.now();
  });
}
setInterval(checkAll, 60000).unref();
setTimeout(checkAll, 2000);

// The same remote over https (a home-made certificate, made once and kept in the data folder): browsers only allow the
// microphone, for voice messages, on a secure address. The first visit shows a warning to accept once.
const HTTPS_PORT = Number(process.env.HTTPS_PORT || 0);
// The certificate comes from a small "home" certificate authority made on first start (kept in /data/tls). Installing
// and trusting that authority on a phone (Settings → Remote control → Trust this server) makes the https address fully
// trusted there: no warning, and an iPhone can fetch the home-screen icon. Apple only accepts such a certificate if it
// lasts at most 825 days and says it's for a web server, so the server certificate is renewed automatically. The
// authority is limited to home-network addresses, so even if its key leaked it couldn't vouch for a real website.
const TLS = DATA ? path.join(DATA, 'tls') : null;
const CA_CERT = TLS && path.join(TLS, 'ca.pem');
function tlsHosts() {
  return (process.env.HTTPS_HOSTS || '').split(',').map(h => h.trim()).filter(Boolean);
}
function ssl(args, opts) { return require('child_process').execFileSync('openssl', args, Object.assign({ stdio: 'pipe' }, opts || {})); }
function makeCa() {
  const permitted = ['IP:192.168.0.0/255.255.0.0', 'IP:10.0.0.0/255.0.0.0', 'IP:172.16.0.0/255.240.0.0', 'IP:127.0.0.0/255.0.0.0',
    'DNS:localhost', 'DNS:.local', 'DNS:.lan', 'DNS:.home', 'DNS:.internal', 'DNS:.home.arpa']
    .concat(tlsHosts().filter(h => !/^[0-9.]+$/.test(h)).map(h => 'DNS:' + h));
  ssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '3650', '-sha256', '-subj', '/CN=WalkieTales home remote',
    '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0', '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
    '-addext', 'nameConstraints=critical,' + permitted.map(x => 'permitted;' + x).join(','),
    '-keyout', path.join(TLS, 'ca-key.pem'), '-out', CA_CERT]);
}
function makeServerCert() {
  const san = ['DNS:localhost', 'IP:127.0.0.1'].concat(tlsHosts().map(h => (/^[0-9.]+$/.test(h) ? 'IP:' : 'DNS:') + h)).join(',');
  const ext = path.join(TLS, 'server.ext'), csr = path.join(TLS, 'server.csr');
  fs.writeFileSync(ext, 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n' +
    'extendedKeyUsage=serverAuth\nsubjectAltName=' + san + '\n');
  ssl(['req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=WalkieTales remote', '-keyout', path.join(TLS, 'key.pem'), '-out', csr]);
  ssl(['x509', '-req', '-in', csr, '-CA', CA_CERT, '-CAkey', path.join(TLS, 'ca-key.pem'), '-CAcreateserial', '-days', '825',
    '-sha256', '-extfile', ext, '-out', path.join(TLS, 'cert.pem')]);
  fs.writeFileSync(path.join(TLS, 'hosts.txt'), tlsHosts().join(','));
  console.log('https certificate made for ' + san);
}
/** Make (or renew) what's missing or out of date. Returns true if the server certificate changed. */
function ensureTls() {
  fs.mkdirSync(TLS, { recursive: true });
  let fresh = false;
  if (!fs.existsSync(CA_CERT)) { makeCa(); fresh = true; } // first start, or upgrading from the old one-off certificate
  const cert = path.join(TLS, 'cert.pem');
  let renew = fresh || !fs.existsSync(cert);
  if (!renew) {
    try { ssl(['x509', '-checkend', String(30 * 86400), '-noout', '-in', cert]); } catch (e) { renew = true; } // expires within 30 days
    const was = fs.existsSync(path.join(TLS, 'hosts.txt')) ? fs.readFileSync(path.join(TLS, 'hosts.txt'), 'utf8') : null;
    if (was !== tlsHosts().join(',')) renew = true; // HTTPS_HOSTS changed
  }
  if (renew) makeServerCert();
  return renew;
}
function tlsOptions() {
  return { key: fs.readFileSync(path.join(TLS, 'key.pem')),
    cert: Buffer.concat([fs.readFileSync(path.join(TLS, 'cert.pem')), fs.readFileSync(CA_CERT)]) };
}
/** The authority's certificate, for phones to install (DER, which iPhones and Android both accept). */
function caDer() {
  const pem = fs.readFileSync(CA_CERT, 'utf8');
  return Buffer.from(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''), 'base64');
}
function startHttps() {
  if (!HTTPS_PORT || !TLS) return;
  try {
    ensureTls();
    const s = https.createServer(tlsOptions(), handler);
    s.requestTimeout = 0;
    s.listen(HTTPS_PORT, () => console.log('WalkieTales companion https on :' + HTTPS_PORT));
    setInterval(() => { // renew the server certificate before it runs out (it lasts 825 days)
      try { if (ensureTls()) s.setSecureContext(tlsOptions()); } catch (e) { console.log('https renew failed: ' + e.message); }
    }, 24 * 3600 * 1000).unref();
  } catch (e) { console.log('https not started: ' + e.message); }
}
startHttps();

load();
server.requestTimeout = 0; // allow long uploads
server.listen(PORT, () => {
  console.log(`WalkieTales companion on :${PORT}, ${players.length} player(s)${DATA ? ', list in ' + LIST : ' (list not saved: no writable data folder)'}`);
});
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => server.close(() => process.exit(0)));

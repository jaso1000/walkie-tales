// WalkieTales companion: serves the remote-control page and forwards /api/* to the player.
// No dependencies. Configure with environment variables:
//   PLAYER_URL  e.g. http://192.168.1.50:8080   (shown on the player: Grown-up settings → Remote control)
//   PLAYER_PIN  the player's PIN (optional: if set, the page won't ask for it)
//   PORT        port to listen on (default 8090)
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const PLAYER_URL = (process.env.PLAYER_URL || '').replace(/\/+$/, '');
const PLAYER_PIN = process.env.PLAYER_PIN || '';
const PORT = Number(process.env.PORT || 8090);
const page = fs.readFileSync(path.join(__dirname, 'web', 'index.html'));

function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer((req, res) => {
  const url = req.url || '/';
  if (req.method === 'GET' && (url === '/' || url.startsWith('/index.html') || url.startsWith('/?'))) {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
    return res.end(page);
  }
  if (url === '/healthz') return json(res, 200, { ok: true, player: PLAYER_URL || null });
  if (!url.startsWith('/api/')) return json(res, 404, { error: 'Not found' });
  if (!PLAYER_URL) return json(res, 500, { error: 'PLAYER_URL is not set on the companion container' });

  let target;
  try { target = new URL(PLAYER_URL + url); } catch (e) { return json(res, 500, { error: 'Bad PLAYER_URL' }); }
  if (PLAYER_PIN) target.searchParams.delete('pin');

  const headers = { ...req.headers };
  delete headers.host;
  delete headers.connection;
  if (PLAYER_PIN) headers['x-pin'] = PLAYER_PIN;

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
});

server.requestTimeout = 0; // allow long uploads
server.listen(PORT, () => {
  console.log(`WalkieTales companion on :${PORT} -> ${PLAYER_URL || '(PLAYER_URL not set)'}${PLAYER_PIN ? ' (PIN from env)' : ''}`);
});
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => server.close(() => process.exit(0)));

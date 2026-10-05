// Matchmaker for Wilbur (UE5.5+ SignallingWebServer).
//
// Epic removed the Matchmaker in UE5.5. This replacement needs no changes to Wilbur and no npm packages:
// it polls each Wilbur's REST API (GET /api/status, enabled with --rest_api) and redirects every new
// browser to an instance that has a UE streamer connected and no player yet.
//
//   node matchmaker.js --config=<file.json>
//
// Config:
// {
//   "httpPort": 80, "listenIp": "127.0.0.1" | "",           // "" = all interfaces
//   "publicIp": "1.2.3.4" | "",                              // host used in redirects; "" = host the browser used
//   "pollIntervalMs": 1000, "reserveSeconds": 15,
//   "instances": [ { "index": 1, "httpPort": 8001 }, ... ]   // Wilbur player ports (HTTP + player WebSocket)
// }
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// Config + logging
// ---------------------------------------------------------------------------
const configArg = process.argv.find((a) => a.startsWith('--config='));
if (!configArg) {
    console.error('Usage: node matchmaker.js --config=<file.json>');
    process.exit(1);
}
const cfg = JSON.parse(fs.readFileSync(configArg.slice('--config='.length), 'utf8'));
const pollIntervalMs = cfg.pollIntervalMs || 1000;
const reserveMs = (cfg.reserveSeconds || 15) * 1000;

const logDir = cfg.logDir || path.join(process.cwd(), 'logs');
fs.mkdirSync(logDir, { recursive: true });
const logFile = path.join(logDir, `matchmaker_${new Date().toISOString().replace(/[:.]/g, '-')}.log`);

function log(msg) {
    const line = `${new Date().toISOString().slice(11, 23)} ${msg}`;
    console.log(line);
    fs.appendFile(logFile, line + '\n', () => {});
}

// ---------------------------------------------------------------------------
// Instance state (refreshed by polling)
// ---------------------------------------------------------------------------
const instances = cfg.instances.map((i) => ({
    index: i.index,
    httpPort: i.httpPort,
    online: false,
    streamers: 0,
    players: 0,
    reservedUntil: 0,
    lastChange: ''
}));

function describe(inst) {
    if (!inst.online) return 'offline';
    if (inst.streamers < 1) return 'no UE';
    if (inst.players > 0) return 'in use';
    if (inst.reservedUntil > Date.now()) return 'reserved';
    return 'free';
}

function fetchStatus(port) {
    return new Promise((resolve) => {
        const req = http.get({ host: '127.0.0.1', port, path: '/api/status', timeout: 1500 }, (res) => {
            let body = '';
            res.on('data', (c) => (body += c));
            res.on('end', () => {
                try {
                    resolve(res.statusCode === 200 ? JSON.parse(body) : null);
                } catch {
                    resolve(null);
                }
            });
        });
        req.on('timeout', () => req.destroy());
        req.on('error', () => resolve(null));
    });
}

async function pollOnce() {
    await Promise.all(
        instances.map(async (inst) => {
            const s = await fetchStatus(inst.httpPort);
            inst.online = !!s;
            inst.streamers = s ? s.streamer_count : 0;
            inst.players = s ? s.player_count : 0;
            // The reserved user has arrived (or someone else took it): the reservation is consumed.
            if (inst.players > 0) inst.reservedUntil = 0;

            const state = describe(inst);
            if (state !== inst.lastChange) {
                log(`instance #${inst.index} (:${inst.httpPort}) -> ${state}`);
                inst.lastChange = state;
            }
        })
    );
}

function pickFree() {
    return instances.find((i) => describe(i) === 'free');
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
function redirectHost(req) {
    if (cfg.publicIp) return cfg.publicIp;
    const h = (req.headers.host || '127.0.0.1').replace(/:\d+$/, '');
    return h;
}

function waitingPage(res) {
    const rows = instances
        .map((i) => `<tr><td>#${i.index}</td><td>${i.httpPort}</td><td class="${describe(i).replace(' ', '-')}">${describe(i)}</td></tr>`)
        .join('');
    res.writeHead(503, { 'Content-Type': 'text/html; charset=utf-8', 'Retry-After': '3', 'Cache-Control': 'no-store' });
    res.end(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="3">
<title>Waiting for a free stream</title>
<style>
 body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle at 30% 20%,#1e2a4a,#0b0f1a 70%);color:#e6ebf5;font-family:Segoe UI,Inter,sans-serif}
 .card{padding:32px 40px;border-radius:16px;background:rgba(255,255,255,.06);backdrop-filter:blur(8px);box-shadow:0 10px 40px rgba(0,0,0,.4);text-align:center}
 h1{font-size:20px;margin:0 0 8px} p{color:#9aa7c2;margin:0 0 20px}
 .dot{display:inline-block;width:10px;height:10px;border-radius:50%;background:#5b8cff;margin:0 4px;animation:b 1.2s infinite}
 .dot:nth-child(2){animation-delay:.2s}.dot:nth-child(3){animation-delay:.4s}
 @keyframes b{0%,80%,100%{opacity:.2;transform:scale(.8)}40%{opacity:1;transform:scale(1.2)}}
 table{margin:20px auto 0;border-collapse:collapse;font-size:13px} td{padding:4px 12px;border-bottom:1px solid rgba(255,255,255,.08)}
 .free{color:#4ade80}.in-use,.reserved{color:#fbbf24}.offline,.no-UE{color:#f87171}
</style></head><body><main class="card"><h1>All streams are busy</h1><p>You'll be connected automatically when one is free.</p>
<div><span class="dot"></span><span class="dot"></span><span class="dot"></span></div>
<table>${rows}</table></main></body></html>`);
}

const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');

    if (url.pathname === '/api/status') {
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end(JSON.stringify(instances.map((i) => ({ ...i, state: describe(i) })), null, 2));
        return;
    }

    if (url.pathname === '/' || url.pathname === '/signallingserver') {
        const inst = pickFree();
        if (!inst) {
            log(`${req.socket.remoteAddress} ${url.pathname}: no free instance`);
            if (url.pathname === '/signallingserver') {
                res.writeHead(503, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'No free instance' }));
            } else {
                waitingPage(res);
            }
            return;
        }

        inst.reservedUntil = Date.now() + reserveMs;
        const target = `${redirectHost(req)}:${inst.httpPort}`;
        log(`${req.socket.remoteAddress} -> instance #${inst.index} (${target})`);

        if (url.pathname === '/signallingserver') {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ signallingServer: target }));
        } else {
            // Keep the query string so frontend flags (e.g. ?AutoPlayVideo=true) still work.
            res.writeHead(302, { Location: `http://${target}/${url.search}`, 'Cache-Control': 'no-store' });
            res.end();
        }
        return;
    }

    res.writeHead(404);
    res.end();
});

server.listen(cfg.httpPort, cfg.listenIp || undefined, () => {
    log(`Matchmaker listening on ${cfg.listenIp || '0.0.0.0'}:${cfg.httpPort}, ${instances.length} instance(s)`);
});

pollOnce();
setInterval(pollOnce, pollIntervalMs);

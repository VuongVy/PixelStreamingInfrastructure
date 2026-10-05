// Preload for Wilbur (UE5.5+ SignallingWebServer): node -r ./bind-host.js dist/index.js ...
//
// Wilbur has no option for the listen address, so every server (HTTP, player / streamer / SFU
// WebSockets) binds to all interfaces. When PS_LISTEN_HOST is set (e.g. 127.0.0.1 in local mode),
// this patch injects that host into every listen() call that only specified a port.
// Epic's code stays untouched, so the Infra-UE5.7 folder can be upgraded by simply replacing it.
'use strict';

const net = require('net');

const host = process.env.PS_LISTEN_HOST;
if (host) {
    const originalListen = net.Server.prototype.listen;

    net.Server.prototype.listen = function (...args) {
        const first = args[0];
        const isPort = typeof first === 'number' || (typeof first === 'string' && /^\d+$/.test(first));

        if (isPort && typeof args[1] !== 'string') {
            // listen(port[, backlog][, callback]) -> listen(port, host[, backlog][, callback])
            args.splice(1, 0, host);
        } else if (first && typeof first === 'object' && first.port !== undefined && !first.host && !first.path) {
            // listen({ port }) -> listen({ port, host })
            args[0] = { ...first, host };
        }
        return originalListen.apply(this, args);
    };

    console.log(`[bind-host] all servers bind to ${host}`);
}

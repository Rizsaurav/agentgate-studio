import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { authorized } from './access.mjs';
// The token arrives through IPC, never arguments, files, or logs.
process.once('message', async (message) => {
  if (
    !message ||
    message.type !== 'start' ||
    typeof message.directory !== 'string' ||
    typeof message.token !== 'string' ||
    !/^[a-f0-9]{64}$/.test(message.token)
  )
    process.exit(1);
  const { directory, token } = message;
  try {
    const require = createRequire(join(directory, 'package.json'));
    const next = require('next');
    const { config } = JSON.parse(
      await readFile(
        join(directory, '.next', 'required-server-files.json'),
        'utf8',
      ),
    );
    process.env.__NEXT_PRIVATE_STANDALONE_CONFIG = JSON.stringify(config);
    const application = next({
      dev: false,
      dir: directory,
      conf: config,
      hostname: '127.0.0.1',
    });
    await application.prepare();
    const handler = application.getRequestHandler();
    const server = createServer((req, res) => {
      if (!authorized(token, req.headers['x-agentgate-desktop'])) {
        res.writeHead(403, {
          'content-type': 'text/plain',
          'cache-control': 'no-store',
        });
        res.end('Forbidden');
        return;
      }
      delete req.headers['x-agentgate-desktop'];
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.setHeader('Referrer-Policy', 'no-referrer');
      res.setHeader('X-Frame-Options', 'DENY');
      res.setHeader(
        'Content-Security-Policy',
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
      );
      if (req.url === '/__desktop_health') {
        res.writeHead(204);
        res.end();
        return;
      }
      void handler(req, res).catch(() => {
        if (!res.headersSent) res.writeHead(500);
        res.end('The workspace request failed.');
      });
    });
    server.requestTimeout = 130_000;
    server.headersTimeout = 15_000;
    server.on('upgrade', (_req, socket) => socket.destroy());
    server.on('error', () => {
      process.send?.({ type: 'failed' });
      process.exit(1);
    });
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (!address || typeof address === 'string') process.exit(1);
      process.send?.({ type: 'ready', port: address.port });
    });
    let closing = false;
    const close = () => {
      if (closing) return;
      closing = true;
      server.closeAllConnections();
      server.close();
      setTimeout(() => process.exit(0), 4000).unref();
      void application.close().then(
        () => process.exit(0),
        () => process.exit(1),
      );
    };
    process.once('SIGTERM', close);
    process.once('SIGINT', close);
    process.once('disconnect', close);
  } catch {
    process.send?.({ type: 'failed' });
    process.exit(1);
  }
});
setTimeout(() => {
  if (!process.connected) process.exit(1);
}, 15_000).unref();

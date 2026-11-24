import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fork } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// Run explicitly after prepare:app: real production sidecar, no simulated server.
test(
  'packaged server denies unauthenticated access, serves the app, and exits with its parent',
  { skip: process.env.AGENTGATE_DESKTOP_SMOKE !== '1', timeout: 45000 },
  async () => {
    const stage = resolve('stage');
    const data = await mkdtemp(join(tmpdir(), 'agentgate-desktop-'));
    const child = fork(join(stage, 'server.mjs'), [], {
      execPath: join(stage, 'runtime', 'node'),
      execArgv: [],
      cwd: data,
      env: {
        ...process.env,
        NODE_ENV: 'production',
        NEXT_TELEMETRY_DISABLED: '1',
        AGENTGATE_DATA_DIR: data,
      },
      stdio: ['ignore', 'pipe', 'pipe', 'ipc'],
    });
    const token = randomBytes(32).toString('hex');
    try {
      const port = await new Promise((accept, reject) => {
        const timer = setTimeout(
          () => reject(new Error('Server readiness deadline exceeded')),
          25000,
        );
        child.once('error', reject);
        child.once('exit', (code) => {
          clearTimeout(timer);
          reject(new Error(`Server exited before ready (${code})`));
        });
        child.on('message', (message) => {
          clearTimeout(timer);
          if (message.type === 'ready') accept(message.port);
          else reject(new Error('Server reported startup failure'));
        });
        child.send({
          type: 'start',
          token,
          directory: join(stage, 'web', 'apps', 'web'),
        });
      });
      const origin = `http://127.0.0.1:${port}`;
      assert.equal((await fetch(origin)).status, 403);
      assert.equal(
        (
          await fetch(origin, {
            headers: { 'x-agentgate-desktop': 'incorrect' },
          })
        ).status,
        403,
      );
      const response = await fetch(origin, {
        headers: { 'x-agentgate-desktop': token },
      });
      assert.equal(response.status, 200);
      const html = await response.text();
      assert.ok(html.includes('AGENTGATE'));
      assert.ok(html.includes('New project'));
      assert.ok(!html.includes(token));
      const exited = new Promise((resolve) => child.once('exit', resolve));
      child.disconnect();
      await Promise.race([
        exited,
        new Promise((_, reject) => {
          setTimeout(() => reject(new Error('Orphaned server')), 7000).unref();
        }),
      ]);
    } finally {
      child.kill('SIGTERM');
      await rm(data, { recursive: true, force: true });
    }
  },
);

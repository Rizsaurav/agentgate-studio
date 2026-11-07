import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { platform, tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { installOllama, verifyOllamaApp } from './ollama-install';

describe.runIf(platform() === 'darwin')('installing Ollama', () => {
  it('refuses a download that is not signed by Ollama', async () => {
    const work = mkdtempSync(join(tmpdir(), 'agentgate-fake-ollama-'));
    const app = join(work, 'Ollama.app', 'Contents', 'Resources');
    mkdirSync(app, { recursive: true });
    writeFileSync(join(app, 'ollama'), '#!/bin/sh\necho pwned\n', {
      mode: 0o755,
    });
    const zip = join(work, 'Ollama.zip');
    execFileSync('ditto', [
      '-c',
      '-k',
      '--keepParent',
      join(work, 'Ollama.app'),
      zip,
    ]);
    const body = readFileSync(zip);
    const server = createServer((_q, r) => r.end(body));
    await new Promise<void>((resolve) =>
      server.listen(0, '127.0.0.1', resolve),
    );
    const address = server.address();
    const url = `http://127.0.0.1:${typeof address === 'object' && address ? address.port : 0}/Ollama.zip`;
    const messages: string[] = [];
    try {
      await expect(
        installOllama(
          (m) => messages.push(m),
          new AbortController().signal,
          url,
        ),
      ).rejects.toThrow('failed its signature check');
      expect(messages).toContain('Checking the Ollama signature…');
    } finally {
      server.close();
    }
  });

  // Point AGENTGATE_OLLAMA_APP at a downloaded Ollama.app to check the real signature.
  const real = process.env.AGENTGATE_OLLAMA_APP;
  it.runIf(real)('accepts only the expected developer team', async () => {
    if (!real) return;
    await expect(verifyOllamaApp(real)).resolves.toBeUndefined();
    await expect(verifyOllamaApp(real, 'AAAAAAAAAA')).rejects.toThrow(
      'different developer',
    );
  });
});

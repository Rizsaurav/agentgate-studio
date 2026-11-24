import { createServer } from 'node:http';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { startOllama, startScanner } from './service-control';

async function serve(path: string) {
  const server = createServer((request, response) => {
    response.statusCode = request.url === path ? 200 : 404;
    response.end('{}');
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const url = `http://127.0.0.1:${typeof address === 'object' && address ? address.port : 0}`;
  return { url, close: () => server.close() };
}

describe('starting services', () => {
  it('does nothing when the service already answers', async () => {
    const ollama = await serve('/api/version');
    const scanner = await serve('/health');
    try {
      expect(await startOllama(ollama.url, 'definitely-not-installed')).toBe(
        'Ollama is already running.',
      );
      expect(await startScanner({ root: tmpdir(), url: scanner.url })).toBe(
        'The scanner is already running.',
      );
    } finally {
      ollama.close();
      scanner.close();
    }
  });
  it('explains what to do when the software is not installed', async () => {
    await expect(
      startOllama('http://127.0.0.1:9', 'definitely-not-installed'),
    ).rejects.toThrow('npm run setup');
    await expect(
      startScanner({
        root: mkdtempSync(join(tmpdir(), 'agentgate-noscanner-')),
        url: 'http://127.0.0.1:9',
      }),
    ).rejects.toThrow('npm run setup');
  });
});

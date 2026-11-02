import { createServer, type Server } from 'node:http';
import { tmpdir } from 'node:os';
import { afterEach, describe, expect, it } from 'vitest';
import {
  ModelPuller,
  OllamaCatalog,
  inspectSystem,
  modelNameSchema,
} from './index';

const GIB = 1024 ** 3;
const servers: Server[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});
async function fakeOllama(handler: Parameters<typeof createServer>[1]) {
  const server = createServer(handler);
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  return `http://127.0.0.1:${typeof address === 'object' && address ? address.port : 0}`;
}

describe('system profile', () => {
  it('reads real values from the operating system', async () => {
    const profile = await inspectSystem(tmpdir());
    expect(profile.memoryBytes).toBeGreaterThan(0);
    expect(profile.freeDiskBytes).toBeGreaterThan(0);
    expect(profile.cores).toBeGreaterThan(0);
    expect(profile.chip.length).toBeGreaterThan(0);
  });
});

describe('model names', () => {
  it.each([
    'qwen2.5:3b',
    'llama3.2',
    'library/qwen2.5:7b-instruct-q4_K_M',
    'smollm2:135m',
    'hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M',
    'hf.co/unsloth/Qwen3-8B-GGUF',
  ])('accepts %s', (name) => {
    expect(modelNameSchema.safeParse(name).success).toBe(true);
  });
  it.each([
    '',
    ' ',
    '../etc/passwd',
    'hf.co/../../etc/passwd',
    'hf.co/owner',
    'evil.com/owner/repo:Q4_K_M',
    'a b',
    'qwen;rm -rf /',
    'http://evil.example/x',
    'a'.repeat(101),
    '-flag',
    'UPPER space',
  ])('rejects %j', (name) => {
    expect(modelNameSchema.safeParse(name).success).toBe(false);
  });
});

describe('model downloads', () => {
  const ndjson = (lines: object[]) =>
    lines.map((l) => JSON.stringify(l)).join('\n') + '\n';

  it('aggregates progress across layers and finishes', async () => {
    const baseUrl = await fakeOllama((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        expect(JSON.parse(body)).toEqual({ model: 'tiny:1b', stream: true });
        res.end(
          ndjson([
            { status: 'pulling manifest' },
            {
              status: 'pulling a',
              digest: 'sha256:a',
              total: 100,
              completed: 40,
            },
            {
              status: 'pulling b',
              digest: 'sha256:b',
              total: 300,
              completed: 300,
            },
            {
              status: 'pulling a',
              digest: 'sha256:a',
              total: 100,
              completed: 100,
            },
            { status: 'success' },
          ]),
        );
      });
    });
    const puller = new ModelPuller(baseUrl);
    puller.start('tiny:1b');
    await puller.idle();
    expect(puller.state()).toMatchObject({
      model: 'tiny:1b',
      status: 'done',
      completedBytes: 400,
      totalBytes: 400,
    });
  });

  it('reports Ollama errors, malformed data, and an unreachable server without throwing', async () => {
    const error = await fakeOllama((_q, r) =>
      r.end(ndjson([{ error: 'pull model manifest: file does not exist' }])),
    );
    const bad = await fakeOllama((_q, r) => r.end('{not json\n'));
    for (const [url, expected] of [
      [error, 'file does not exist'],
      [bad, 'unexpected response'],
      ['http://127.0.0.1:1', 'not reachable'],
    ] as const) {
      const puller = new ModelPuller(url);
      puller.start('x:1b');
      await puller.idle();
      expect(puller.state()?.status).toBe('failed');
      expect(puller.state()?.message).toContain(expected);
    }
  });

  it('allows one download at a time, rejects bad names, and can be cancelled', async () => {
    const baseUrl = await fakeOllama((_q, r) => {
      r.write(
        ndjson([
          {
            status: 'pulling a',
            digest: 'sha256:a',
            total: 1000,
            completed: 1,
          },
        ]),
      );
    });
    const puller = new ModelPuller(baseUrl);
    expect(() => puller.start('bad name!')).toThrow();
    puller.start('slow:1b');
    expect(() => puller.start('other:1b')).toThrow('already downloading');
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(puller.state()?.completedBytes).toBe(1);
    puller.cancel();
    await puller.idle();
    expect(puller.state()).toMatchObject({
      status: 'cancelled',
      message: 'Cancelled.',
    });
    puller.start('next:1b');
    puller.cancel();
    await puller.idle();
  });
});

// Real download through a real Ollama (about 90 MB), removed afterwards.
const ollamaUrl = process.env.AGENTGATE_OLLAMA_URL;
describe.runIf(ollamaUrl)('live Ollama download (integration)', () => {
  it('pulls a small model, lists it with its size, and rejects a model that does not exist', async () => {
    const model = 'smollm2:135m';
    const puller = new ModelPuller(ollamaUrl);
    const catalog = new OllamaCatalog(ollamaUrl);
    try {
      puller.start(model);
      await puller.idle();
      expect(puller.state()).toMatchObject({ status: 'done' });
      expect(puller.state()?.totalBytes).toBeGreaterThan(50_000_000);
      const installed = await catalog.listDetailed();
      expect(
        installed.find((m) => m.name === model)?.sizeBytes,
      ).toBeGreaterThan(50_000_000);
      puller.start('definitely-not-a-model-xyz');
      await puller.idle();
      expect(puller.state()).toMatchObject({ status: 'failed' });
      expect(puller.state()?.message).toContain('does not exist');
    } finally {
      await fetch(`${ollamaUrl}/api/delete`, {
        method: 'DELETE',
        body: JSON.stringify({ model }),
      });
    }
  }, 300_000);
});

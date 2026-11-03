import { createServer, type Server } from 'node:http';
import { afterEach, describe, expect, it } from 'vitest';
import {
  CUSTOM_PROVIDER,
  CustomEndpoint,
  SecretCredentialStore,
  SqliteSettings,
  openDatabase,
} from './index';
import { MemoryBackend } from './test-support';

const closers: (() => void)[] = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
});

/** A minimal OpenAI-compatible chat server that streams one reply and records what it was sent. */
async function fakeServer(options: { fail?: boolean } = {}) {
  const seen: { auth: string | undefined; model: string }[] = [];
  const server: Server = createServer((request, response) => {
    let body = '';
    request.on('data', (chunk) => (body += chunk));
    request.on('end', () => {
      const { model } = JSON.parse(body) as { model: string };
      seen.push({ auth: request.headers.authorization, model });
      if (options.fail) {
        response.writeHead(401, { 'content-type': 'application/json' });
        response.end(
          '{"error":{"message":"Invalid API key sk-should-not-leak"}}',
        );
        return;
      }
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      const chunk = (delta: object, finish: string | null) =>
        `data: ${JSON.stringify({
          id: 'c1',
          object: 'chat.completion.chunk',
          created: 1,
          model,
          choices: [{ index: 0, delta, finish_reason: finish }],
        })}\n\n`;
      response.write(chunk({ role: 'assistant', content: 'ok' }, null));
      response.write(chunk({}, 'stop'));
      response.end('data: [DONE]\n\n');
    });
  });
  await new Promise<void>((done) => server.listen(0, '127.0.0.1', done));
  closers.push(() => {
    server.closeAllConnections();
    server.close();
  });
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  return { url: `http://127.0.0.1:${port}/v1`, seen };
}

function setup() {
  const db = openDatabase(':memory:');
  closers.push(() => db.close());
  const backend = new MemoryBackend();
  const endpoint = new CustomEndpoint(
    new SqliteSettings(db),
    new SecretCredentialStore(backend, [CUSTOM_PROVIDER]),
  );
  return { endpoint, backend };
}

describe('custom OpenAI-compatible endpoint', () => {
  it('verifies, saves, reports without the key, and answers', async () => {
    const server = await fakeServer();
    const { endpoint, backend } = setup();
    await endpoint.connect({
      name: 'Gateway',
      baseUrl: `${server.url}/`,
      models: 'team/model-a, team/model-b',
      apiKey: 'gw-key-123456789',
    });
    expect(server.seen[0]).toEqual({
      auth: 'Bearer gw-key-123456789',
      model: 'team/model-a',
    });
    const status = await endpoint.status();
    expect(status).toEqual({
      configured: true,
      name: 'Gateway',
      baseUrl: server.url,
      models: ['team/model-a', 'team/model-b'],
      hasKey: true,
    });
    expect(JSON.stringify(status)).not.toContain('gw-key');
    expect(backend.values.get(CUSTOM_PROVIDER)).toContain('gw-key-123456789');

    const opened = await endpoint.open({
      provider: 'custom',
      modelId: 'team/model-b',
    });
    expect(opened.model.id).toBe('team/model-b');
    await expect(
      endpoint.open({ provider: 'custom', modelId: 'other' }),
    ).rejects.toThrow('not set up');

    await endpoint.disconnect();
    expect(await endpoint.status()).toEqual({ configured: false });
    expect(backend.values.size).toBe(0);
  });

  it('works without a key for a local server', async () => {
    const server = await fakeServer();
    const { endpoint } = setup();
    await endpoint.connect({
      name: 'LM Studio',
      baseUrl: server.url,
      models: 'local-model',
      apiKey: '',
    });
    expect(server.seen[0]?.auth).toBe('Bearer none');
    expect(await endpoint.status()).toMatchObject({ hasKey: false });
  });

  it('saves nothing when the server rejects the key, and never echoes it', async () => {
    const server = await fakeServer({ fail: true });
    const { endpoint, backend } = setup();
    const error = await endpoint
      .connect({
        name: 'Gateway',
        baseUrl: server.url,
        models: 'm',
        apiKey: 'sk-should-not-leak',
      })
      .catch((e: Error) => e);
    expect((error as Error).message).toBe('The provider rejected the API key.');
    expect(await endpoint.status()).toEqual({ configured: false });
    expect(backend.values.size).toBe(0);
  });

  it.each([
    ['http://gateway.example.com/v1', 'Use https://'],
    ['https://user:pass@gateway.example.com/v1', 'credentials'],
    ['https://gateway.example.com/v1?token=x', 'credentials'],
    ['ftp://gateway.example.com', 'https://'],
    ['not a url', 'full URL'],
  ])('refuses the unsafe URL %s', async (baseUrl, message) => {
    const { endpoint } = setup();
    await expect(
      endpoint.connect({ name: 'x', baseUrl, models: 'm', apiKey: '' }),
    ).rejects.toThrow(message);
  });
});

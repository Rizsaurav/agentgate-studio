import { randomUUID } from 'node:crypto';
import { afterEach, describe, expect, it } from 'vitest';
import {
  EnvironmentBackend,
  CloudCatalog,
  KeychainBackend,
  SecretCredentialStore,
  apiKeySchema,
  describeProviderError,
  type SecretBackend,
} from './index';

class MemoryBackend implements SecretBackend {
  readonly values = new Map<string, string>();
  async get(account: string) {
    return this.values.get(account) ?? null;
  }
  async set(account: string, secret: string) {
    this.values.set(account, secret);
  }
  async delete(account: string) {
    this.values.delete(account);
  }
}
const PROVIDERS = ['anthropic', 'openai'];

describe('SecretCredentialStore', () => {
  it('stores, lists without secrets, and deletes keys', async () => {
    const store = new SecretCredentialStore(new MemoryBackend(), PROVIDERS);
    expect(await store.read('anthropic')).toBeUndefined();
    await store.modify('anthropic', async () => ({
      type: 'api_key',
      key: 'sk-test-123456',
    }));
    expect(await store.read('anthropic')).toEqual({
      type: 'api_key',
      key: 'sk-test-123456',
    });
    expect(await store.list()).toEqual([
      { providerId: 'anthropic', type: 'api_key' },
    ]);
    await store.delete('anthropic');
    expect(await store.list()).toEqual([]);
  });

  it('serializes concurrent writes per provider', async () => {
    const store = new SecretCredentialStore(new MemoryBackend(), PROVIDERS);
    await Promise.all(
      [1, 2, 3].map((n) =>
        store.modify('openai', async (current) => ({
          type: 'api_key',
          key: `${(current?.type === 'api_key' ? current.key : '') ?? ''}${n}`,
        })),
      ),
    );
    expect(await store.read('openai')).toEqual({ type: 'api_key', key: '123' });
  });

  it('rejects unknown providers, unsupported credentials, and corrupt entries', async () => {
    const backend = new MemoryBackend();
    const store = new SecretCredentialStore(backend, PROVIDERS);
    await expect(store.read('../etc')).rejects.toThrow('Unsupported provider');
    await expect(
      store.modify('openai', async () => ({
        type: 'oauth',
        refresh: 'r',
        access: 'a',
        expires: 1,
      })),
    ).rejects.toThrow();
    backend.values.set('openai', 'not json');
    await expect(store.read('openai')).rejects.toThrow('unreadable');
  });

  it.runIf(process.platform === 'darwin')(
    'round-trips through the real operating system keychain',
    async () => {
      const service = `agentgate-test-${randomUUID()}`;
      const store = new SecretCredentialStore(
        new KeychainBackend(service),
        PROVIDERS,
      );
      cleanup.push(() => store.delete('openai'));
      await store.modify('openai', async () => ({
        type: 'api_key',
        key: 'sk-keychain-123456',
      }));
      expect(await store.read('openai')).toEqual({
        type: 'api_key',
        key: 'sk-keychain-123456',
      });
      await store.delete('openai');
      expect(await store.read('openai')).toBeUndefined();
    },
  );
});
const cleanup: (() => Promise<void>)[] = [];
afterEach(async () => {
  for (const task of cleanup.splice(0)) await task().catch(() => undefined);
});

describe('provider errors and key validation', () => {
  it.each([
    [
      '401 Incorrect API key provided: sk-abc***xyz',
      'The provider rejected the API key.',
    ],
    [
      '429 rate limit exceeded',
      'The provider rate limit or quota was reached.',
    ],
    ['fetch failed ECONNREFUSED', 'The provider could not be reached.'],
    ['something sk-secret-value odd', 'The provider request failed.'],
  ])('maps %s to fixed text without echoing the input', (raw, expected) => {
    const text = describeProviderError(raw);
    expect(text).toBe(expected);
    expect(text).not.toContain('sk-');
  });

  it.each([
    '',
    'short',
    'has space in it 123',
    'a'.repeat(513),
    'ключ-ключ-ключ',
  ])('rejects invalid key %j', (key) => {
    expect(apiKeySchema.safeParse(key).success).toBe(false);
  });
});

describe('CloudCatalog', () => {
  const catalog = () =>
    new CloudCatalog(new SecretCredentialStore(new MemoryBackend(), PROVIDERS));

  it('lists Pi built-in models and reports missing keys', async () => {
    const status = await catalog().status();
    expect(status.map((entry) => entry.provider)).toEqual([
      'anthropic',
      'openai',
    ]);
    for (const entry of status) expect(entry.models.length).toBeGreaterThan(0);
  });

  it('refuses unsupported providers, unknown models, and keyless use', async () => {
    const cloud = catalog();
    await expect(cloud.connect('ollama', 'sk-valid-key-123')).rejects.toThrow();
    await expect(cloud.connect('openai', 'bad key')).rejects.toThrow();
    const configured = (await cloud.status()).find((e) => e.configured);
    if (!configured)
      await expect(
        cloud.open({ provider: 'openai', modelId: 'any' }),
      ).rejects.toThrow('No API key is saved');
  });
});

// Needs network access but no paid key: a deliberately invalid key must be rejected and not saved.
describe.runIf(process.env.AGENTGATE_LIVE_CLOUD === '1')(
  'live provider key check (integration)',
  () => {
    it.each(['anthropic', 'openai'])(
      'rejects an invalid %s key with a sanitized message and saves nothing',
      async (provider) => {
        const backend = new MemoryBackend();
        const cloud = new CloudCatalog(
          new SecretCredentialStore(backend, PROVIDERS),
        );
        const bogus = 'sk-invalid-0000000000000000';
        const error = await cloud
          .connect(provider, bogus)
          .catch((e: Error) => e);
        expect(error).toBeInstanceOf(Error);
        expect((error as Error).message).toBe(
          'The provider rejected the API key.',
        );
        expect((error as Error).message).not.toContain(bogus);
        expect(backend.values.size).toBe(0);
      },
      60_000,
    );
  },
);

describe('environment credentials (containers)', () => {
  it('reads keys from the environment, treats blanks as unset, and refuses to save', async () => {
    const backend = new EnvironmentBackend({
      OPENROUTER_API_KEY: ' sk-or-test ',
      OPENAI_API_KEY: '  ',
    });
    expect(JSON.parse((await backend.get('openrouter')) ?? '{}')).toEqual({
      type: 'api_key',
      key: 'sk-or-test',
    });
    expect(await backend.get('openai')).toBeNull();
    expect(await backend.get('anthropic')).toBeNull();
    expect(await backend.get('unknown')).toBeNull();
    await expect(backend.set()).rejects.toThrow('environment variables');
    await expect(backend.delete()).rejects.toThrow('environment variables');
  });
});

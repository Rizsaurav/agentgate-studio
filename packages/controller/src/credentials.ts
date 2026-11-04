import { readFileSync } from 'node:fs';
import { AsyncEntry } from '@napi-rs/keyring';
import type {
  AuthOperationOptions,
  Credential,
  CredentialInfo,
  CredentialStore,
} from '@earendil-works/pi-ai';
import { z } from 'zod';

export const KEYCHAIN_SERVICE = 'agentgate-studio';

/** Minimal secret storage; production uses the operating system's credential store. */
export interface SecretBackend {
  get(account: string): Promise<string | null>;
  set(account: string, secret: string): Promise<void>;
  delete(account: string): Promise<void>;
}

export class KeychainBackend implements SecretBackend {
  constructor(private readonly service: string = KEYCHAIN_SERVICE) {}
  get(account: string): Promise<string | null> {
    return new AsyncEntry(this.service, account).getPassword();
  }
  async set(account: string, secret: string): Promise<void> {
    await new AsyncEntry(this.service, account).setPassword(secret);
  }
  async delete(account: string): Promise<void> {
    await new AsyncEntry(this.service, account).deletePassword();
  }
}

const ENVIRONMENT_KEYS: Record<string, string> = {
  anthropic: 'ANTHROPIC_API_KEY',
  openai: 'OPENAI_API_KEY',
  openrouter: 'OPENROUTER_API_KEY',
  google: 'GEMINI_API_KEY',
  groq: 'GROQ_API_KEY',
  deepseek: 'DEEPSEEK_API_KEY',
  mistral: 'MISTRAL_API_KEY',
  xai: 'XAI_API_KEY',
  custom: 'AGENTGATE_CUSTOM_API_KEY',
};

/**
 * Read-only keys from environment variables, for containers, which have no operating system
 * credential store. Keys are set when the container starts, never saved by the app.
 * `NAME_FILE` (a path, as Docker secrets mount them) is read when `NAME` itself is empty,
 * so a key need not sit in `.env` or in the container's environment.
 */
export class EnvironmentBackend implements SecretBackend {
  constructor(
    private readonly env: Record<string, string | undefined> = process.env,
  ) {}
  async get(account: string): Promise<string | null> {
    const name = ENVIRONMENT_KEYS[account];
    if (!name) return null;
    const value = this.env[name]?.trim() || this.fromFile(name);
    return value ? JSON.stringify({ type: 'api_key', key: value }) : null;
  }

  private fromFile(name: string): string | undefined {
    const path = this.env[`${name}_FILE`]?.trim();
    if (!path) return undefined;
    try {
      return readFileSync(path, 'utf8').trim() || undefined;
    } catch (error) {
      // A configured key that cannot be read is an error, not a missing key. The file's
      // content is never part of the message.
      throw new Error(
        `${name}_FILE is set but the file cannot be read (${error instanceof Error && 'code' in error ? String(error.code) : 'unknown error'}).`,
      );
    }
  }
  async set(): Promise<void> {
    throw new Error(
      'Keys are set with environment variables in this setup. See .env.example.',
    );
  }
  async delete(): Promise<void> {
    throw new Error(
      'Keys are set with environment variables in this setup. See .env.example.',
    );
  }
}

const storedKeySchema = z
  .object({ type: z.literal('api_key'), key: z.string().min(1) })
  .strict();

/**
 * Pi's CredentialStore backed by a secret store. Only API keys are supported,
 * the provider ids are a fixed allow-list (secret stores cannot be enumerated),
 * and nothing is written to disk by the application.
 */
export class SecretCredentialStore implements CredentialStore {
  private chains = new Map<string, Promise<unknown>>();

  constructor(
    private readonly backend: SecretBackend,
    private readonly providerIds: readonly string[],
  ) {}

  async read(
    providerId: string,
    _options?: AuthOperationOptions,
  ): Promise<Credential | undefined> {
    this.assertKnown(providerId);
    const raw = await this.backend.get(providerId);
    if (raw === null) return undefined;
    const parsed = storedKeySchema.safeParse(safeJson(raw));
    if (!parsed.success)
      throw new Error(`The stored credential for ${providerId} is unreadable.`);
    return parsed.data;
  }

  async list(
    _options?: AuthOperationOptions,
  ): Promise<readonly CredentialInfo[]> {
    const present: CredentialInfo[] = [];
    for (const providerId of this.providerIds)
      if ((await this.backend.get(providerId)) !== null)
        present.push({ providerId, type: 'api_key' });
    return present;
  }

  modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>,
    _options?: AuthOperationOptions,
  ): Promise<Credential | undefined> {
    return this.serialize(providerId, async () => {
      const current = await this.read(providerId);
      const next = await fn(current);
      if (next === undefined) return current;
      const parsed = storedKeySchema.parse(next);
      await this.backend.set(providerId, JSON.stringify(parsed));
      return parsed;
    });
  }

  delete(providerId: string, _options?: AuthOperationOptions): Promise<void> {
    this.assertKnown(providerId);
    return this.serialize(providerId, () => this.backend.delete(providerId));
  }

  private assertKnown(providerId: string): void {
    if (!this.providerIds.includes(providerId))
      throw new Error(`Unsupported provider ${providerId}.`);
  }

  private serialize<T>(providerId: string, task: () => Promise<T>): Promise<T> {
    this.assertKnown(providerId);
    const previous = this.chains.get(providerId) ?? Promise.resolve();
    const run = previous.then(task, task);
    this.chains.set(
      providerId,
      run.catch(() => undefined),
    );
    return run;
  }
}

function safeJson(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

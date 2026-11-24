import type { CredentialStore } from '@earendil-works/pi-ai';
import { z } from 'zod';
import { apiKeySchema, describeProviderError } from './cloud';
import type { OpenedModel } from './ollama';
import { openAICompatibleRegistry } from './openai-compatible';
import type { ModelRef } from './sessions';
import type { SqliteSettings } from './settings';

export const CUSTOM_PROVIDER = 'custom';
const SETTINGS_KEY = 'custom-endpoint';
const VERIFY_TIMEOUT_MS = 20_000;
/** Plain http is accepted only where a key cannot cross a network. */
const LOCAL_HOSTS = new Set([
  'localhost',
  '127.0.0.1',
  '[::1]',
  'host.docker.internal',
]);

const modelIdSchema = z
  .string()
  .trim()
  .regex(/^[\w.:/@+-]{1,200}$/, 'Model ids have no spaces.');

export const endpointUrlSchema = z
  .string()
  .trim()
  .max(300)
  .transform((value, ctx) => {
    let url: URL;
    try {
      url = new URL(value);
    } catch {
      ctx.addIssue({ code: 'custom', message: 'Enter a full URL.' });
      return z.NEVER;
    }
    const problem =
      url.protocol !== 'https:' && url.protocol !== 'http:'
        ? 'The URL must start with https://.'
        : url.protocol === 'http:' && !LOCAL_HOSTS.has(url.hostname)
          ? 'Use https:// for a server on another computer, so the key is encrypted.'
          : url.username || url.password || url.search || url.hash
            ? 'Leave credentials and query strings out of the URL.'
            : null;
    if (problem) {
      ctx.addIssue({ code: 'custom', message: problem });
      return z.NEVER;
    }
    return `${url.origin}${url.pathname.replace(/\/+$/, '')}`;
  });

const savedSchema = z
  .object({
    name: z.string().min(1).max(40),
    baseUrl: z.string(),
    models: z.array(modelIdSchema).min(1).max(10),
  })
  .strict();
type Saved = z.infer<typeof savedSchema>;

export const customEndpointSchema = z
  .object({
    name: z.string().trim().min(1, 'Name the endpoint.').max(40),
    baseUrl: endpointUrlSchema,
    models: z
      .string()
      .transform((value) =>
        value
          .split(/[\s,]+/)
          .map((id) => id.trim())
          .filter(Boolean),
      )
      .pipe(
        z
          .array(modelIdSchema)
          .min(1, 'Enter at least one model id.')
          .max(10, 'Enter at most 10 model ids.'),
      ),
    apiKey: z
      .string()
      .trim()
      .transform((value) => value || null)
      .pipe(apiKeySchema.nullable()),
  })
  .strict();

export type CustomEndpointStatus =
  | { configured: false }
  | {
      configured: true;
      name: string;
      baseUrl: string;
      models: string[];
      hasKey: boolean;
    };

/** Any OpenAI-compatible server the user names. The URL and model ids are settings; the key is a secret. */
export class CustomEndpoint {
  constructor(
    private readonly settings: SqliteSettings,
    private readonly credentials: CredentialStore,
  ) {}

  async status(): Promise<CustomEndpointStatus> {
    const saved = this.saved();
    if (!saved) return { configured: false };
    return {
      configured: true,
      ...saved,
      hasKey: (await this.key()) !== null,
    };
  }

  /** Sends one tiny request through the endpoint and saves it only if a model answers. */
  async connect(input: unknown): Promise<void> {
    const { name, baseUrl, models, apiKey } = customEndpointSchema.parse(input);
    const registry = openAICompatibleRegistry({
      id: CUSTOM_PROVIDER,
      name,
      baseUrl,
      modelIds: models,
      apiKey,
    });
    const model = registry.getModel(CUSTOM_PROVIDER, models[0] as string);
    if (!model) throw new Error('The model could not be loaded.');
    const result = await registry.completeSimple(
      model,
      {
        messages: [
          { role: 'user', content: 'Reply with: ok', timestamp: Date.now() },
        ],
      },
      { maxTokens: 16, signal: AbortSignal.timeout(VERIFY_TIMEOUT_MS) },
    );
    if (result.stopReason === 'error' || result.stopReason === 'aborted')
      throw new Error(
        describeProviderError(result.errorMessage ?? 'timed out'),
      );
    if (apiKey)
      await this.credentials.modify(CUSTOM_PROVIDER, async () => ({
        type: 'api_key',
        key: apiKey,
      }));
    else if ((await this.key()) !== null)
      await this.credentials.delete(CUSTOM_PROVIDER);
    this.settings.set(
      SETTINGS_KEY,
      JSON.stringify({ name, baseUrl, models } satisfies Saved),
    );
  }

  async disconnect(): Promise<void> {
    if ((await this.key()) !== null)
      await this.credentials.delete(CUSTOM_PROVIDER);
    this.settings.delete(SETTINGS_KEY);
  }

  async open(ref: ModelRef): Promise<OpenedModel> {
    const saved = this.saved();
    if (!saved) throw new Error('No custom endpoint is set up.');
    if (!saved.models.includes(ref.modelId))
      throw new Error(`Model ${ref.modelId} is not set up on ${saved.name}.`);
    const registry = openAICompatibleRegistry({
      id: CUSTOM_PROVIDER,
      name: saved.name,
      baseUrl: saved.baseUrl,
      modelIds: saved.models,
      apiKey: await this.key(),
    });
    const model = registry.getModel(CUSTOM_PROVIDER, ref.modelId);
    if (!model) throw new Error(`Model ${ref.modelId} could not be loaded.`);
    return {
      model,
      streamFn: (target, context, options) =>
        registry.streamSimple(target, context, options),
      getApiKey: () => undefined,
      describeError: describeProviderError,
    };
  }

  private saved(): Saved | null {
    const raw = this.settings.get(SETTINGS_KEY);
    if (raw === undefined) return null;
    const parsed = savedSchema.safeParse(JSON.parse(raw));
    if (!parsed.success)
      throw new Error('The saved custom endpoint settings are unreadable.');
    return parsed.data;
  }

  private async key(): Promise<string | null> {
    const credential = await this.credentials.read(CUSTOM_PROVIDER);
    return credential?.type === 'api_key' ? (credential.key ?? null) : null;
  }
}

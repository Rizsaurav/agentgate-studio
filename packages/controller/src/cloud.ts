import {
  InMemoryCredentialStore,
  createModels,
  type Api,
  type CredentialStore,
  type Model,
  type MutableModels,
} from '@earendil-works/pi-ai';
import { anthropicProvider } from '@earendil-works/pi-ai/providers/anthropic';
import { deepseekProvider } from '@earendil-works/pi-ai/providers/deepseek';
import { googleProvider } from '@earendil-works/pi-ai/providers/google';
import { groqProvider } from '@earendil-works/pi-ai/providers/groq';
import { mistralProvider } from '@earendil-works/pi-ai/providers/mistral';
import { openaiProvider } from '@earendil-works/pi-ai/providers/openai';
import { openrouterProvider } from '@earendil-works/pi-ai/providers/openrouter';
import { xaiProvider } from '@earendil-works/pi-ai/providers/xai';
import { z } from 'zod';
import type { OpenedModel } from './ollama';
import {
  cloudProviderSchema,
  type CloudProvider,
  type ModelRef,
} from './sessions';

const VERIFY_TIMEOUT_MS = 20_000;

/** Display name and where a user gets a key, for each provider that can be connected. */
export const PROVIDER_INFO: Record<
  CloudProvider,
  { name: string; keyUrl: string }
> = {
  openrouter: {
    name: 'OpenRouter',
    keyUrl: 'https://openrouter.ai/keys',
  },
  anthropic: {
    name: 'Anthropic',
    keyUrl: 'https://console.anthropic.com/settings/keys',
  },
  openai: { name: 'OpenAI', keyUrl: 'https://platform.openai.com/api-keys' },
  google: {
    name: 'Google Gemini',
    keyUrl: 'https://aistudio.google.com/apikey',
  },
  groq: { name: 'Groq', keyUrl: 'https://console.groq.com/keys' },
  deepseek: {
    name: 'DeepSeek',
    keyUrl: 'https://platform.deepseek.com/api_keys',
  },
  mistral: { name: 'Mistral', keyUrl: 'https://console.mistral.ai/api-keys' },
  xai: { name: 'xAI', keyUrl: 'https://console.x.ai' },
};

const PROVIDERS = {
  openrouter: openrouterProvider,
  anthropic: anthropicProvider,
  openai: openaiProvider,
  google: googleProvider,
  groq: groqProvider,
  deepseek: deepseekProvider,
  mistral: mistralProvider,
  xai: xaiProvider,
} satisfies Record<CloudProvider, unknown>;
export const apiKeySchema = z
  .string()
  .trim()
  .min(8, 'Enter the provider API key.')
  .max(512, 'That API key is too long.')
  .regex(/^[\x21-\x7e]+$/, 'An API key has no spaces or special characters.');

/**
 * Provider messages can echo parts of a key, so only a fixed vocabulary is
 * ever stored, logged, or shown.
 */
export function describeProviderError(raw: string): string {
  if (
    /\b(401|403)\b|api[ _-]?key|authenticat|unauthori[sz]ed|permission|invalid.*(key|token)/i.test(
      raw,
    )
  )
    return 'The provider rejected the API key.';
  if (/\b429\b|rate.?limit|quota|insufficient/i.test(raw))
    return 'The provider rate limit or quota was reached.';
  if (/timed? ?out|ENOTFOUND|ECONN|network|fetch failed/i.test(raw))
    return 'The provider could not be reached.';
  return 'The provider request failed.';
}

export type ProviderStatus = {
  provider: CloudProvider;
  configured: boolean;
  source: string | null;
  models: string[];
};

/** Cloud models through Pi's built-in providers; keys live only in the credential store. */
export class CloudCatalog {
  private readonly registry: MutableModels;

  constructor(private readonly credentials: CredentialStore) {
    this.registry = this.buildRegistry(credentials);
  }

  async status(): Promise<ProviderStatus[]> {
    return Promise.all(
      cloudProviderSchema.options.map(async (provider) => {
        const auth = await this.registry.checkAuth(provider);
        return {
          provider,
          configured: auth !== undefined,
          source: auth?.source ?? null,
          models: this.registry.getModels(provider).map((model) => model.id),
        };
      }),
    );
  }

  /** Tests the key with one tiny real request, and saves it only if the provider accepts it. */
  async connect(providerInput: unknown, keyInput: unknown): Promise<void> {
    const provider = cloudProviderSchema.parse(providerInput);
    const key = apiKeySchema.parse(keyInput);
    const probeCredentials = new InMemoryCredentialStore();
    await probeCredentials.modify(provider, async () => ({
      type: 'api_key',
      key,
    }));
    // The probe ignores ambient environment keys so that it tests exactly this key.
    const probe = this.buildRegistry(probeCredentials, true);
    const model = cheapest(probe.getModels(provider));
    const result = await probe.completeSimple(
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
    await this.credentials.modify(provider, async () => ({
      type: 'api_key',
      key,
    }));
  }

  async disconnect(providerInput: unknown): Promise<void> {
    await this.credentials.delete(cloudProviderSchema.parse(providerInput));
  }

  async open(ref: ModelRef): Promise<OpenedModel> {
    const provider = cloudProviderSchema.parse(ref.provider);
    if (!(await this.registry.checkAuth(provider)))
      throw new Error(`No API key is saved for ${provider}.`);
    const model = this.registry.getModel(provider, ref.modelId);
    if (!model)
      throw new Error(`Model ${ref.modelId} is not offered by ${provider}.`);
    return {
      model,
      streamFn: (target, context, options) =>
        this.registry.streamSimple(target, context, options),
      getApiKey: () => undefined,
      describeError: describeProviderError,
    };
  }

  private buildRegistry(
    credentials: CredentialStore,
    isolated = false,
  ): MutableModels {
    const registry = createModels({
      credentials,
      ...(isolated
        ? {
            authContext: {
              env: async () => undefined,
              fileExists: async () => false,
            },
          }
        : {}),
    });
    for (const create of Object.values(PROVIDERS))
      registry.setProvider(create());
    return registry;
  }
}

function cheapest(models: readonly Model<Api>[]): Model<Api> {
  // Free models are often rate limited, which would make a good key look rejected.
  const paid = models.filter((model) => model.cost.output > 0);
  const sorted = [...(paid.length ? paid : models)].sort(
    (a, b) => a.cost.output - b.cost.output,
  );
  const model = sorted[0];
  if (!model) throw new Error('The provider offers no models.');
  return model;
}

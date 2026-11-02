import {
  InMemoryCredentialStore,
  createModels,
  type CredentialStore,
  type MutableModels,
} from '@earendil-works/pi-ai';
import { openrouterProvider } from '@earendil-works/pi-ai/providers/openrouter';
import { apiKeySchema, describeProviderError } from './cloud';
import type { OpenedModel } from './ollama';

export const AGENT_PROVIDER = 'openrouter';
export const DEFAULT_AGENT_MODEL = 'deepseek/deepseek-v4.1-flash';
const VERIFY_TIMEOUT_MS = 20_000;

/** The model behind the assistant, reached through OpenRouter. The key lives only in the credential store. */
export class AgentModel {
  private readonly registry: MutableModels;

  constructor(
    private readonly credentials: CredentialStore,
    readonly modelId: string = DEFAULT_AGENT_MODEL,
  ) {
    this.registry = this.build(credentials);
  }

  async configured(): Promise<boolean> {
    return (await this.registry.checkAuth(AGENT_PROVIDER)) !== undefined;
  }

  /** Tests the key with one tiny request to the assistant's own model, and saves it only if accepted. */
  async connect(keyInput: unknown): Promise<void> {
    const key = apiKeySchema.parse(keyInput);
    const probeCredentials = new InMemoryCredentialStore();
    await probeCredentials.modify(AGENT_PROVIDER, async () => ({
      type: 'api_key',
      key,
    }));
    const probe = this.build(probeCredentials, true);
    const model = this.model(probe);
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
    await this.credentials.modify(AGENT_PROVIDER, async () => ({
      type: 'api_key',
      key,
    }));
  }

  async disconnect(): Promise<void> {
    await this.credentials.delete(AGENT_PROVIDER);
  }

  async open(): Promise<OpenedModel> {
    if (!(await this.configured()))
      throw new Error('Connect an OpenRouter key to turn the assistant on.');
    return {
      model: this.model(this.registry),
      streamFn: (target, context, options) =>
        this.registry.streamSimple(target, context, options),
      getApiKey: () => undefined,
      describeError: describeProviderError,
    };
  }

  private model(registry: MutableModels) {
    const model = registry.getModel(AGENT_PROVIDER, this.modelId);
    if (!model)
      throw new Error(`OpenRouter does not offer the model ${this.modelId}.`);
    return model;
  }

  private build(credentials: CredentialStore, isolated = false): MutableModels {
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
    registry.setProvider(openrouterProvider());
    return registry;
  }
}

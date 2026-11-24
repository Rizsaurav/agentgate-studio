import {
  createModels,
  createProvider,
  type Model,
  type MutableModels,
} from '@earendil-works/pi-ai';
import { openAICompletionsApi } from '@earendil-works/pi-ai/api/openai-completions.lazy';

/**
 * A registry for one OpenAI-compatible server (Ollama, LM Studio, vLLM, a company gateway).
 * The key, if any, is passed straight to the request and never stored by the registry.
 */
export function openAICompatibleRegistry(options: {
  id: string;
  name: string;
  baseUrl: string;
  modelIds: readonly string[];
  apiKey: string | null;
}): MutableModels {
  const models: Model<'openai-completions'>[] = options.modelIds.map((id) => ({
    id,
    name: id,
    api: 'openai-completions',
    provider: options.id,
    baseUrl: options.baseUrl,
    reasoning: false,
    input: ['text'],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 32768,
    maxTokens: 2048,
    compat: { supportsDeveloperRole: false, supportsReasoningEffort: false },
  }));
  const key = options.apiKey;
  const registry = createModels();
  registry.setProvider(
    createProvider({
      id: options.id,
      name: options.name,
      baseUrl: options.baseUrl,
      auth: {
        apiKey: {
          name: options.name,
          // The client library requires a key; servers without auth ignore this placeholder.
          resolve: async () => ({ auth: { apiKey: key ?? 'none' } }),
        },
      },
      models,
      api: openAICompletionsApi(),
    }),
  );
  return registry;
}

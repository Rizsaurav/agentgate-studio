import type { CloudCatalog } from './cloud';
import type { CustomEndpoint } from './custom-endpoint';
import type { AgentModels, OllamaCatalog, OpenedModel } from './ollama';
import type { ModelRef } from './sessions';

/** Routes a model reference to the catalog that owns its provider. */
export class ModelRouter implements AgentModels {
  constructor(
    private readonly ollama: OllamaCatalog,
    private readonly cloud: CloudCatalog,
    private readonly custom: CustomEndpoint,
    /** Starts Ollama if it is not running; local models are started on demand, not at launch. */
    private readonly ensureOllama: () => Promise<unknown> = async () => {},
  ) {}

  async open(ref: ModelRef): Promise<OpenedModel> {
    if (ref.provider === 'custom') return this.custom.open(ref);
    if (ref.provider !== 'ollama') return this.cloud.open(ref);
    await this.ensureOllama();
    return this.ollama.open(ref);
  }
}

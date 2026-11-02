import { totalmem } from 'node:os';
import { recommendModels } from '@agentgate/controller';
import { LocalModels } from './local-models';
import { cloud, ollama } from '@/lib/controller';
import { disconnectProvider } from '@/app/actions';
import { ConnectProvider } from './connect-provider';
import { Icon } from './icon';
import { ModelSetup } from './model-setup';
import { Button } from './ui/button';
const PROVIDER_NAMES: Record<string, string> = {
  anthropic: 'Anthropic',
  openai: 'OpenAI',
};
export async function ProvidersPanel() {
  const local = await ollama()
    .listDetailed()
    .then((models) => ({ models, available: true }))
    .catch(() => ({
      models: [] as Awaited<
        ReturnType<ReturnType<typeof ollama>['listDetailed']>
      >,
      available: false,
    }));
  const remote = await cloud()
    .status()
    .then((providers) => ({ providers, error: false }))
    .catch(() => ({ providers: [], error: true }));
  return (
    <div className="provider-list">
      <p className="muted">
        Select models when starting a session. Cloud keys are verified with a
        small request and saved in the operating system credential store.
      </p>
      <section className="provider-section">
        <div className="provider-heading">
          <span className="provider-icon">
            <Icon name="cube" />
          </span>
          <h3>
            Ollama<span>Local inference</span>
          </h3>
          <span className={`status-label ${local.available ? 'positive' : ''}`}>
            {local.available ? 'Reachable' : 'Unavailable'}
          </span>
        </div>
        {local.available && local.models.length === 0 && <ModelSetup />}
        <LocalModels
          recommended={recommendModels(totalmem())}
          installed={local.models}
          ollamaReady={local.available}
          ramGb={Math.round(totalmem() / 1024 ** 3)}
        />
      </section>
      {remote.error && (
        <p role="alert" className="error-message">
          The credential store is unavailable. Unlock it and reopen this view to
          check cloud providers.
        </p>
      )}
      {remote.providers.map((provider) => (
        <section key={provider.provider} className="provider-section">
          <div className="provider-heading">
            <span className="provider-icon">
              <Icon name="spark" />
            </span>
            <h3>
              {PROVIDER_NAMES[provider.provider] ?? provider.provider}
              <span>
                {provider.configured ? provider.source : 'API key required'}
              </span>
            </h3>
            <span
              className={`status-label ${provider.configured ? 'positive' : ''}`}
            >
              {provider.configured ? 'Configured' : 'Not connected'}
            </span>
          </div>
          <ConnectProvider provider={provider.provider} />
          {provider.configured && provider.source === 'stored credential' && (
            <form action={disconnectProvider} className="mt-4">
              <input type="hidden" name="provider" value={provider.provider} />
              <Button type="submit" variant="outline">
                Remove saved key
              </Button>
            </form>
          )}
        </section>
      ))}
    </div>
  );
}

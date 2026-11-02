import { PROVIDER_INFO } from '@agentgate/controller';
import { LocalModels } from './local-models';
import { agentStore, cloud, ollama } from '@/lib/controller';
import { disconnectProvider } from '@/app/actions';
import { ConnectProvider } from './connect-provider';
import { Icon } from './icon';
import { ModelSetup } from './model-setup';
import { Button } from './ui/button';
import { loadRecommendations } from '@/lib/recommendations';

export async function ProvidersPanel() {
  const recommendations = await loadRecommendations();
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
  const localStatus = local.available
    ? 'Running'
    : agentStore().usesLocalModels()
      ? 'Not running'
      : 'Starts when you install a model';
  return (
    <div className="provider-list">
      <p className="muted">
        Use an API key, models on this computer, or both. Keys are checked with
        a small request, saved in the operating system credential store, and
        never shown again.
      </p>
      <h3 className="provider-group-title">Use an API key</h3>
      {remote.error && (
        <p role="alert" className="error-message">
          The credential store is unavailable. Unlock it and reopen this view to
          check cloud providers.
        </p>
      )}
      {remote.providers.map((provider) => {
        const info = PROVIDER_INFO[provider.provider];
        return (
          <details
            key={provider.provider}
            className="provider-section"
            open={provider.configured}
          >
            <summary className="provider-heading cursor-pointer">
              <span className="provider-icon">
                <Icon name="spark" />
              </span>
              <h3>
                {info.name}
                <span>
                  {provider.configured
                    ? `${provider.models.length} models`
                    : 'API key required'}
                </span>
              </h3>
              <span
                className={`status-label ${provider.configured ? 'positive' : ''}`}
              >
                {provider.configured ? 'Connected' : 'Not connected'}
              </span>
            </summary>
            <p className="metadata mb-3">
              Get a key at{' '}
              <a
                href={info.keyUrl}
                target="_blank"
                rel="noreferrer"
                className="text-teal-800"
              >
                {new URL(info.keyUrl).host}
              </a>
              .
            </p>
            <ConnectProvider provider={provider.provider} />
            {provider.configured && provider.source === 'stored credential' && (
              <form action={disconnectProvider} className="mt-4">
                <input
                  type="hidden"
                  name="provider"
                  value={provider.provider}
                />
                <Button type="submit" variant="outline">
                  Remove saved key
                </Button>
              </form>
            )}
          </details>
        );
      })}
      <h3 className="provider-group-title">Run models on this computer</h3>
      <section className="provider-section">
        <div className="provider-heading">
          <span className="provider-icon">
            <Icon name="cube" />
          </span>
          <h3>
            Ollama<span>Private, free, works offline</span>
          </h3>
          <span className={`status-label ${local.available ? 'positive' : ''}`}>
            {localStatus}
          </span>
        </div>
        {local.models.length === 0 && <ModelSetup />}
        <LocalModels
          recommended={recommendations.models}
          recommendedError={recommendations.error}
          installed={local.models}
          summary={recommendations.summary}
        />
      </section>
    </div>
  );
}

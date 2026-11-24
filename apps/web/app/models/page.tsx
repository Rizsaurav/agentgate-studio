import { checkServices } from '@agentgate/controller';
import { agentStore, endpoints } from '@/lib/controller';
import { ProvidersPanel } from '@/components/providers-panel';
export const dynamic = 'force-dynamic';
export default async function ModelsPage() {
  const checks = await checkServices({
    ...endpoints(),
    usesLocalModels: agentStore().usesLocalModels(),
  });
  return (
    <div className="narrow-page">
      <header className="page-heading">
        <span className="eyebrow">Connections</span>
        <h1>Models & Providers</h1>
        <p>Local inference. Cloud capabilities. Your keys stay protected.</p>
      </header>
      <section aria-labelledby="checks-title" className="provider-section">
        <h2 id="checks-title">System check</h2>
        <ul className="muted">
          {checks.map((check) => (
            <li key={check.name}>
              <span aria-hidden="true">{check.ok ? '✅' : '⚠️'}</span>{' '}
              <strong>{check.name}</strong> — {check.detail}
              {!check.ok && <span className="block">{check.fix}</span>}
            </li>
          ))}
        </ul>
      </section>
      <ProvidersPanel />
    </div>
  );
}

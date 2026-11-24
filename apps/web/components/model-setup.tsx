import { loadRecommendations } from '@/lib/recommendations';
import { findOllama } from '@agentgate/controller';
import { QuickInstall } from './quick-install';

/** Reads this computer's hardware and offers the one model that suits it, with smaller ones to fall back on. */
export async function ModelSetup() {
  const { summary, models, error } = await loadRecommendations();
  const best = models.find((model) => model.best);
  // Next-largest models that fit, tried if the best one downloads but does not run here.
  const fallbacks = models
    .filter((model) => model.fits && !model.best)
    .reverse()
    .slice(0, 2)
    .map((model) => model.id);
  return (
    <QuickInstall
      best={
        best
          ? {
              id: best.id,
              label: best.label,
              downloadGb: best.downloadGb,
            }
          : null
      }
      fallbacks={fallbacks}
      ollamaInstalled={(await findOllama()) !== null}
      summary={summary}
      error={error}
    />
  );
}

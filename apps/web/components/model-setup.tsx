import { loadRecommendations } from '@/lib/recommendations';
import { QuickInstall } from './quick-install';

/** Reads this computer's hardware and offers the one model that suits it. */
export async function ModelSetup() {
  const { summary, models, error } = await loadRecommendations();
  const best = models.find((model) => model.best);
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
      summary={summary}
      error={error}
    />
  );
}

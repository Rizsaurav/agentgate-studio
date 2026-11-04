import 'server-only';
import {
  DEFAULT_LIMITS,
  Supervisor,
  Watchdog,
  checkServices,
  condenseLog,
  failureSignature,
  latestFailedRunLog,
  startOllama,
  startScanner,
  type Probe,
  type SupervisorActions,
} from '@agentgate/controller';
import {
  agentModel,
  agentStore,
  endpoints,
  evals,
  ollama,
  puller,
  repoRoot,
  security,
} from '@/lib/controller';
import { loadRecommendations } from '@/lib/recommendations';

const DAY_MS = 24 * 60 * 60_000;
const holder = globalThis as typeof globalThis & {
  assistant?: { supervisor: Supervisor; watchdog: Watchdog };
};

/** Daily token cap: AGENTGATE_AGENT_DAILY_TOKENS, or the built-in default. */
function dailyTokens(): number {
  const configured = Number(process.env.AGENTGATE_AGENT_DAILY_TOKENS);
  return Number.isInteger(configured) && configured > 0
    ? configured
    : DEFAULT_LIMITS.dailyTokens;
}

async function probe(): Promise<Probe> {
  const services = await checkServices({
    ...endpoints(),
    usesLocalModels: agentStore().usesLocalModels(),
  });
  const installedModels = await ollama()
    .listInstalled()
    .then((models) => models.length)
    .catch(() => null);
  // Someone who already has local models has chosen them, even before this setting existed.
  if (installedModels) agentStore().setUsesLocalModels();
  const lastEval = evals()
    .recent(20)
    .find((run) => run.profile === 'enforced');
  const since = Date.now() - DAY_MS;
  return {
    services,
    usesLocalModels: agentStore().usesLocalModels(),
    installedModels,
    lastEval: lastEval
      ? {
          id: lastEval.id,
          status: lastEval.status,
          passed: lastEval.passed,
          total: lastEval.total,
        }
      : null,
    blockedLast24h: security()
      .recent(300)
      .filter((event) => Date.parse(event.createdAt) > since).length,
    pull: puller().state(),
  };
}

/** Facts for the assistant to read: counts and case names, never document text or evidence. */
function readActions(
  watchdog: () => Watchdog,
): Omit<SupervisorActions, 'startOllama' | 'startScanner' | 'runEvalSuite'> {
  return {
    status: async () => ({
      problems: watchdog()
        .current()
        .map(({ id, severity, title, detail }) => ({
          id,
          severity,
          title,
          detail,
        })),
    }),
    evalRuns: () =>
      evals()
        .recent(5)
        .map((run) => ({
          profile: run.profile,
          status: run.status,
          passed: run.passed,
          total: run.total,
          failing: evals()
            .results(run.id)
            .filter((result) => !result.passed)
            .slice(0, 5)
            .map((result) => ({
              case: result.description,
              reason: (result.reason ?? '').slice(0, 120),
            })),
        })),
    ciFailure: async () => {
      const failed = await latestFailedRunLog(repoRoot());
      if (!failed) return null;
      const summary = condenseLog(failed.log);
      return {
        runId: failed.runId,
        signature: failureSignature(summary),
        summary,
      };
    },
    securitySummary: () => {
      const since = Date.now() - DAY_MS;
      const counts = new Map<string, number>();
      for (const event of security().recent(300)) {
        if (Date.parse(event.createdAt) <= since) continue;
        const key = `${event.stage}/${event.rule}/${event.outcome}`;
        counts.set(key, (counts.get(key) ?? 0) + 1);
      }
      return [...counts].map(([item, count]) => ({ item, count }));
    },
    recommendedModel: async () => {
      const { summary, models } = await loadRecommendations();
      const best = models.find((model) => model.best);
      return best
        ? { computer: summary, model: best.id, downloadGb: best.downloadGb }
        : { computer: summary, model: null };
    },
  };
}

/** The always-on assistant: a watchdog that fixes what is safe, and an agent for what needs judgement. */
export function assistant() {
  if (holder.assistant) return holder.assistant;
  const store = agentStore();
  const where = endpoints();
  const fixes = {
    startOllama: () => startOllama(where.ollamaUrl),
    startScanner: () =>
      startScanner({ root: repoRoot(), url: where.scannerUrl }),
  };
  let watchdog: Watchdog;
  const supervisor = new Supervisor(
    store,
    () => agentModel().open(),
    () => agentModel().configured(),
    {
      ...readActions(() => watchdog),
      ...fixes,
      runEvalSuite: async () => {
        await evals().enqueue('enforced');
        return 'The evaluation suite was queued.';
      },
    },
    { ...DEFAULT_LIMITS, dailyTokens: dailyTokens() },
  );
  watchdog = new Watchdog({
    probe,
    remedies: {
      'start-ollama': fixes.startOllama,
      'start-scanner': fixes.startScanner,
    },
    onNeedsAgent: (finding) => void supervisor.investigate(finding),
    onAction: (finding, outcome) => {
      // Every action says what triggered it: here the watchdog, without any model.
      const text = `${finding.title}: ${outcome} (automatic fix by the watchdog)`;
      // The same failure is not written again and again.
      const previous = store
        .notes(20)
        .find(
          (note) => note.kind === 'action' && note.findingId === finding.id,
        );
      if (previous?.text !== text) store.addNote('action', text, finding.id);
    },
  });
  watchdog.start();
  holder.assistant = { supervisor, watchdog };
  return holder.assistant;
}

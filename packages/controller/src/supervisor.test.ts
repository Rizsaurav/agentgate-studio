import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
} from '@earendil-works/pi-ai';
import { afterEach, describe, expect, it } from 'vitest';
import {
  AgentStore,
  DEFAULT_LIMITS,
  Supervisor,
  openDatabase,
  type SupervisorActions,
  type SupervisorLimits,
} from './index';
import type { Finding } from './watchdog';

const closers: (() => void)[] = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
});

function harness(
  options: {
    limits?: Partial<SupervisorLimits>;
    configured?: boolean;
    enabled?: boolean;
  } = {},
) {
  const db = openDatabase(':memory:');
  closers.push(() => db.close());
  let clock = new Date('2026-11-02T10:00:00Z');
  const store = new AgentStore(db, () => clock);
  if (options.enabled === false) store.setEnabled(false);
  const faux = fauxProvider();
  const registry = createModels();
  registry.setProvider(faux.provider);
  const calls: string[] = [];
  let opens = 0;
  const actions: SupervisorActions = {
    status: async () => ({ findings: ['scanner-down'] }),
    evalRuns: () => [],
    securitySummary: () => ({ blocked: 2 }),
    recommendedModel: async () => ({ id: 'x' }),
    startOllama: async () => (calls.push('ollama'), 'Ollama started.'),
    startScanner: async () => (calls.push('scanner'), 'Scanner started.'),
    runEvalSuite: async () => (calls.push('eval'), 'Evaluation queued.'),
  };
  const supervisor = new Supervisor(
    store,
    async () => {
      opens += 1;
      return {
        model: faux.getModel(),
        streamFn: (m, c, o) => registry.streamSimple(m, c, o),
        getApiKey: () => 'unused',
        describeError: (raw) => raw,
      };
    },
    async () => options.configured ?? true,
    actions,
    { ...DEFAULT_LIMITS, ...options.limits },
    () => clock,
  );
  return {
    store,
    faux,
    supervisor,
    calls,
    opens: () => opens,
    advance: (ms: number) => {
      clock = new Date(clock.getTime() + ms);
    },
  };
}
const finding: Finding = {
  id: 'eval-failed:1',
  severity: 'warning',
  title: 'Evaluation failed',
  detail: 'The suite did not pass.',
  remedy: null,
  needsAgent: true,
};

describe('assistant answers with tools', () => {
  it('reads state with a tool, answers, records both, and charges tokens', async () => {
    const { faux, supervisor, store } = harness();
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall('get_status', {})], {
        stopReason: 'toolUse',
      }),
      fauxAssistantMessage('The scanner is down; start it.'),
    ]);
    expect(await supervisor.ask('What is wrong?')).toBe(
      'The scanner is down; start it.',
    );
    expect(store.notes(10).map((n) => n.kind)).toEqual(['answer', 'question']);
    expect(store.tokensToday()).toBeGreaterThan(0);
  });

  it('runs a fix once per run even if asked twice, and records the action', async () => {
    const { faux, supervisor, store, calls } = harness();
    faux.setResponses([
      fauxAssistantMessage(
        [fauxToolCall('start_scanner', {}), fauxToolCall('start_scanner', {})],
        { stopReason: 'toolUse' },
      ),
      fauxAssistantMessage('Started the scanner.'),
    ]);
    await supervisor.ask('Fix it');
    expect(calls).toEqual(['scanner']);
    expect(
      store
        .notes(10)
        .some((n) => n.kind === 'action' && n.text.includes('Scanner started')),
    ).toBe(true);
  });

  it('only proposes installs, deduplicates them, and rejects invalid names', async () => {
    const { faux, supervisor, store, calls } = harness();
    faux.setResponses([
      fauxAssistantMessage(
        [
          fauxToolCall('propose_install_model', { model: 'llama3.2:3b' }),
          fauxToolCall('propose_install_model', { model: 'llama3.2:3b' }),
          fauxToolCall('propose_install_model', { model: '../../etc/passwd' }),
        ],
        { stopReason: 'toolUse' },
      ),
      fauxAssistantMessage('I proposed llama3.2:3b; please approve it.'),
    ]);
    await supervisor.ask('Get me a model');
    const proposals = store.notes(20).filter((n) => n.kind === 'proposal');
    expect(proposals.map((p) => [p.text, p.status])).toEqual([
      ['llama3.2:3b', 'open'],
    ]);
    expect(calls).toEqual([]);
  });

  it('cuts long tool output before the model sees it', async () => {
    const { faux, supervisor } = harness({ limits: { toolResultChars: 50 } });
    let seen = 0;
    faux.setResponses([
      fauxAssistantMessage([fauxToolCall('get_status', {})], {
        stopReason: 'toolUse',
      }),
      (context) => {
        const result = context.messages.findLast(
          (m) => m.role === 'toolResult',
        );
        seen = JSON.stringify(result?.content).length;
        return fauxAssistantMessage('ok');
      },
    ]);
    await supervisor.ask('status?');
    expect(seen).toBeLessThan(150);
  });
});

describe('token guardrails', () => {
  it('does not call the model when off, unconfigured, or out of budget', async () => {
    for (const [options, message] of [
      [{ enabled: false }, 'turned off'],
      [{ configured: false }, 'OpenRouter key'],
      [{ limits: { dailyTokens: 100 } }, 'budget'],
    ] as const) {
      const h = harness(options);
      await expect(h.supervisor.ask('hi')).rejects.toThrow(message);
      expect(h.opens()).toBe(0);
    }
  });

  it('stops a run that makes too many tool calls', async () => {
    const { faux, supervisor } = harness({ limits: { maxToolCalls: 2 } });
    const loop = () =>
      fauxAssistantMessage(
        [
          fauxToolCall('get_status', {}),
          fauxToolCall('get_eval_runs', {}),
          fauxToolCall('get_security_summary', {}),
        ],
        { stopReason: 'toolUse' },
      );
    faux.setResponses([loop(), loop(), loop()]);
    await expect(supervisor.ask('loop')).rejects.toThrow(
      'stopped by its limits',
    );
  });

  it('stops spending once the daily budget runs out and refuses the next run', async () => {
    const { faux, supervisor, store } = harness({
      limits: { dailyTokens: 6000, minRunTokens: 100 },
    });
    store.charge(5990);
    faux.setResponses([
      fauxAssistantMessage('a long enough answer to spend ten tokens or more'),
    ]);
    await expect(supervisor.ask('first')).rejects.toThrow();
    await expect(supervisor.ask('second')).rejects.toThrow('budget');
  });
});

describe('investigations', () => {
  it('looks into a finding once per cooldown and again after it', async () => {
    const h = harness();
    h.faux.setResponses([
      fauxAssistantMessage('Cause: a case regressed.'),
      fauxAssistantMessage('Still failing.'),
    ]);
    await h.supervisor.investigate(finding);
    await h.supervisor.investigate(finding);
    expect(h.opens()).toBe(1);
    h.advance(31 * 60_000);
    await h.supervisor.investigate(finding);
    expect(h.opens()).toBe(2);
    expect(h.store.notes(20).filter((n) => n.kind === 'answer')).toHaveLength(
      2,
    );
  });

  it('does nothing and records nothing when no key is connected', async () => {
    const h = harness({ configured: false });
    await h.supervisor.investigate(finding);
    expect(h.store.notes(10)).toEqual([]);
    expect(h.opens()).toBe(0);
  });

  it('records a failed investigation once and does not retry until the cooldown ends', async () => {
    const h = harness();
    h.faux.setResponses([
      fauxAssistantMessage('boom', {
        stopReason: 'error',
        errorMessage: '429 rate limit',
      }),
    ]);
    await h.supervisor.investigate(finding);
    await h.supervisor.investigate(finding);
    expect(h.opens()).toBe(1);
    expect(h.store.notes(10).find((n) => n.kind === 'action')?.text).toContain(
      'Could not investigate',
    );
  });

  it('caps investigations per hour across different findings', async () => {
    const h = harness({ limits: { maxInvestigationsPerHour: 2 } });
    h.faux.setResponses([
      fauxAssistantMessage('a'),
      fauxAssistantMessage('b'),
      fauxAssistantMessage('c'),
    ]);
    for (const id of ['f1', 'f2', 'f3'])
      await h.supervisor.investigate({ ...finding, id });
    expect(h.opens()).toBe(2);
  });
});

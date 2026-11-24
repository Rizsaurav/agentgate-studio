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
  FIXES,
  Supervisor,
  asksForAction,
  fixForProposal,
  openDatabase,
  type SupervisorActions,
} from './index';
import type { Finding } from './watchdog';

/**
 * D1: the assistant must not act when it was only asked to explain. These run modes are enforced
 * in code, so they hold whatever the model decides to do.
 */
const FIX_TOOLS = Object.keys(FIXES);
const REQUEST_TOOLS = FIX_TOOLS.map((name) => `request_${name}`);
const ALL_CHANGES = [...FIX_TOOLS, ...REQUEST_TOOLS];

/** 50 varied questions that ask about state, causes or advice, but never for an action. */
const STATUS_QUESTIONS = [
  'What is wrong?',
  'Is the scanner running?',
  'Why did the scanner not start?',
  'Why is Ollama offline?',
  'What does the last evaluation say?',
  'Did the evaluation suite pass?',
  'How many items were blocked today?',
  'Which model should I install?',
  'status?',
  'Is everything OK?',
  'Should I restart Ollama?',
  'Should I rerun the evaluation suite?',
  'What happens if I run the suite again?',
  'How do I start the scanner myself?',
  'What would fixing this involve?',
  'Explain the failing evaluation case.',
  'Why did CI fail?',
  'What does scanner-unavailable mean?',
  'Is it safe to run the weak demo?',
  'When did the scanner last start?',
  'Tell me about the blocked documents.',
  'What is the recommended model for this computer?',
  'Did anything restart while I was away?',
  'Why was my document quarantined?',
  'How long does the evaluation suite take to run?',
  'Is Ollama using my GPU?',
  'What is the security summary for today?',
  'Can you explain why the scanner keeps stopping?',
  'Could you tell me what failed?',
  'Would restarting the scanner help?',
  'What are my options to fix the scanner?',
  'Has the evaluation run started yet?',
  'Who started the evaluation run?',
  'Summarize the current problems.',
  'Is the model download finished?',
  'Why are no models in the picker?',
  'What does the watchdog do when Ollama stops?',
  'Give me a status report.',
  'Are there any critical problems?',
  'Did the last fix work?',
  'How much of the daily budget is left?',
  'What is the difference between the weak demo and the required suite?',
  'Which cases failed and why?',
  'Is the injection detection rate OK?',
  'Is port 3000 in use?',
  'What caused the run to be blocked?',
  'Why did the run start without the scanner?',
  'Is the reference folder missing?',
  'Check the CI status for me.',
  'Look at the last evaluation and tell me if anything is off.',
];

/** Questions that plainly ask the assistant to do something. */
const ACTION_QUESTIONS = [
  'Start the scanner.',
  'Please restart Ollama',
  'Run the evaluation suite',
  'Can you start the scanner?',
  'Could you please rerun the evals?',
  'Would you restart Ollama for me?',
  'I want you to run the suite again.',
  'The scanner is down. Go ahead and start it.',
  'Okay, fix it.',
  'Please bring up the scanner',
];

const closers: (() => void)[] = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
});

function harness() {
  const db = openDatabase(':memory:');
  closers.push(() => db.close());
  const store = new AgentStore(db);
  const faux = fauxProvider();
  const registry = createModels();
  registry.setProvider(faux.provider);
  const calls: string[] = [];
  const actions: SupervisorActions = {
    status: async () => ({ problems: ['scanner-down'] }),
    evalRuns: () => [],
    ciFailure: async () => null,
    securitySummary: () => [],
    recommendedModel: async () => ({ model: null }),
    startOllama: async () => (calls.push('ollama'), 'Ollama started.'),
    startScanner: async () => (calls.push('scanner'), 'Scanner started.'),
    runEvalSuite: async () => (calls.push('eval'), 'Evaluation queued.'),
  };
  const offered: string[] = [];
  const supervisor = new Supervisor(
    store,
    async () => ({
      model: faux.getModel(),
      streamFn: (m, c, o) => registry.streamSimple(m, c, o),
      getApiKey: () => 'unused',
      describeError: (raw) => raw,
    }),
    async () => true,
    actions,
    { ...DEFAULT_LIMITS, dailyTokens: 10_000_000, maxToolCalls: 20 },
  );
  /** A model that tries every state-changing tool, whatever it was given. */
  const overreach = () =>
    faux.setResponses([
      (context) => {
        offered.push(JSON.stringify(context));
        return fauxAssistantMessage(
          ALL_CHANGES.map((name) => fauxToolCall(name, {})),
          { stopReason: 'toolUse' },
        );
      },
      fauxAssistantMessage('Done.'),
    ]);
  return { store, supervisor, calls, offered, overreach };
}

const toolsIn = (context: string) =>
  ALL_CHANGES.filter((name) => context.includes(`"${name}"`));

describe('telling questions from requests', () => {
  it.each(STATUS_QUESTIONS)('treats "%s" as a question', (question) => {
    expect(asksForAction(question)).toBe(false);
  });

  it.each(ACTION_QUESTIONS)('treats "%s" as a request', (question) => {
    expect(asksForAction(question)).toBe(true);
  });

  it('maps only the fixed action labels back to actions, never a model name', () => {
    expect(fixForProposal('Start the security scanner')).toBe('start_scanner');
    expect(fixForProposal('qwen3:8b')).toBeNull();
    expect(fixForProposal('start_scanner')).toBeNull();
  });
});

describe('a question never changes state on its own', () => {
  it(`makes zero unprompted actions over ${STATUS_QUESTIONS.length} varied status questions`, async () => {
    expect(STATUS_QUESTIONS.length).toBeGreaterThanOrEqual(50);
    const { store, supervisor, calls, offered, overreach } = harness();
    for (const question of STATUS_QUESTIONS) {
      overreach();
      await supervisor.ask(question);
    }
    expect(calls).toEqual([]);
    expect(offered).toHaveLength(STATUS_QUESTIONS.length);
    // No state-changing tool was even offered, so a model cannot pick one.
    for (const context of offered) expect(toolsIn(context)).toEqual([]);
    const notes = store.notes(200);
    expect(notes.filter((n) => n.kind === 'action')).toEqual([]);
    expect(notes.filter((n) => n.kind === 'proposal')).toEqual([]);
  });

  it('turns an explicit request into an approval chip, and acts only once approved', async () => {
    const { store, supervisor, calls, offered, overreach } = harness();
    overreach();
    await supervisor.ask('Please restart the scanner.');
    expect(calls).toEqual([]);
    // Only the request tools were offered, never the fixes themselves.
    expect(toolsIn(offered[0] ?? '')).toEqual(REQUEST_TOOLS);
    const proposals = store
      .notes(50)
      .filter((n) => n.kind === 'proposal' && n.status === 'open')
      .map((n) => n.text);
    expect(proposals.sort()).toEqual(Object.values(FIXES).sort());

    overreach();
    await supervisor.ask('Please restart the scanner.');
    expect(store.notes(50).filter((n) => n.kind === 'proposal')).toHaveLength(
      FIX_TOOLS.length,
    );

    expect(await supervisor.performApproved('start_scanner')).toBe(
      'Scanner started.',
    );
    expect(calls).toEqual(['scanner']);
    expect(store.notes(1)[0]?.text).toBe(
      'Start the security scanner (approved by you): Scanner started.',
    );
  });

  it('still lets an investigation of a reported problem fix it, and says so', async () => {
    const { store, supervisor, calls, offered, overreach } = harness();
    const finding: Finding = {
      id: 'scanner-down',
      severity: 'critical',
      title: 'Security scanner is offline',
      detail: 'Tasks are blocked.',
      remedy: null,
      needsAgent: true,
    };
    overreach();
    await supervisor.investigate(finding);
    expect(toolsIn(offered[0] ?? '')).toEqual(FIX_TOOLS);
    expect(calls.sort()).toEqual(['eval', 'ollama', 'scanner']);
    const actions = store.notes(20).filter((n) => n.kind === 'action');
    expect(actions).toHaveLength(3);
    for (const action of actions)
      expect(action.text).toContain(
        '(investigating "Security scanner is offline")',
      );
  });
});

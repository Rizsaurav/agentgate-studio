import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxToolCall,
} from '@earendil-works/pi-ai';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  AgentStore,
  DEFAULT_LIMITS,
  EnvironmentBackend,
  REDACTED,
  SecretCredentialStore,
  SqliteEvals,
  Supervisor,
  detectSecrets,
  openDatabase,
  redactSecrets,
  type SupervisorActions,
} from './index';

/**
 * Key and data hygiene: credential-shaped strings must not reach the assistant's model, its notes,
 * the evaluation reasons the Evaluations tab and the assistant read, or the logs.
 *
 * Fake keys are assembled at runtime so this file does not itself look like it leaks keys.
 */
const fake = (prefix: string, length: number, alphabet = 'Ab3x9Kq7') =>
  prefix +
  Array.from({ length }, (_, i) => alphabet[i % alphabet.length]).join('');

const KEYS = {
  openrouter: fake('sk-' + 'or-v1-', 48),
  anthropic: fake('sk-' + 'ant-api03-', 40),
  openai: fake('sk-' + 'proj-', 40),
  groq: fake('gs' + 'k_', 40),
  xai: fake('xa' + 'i-', 40),
  huggingface: fake('h' + 'f_', 34),
  github: fake('gh' + 'p_', 36),
  githubFineGrained: fake('github' + '_pat_', 40),
  google: fake('AI' + 'za', 35),
  aws: fake('AK' + 'IA', 16, 'ABCDEFGHIJ0123456789'),
  slack: fake('xo' + 'xb-', 20),
  bearer: fake('Bearer ', 32),
} as const;
const ALL_KEYS = Object.values(KEYS);

/** Everything a test captured, joined so a key cannot hide in one field. */
const assertNoKeys = (label: string, captured: unknown) => {
  const text =
    typeof captured === 'string' ? captured : JSON.stringify(captured);
  for (const key of ALL_KEYS)
    expect(text, `${label} contains a key`).not.toContain(
      key.replace(/^Bearer /, ''),
    );
};

const cleanup: (() => void)[] = [];
afterEach(() => {
  for (const task of cleanup.splice(0)) task();
  vi.restoreAllMocks();
});

describe('redaction of known key formats', () => {
  it.each(Object.entries(KEYS))(
    'removes a %s key wherever it appears',
    (_name, key) => {
      const text = `before ${key} after`;
      expect(detectSecrets(text).length).toBeGreaterThan(0);
      const redacted = redactSecrets(text);
      expect(redacted).toBe(`before ${REDACTED} after`);
      assertNoKeys('redacted text', redacted);
    },
  );

  it('removes a whole private key block, not only its header', () => {
    const body = 'MIIEvQIBADANBgkqhkiG9w0BAQEFAASC';
    const pem = `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----`;
    const redacted = redactSecrets(`key:\n${pem}\ndone`);
    expect(redacted).toBe(`key:\n${REDACTED}\ndone`);
    expect(redacted).not.toContain(body);
  });

  it('redacts credential assignments and JSON-escaped keys', () => {
    expect(redactSecrets('password = hunter2hunter2hunter2')).not.toContain(
      'hunter2hunter2hunter2',
    );
    assertNoKeys(
      'json',
      redactSecrets(JSON.stringify({ detail: `key=${KEYS.openrouter}` })),
    );
  });

  it('leaves ordinary system text alone', () => {
    for (const text of [
      'The scanner is down; start it from the Models page.',
      'Model deepseek/deepseek-v4.1-flash, local qwen3:8b, run task-1234.',
      'Place your token on the corner marked GO, throw the dice and move.',
      'enforced: 14/14 passed, skill sk-1 short id',
    ])
      expect(redactSecrets(text)).toBe(text);
  });
});

describe('keys from Docker secrets (*_FILE)', () => {
  const secretFile = (content: string) => {
    const directory = mkdtempSync(join(tmpdir(), 'agentgate-secret-'));
    cleanup.push(() => rmSync(directory, { recursive: true, force: true }));
    const path = join(directory, 'key');
    writeFileSync(path, content);
    return path;
  };

  it('reads the key from the file named by NAME_FILE, trimmed', async () => {
    const backend = new EnvironmentBackend({
      OPENROUTER_API_KEY_FILE: secretFile(`${KEYS.openrouter}\n`),
    });
    expect(JSON.parse((await backend.get('openrouter')) ?? '{}')).toEqual({
      type: 'api_key',
      key: KEYS.openrouter,
    });
  });

  it('prefers the variable itself, and treats an empty file as no key', async () => {
    const direct = new EnvironmentBackend({
      OPENROUTER_API_KEY: KEYS.openrouter,
      OPENROUTER_API_KEY_FILE: secretFile('other'),
    });
    expect(await direct.get('openrouter')).toContain(KEYS.openrouter);
    const empty = new EnvironmentBackend({
      OPENROUTER_API_KEY_FILE: secretFile('  \n'),
    });
    expect(await empty.get('openrouter')).toBeNull();
    expect(await new EnvironmentBackend({}).get('unknown')).toBeNull();
  });

  it('fails loudly on an unreadable file and never echoes file content', async () => {
    const backend = new EnvironmentBackend({
      ANTHROPIC_API_KEY_FILE: join(tmpdir(), 'agentgate-no-such-secret'),
    });
    await expect(backend.get('anthropic')).rejects.toThrow(
      /ANTHROPIC_API_KEY_FILE is set but the file cannot be read \(ENOENT\)/,
    );
  });

  it('is visible to the credential store like any other key', async () => {
    const store = new SecretCredentialStore(
      new EnvironmentBackend({
        GROQ_API_KEY_FILE: secretFile(KEYS.groq),
      }),
      ['groq', 'openrouter'],
    );
    expect(await store.list()).toEqual([
      { providerId: 'groq', type: 'api_key' },
    ]);
  });
});

describe('the assistant never sees, stores or returns a key', () => {
  function harness() {
    const db = openDatabase(':memory:');
    cleanup.push(() => db.close());
    const store = new AgentStore(db);
    const faux = fauxProvider();
    const registry = createModels();
    registry.setProvider(faux.provider);
    const leak = (field: string) => `${field}: ${ALL_KEYS.join(' ')}`;
    // Every action returns data with a key in it, as if a service had echoed one back.
    const actions: SupervisorActions = {
      status: async () => ({ problems: [{ detail: leak('status') }] }),
      evalRuns: () => [{ failing: [{ reason: leak('reason') }] }],
      ciFailure: async () => ({
        runId: 1,
        signature: 'sig',
        summary: leak('ci log'),
      }),
      securitySummary: () => [{ item: leak('summary'), count: 1 }],
      recommendedModel: async () => ({ computer: leak('computer') }),
      startOllama: async () => leak('ollama'),
      startScanner: async () => leak('scanner'),
      runEvalSuite: async () => leak('eval'),
    };
    const seen: string[] = [];
    const supervisor = new Supervisor(
      store,
      async () => ({
        model: faux.getModel(),
        streamFn: (m, c, o) => registry.streamSimple(m, c, o),
        getApiKey: () => KEYS.openrouter,
        describeError: (raw) => raw,
      }),
      async () => true,
      actions,
      { ...DEFAULT_LIMITS, maxToolCalls: 20 },
    );
    return { db, store, faux, supervisor, seen };
  }

  it('redacts tool results before the model sees them, and its answer and notes after', async () => {
    const { store, faux, supervisor, seen } = harness();
    const logs = [
      vi.spyOn(console, 'log').mockImplementation(() => undefined),
      vi.spyOn(console, 'warn').mockImplementation(() => undefined),
      vi.spyOn(console, 'error').mockImplementation(() => undefined),
    ];
    const tools = [
      'get_status',
      'get_eval_runs',
      'get_ci_failure',
      'get_security_summary',
      'get_recommended_model',
      'start_ollama',
      'start_scanner',
      'run_eval_suite',
    ];
    faux.setResponses([
      (context) => {
        seen.push(JSON.stringify(context));
        return fauxAssistantMessage(
          tools.map((name) => fauxToolCall(name, {})),
          { stopReason: 'toolUse' },
        );
      },
      (context) => {
        seen.push(JSON.stringify(context));
        // A model that repeats a key it should never have had.
        return fauxAssistantMessage(`Done. Your key is ${KEYS.anthropic}.`);
      },
    ]);
    const answer = await supervisor.ask('Fix whatever is broken.');
    expect(answer).toBe(`Done. Your key is ${REDACTED}.`);
    // The second context holds every tool result the model was given.
    expect(seen).toHaveLength(2);
    expect(seen[1]).toContain(REDACTED);
    assertNoKeys('model context', seen);
    assertNoKeys('notes', store.notes(50));
    assertNoKeys(
      'logs',
      logs.flatMap((spy) => spy.mock.calls),
    );
  });

  it('refuses a question that contains a key: nothing is sent or saved', async () => {
    const { store, faux, supervisor } = harness();
    faux.setResponses([fauxAssistantMessage('should not run')]);
    await expect(
      supervisor.ask(`Is this key valid? ${KEYS.openai}`),
    ).rejects.toThrow(/looks like an API key.*rotate it/);
    expect(faux.state.callCount).toBe(0);
    expect(store.notes(10)).toEqual([]);
  });

  it('cleans notes saved before redaction existed when they are read', () => {
    const { db, store } = harness();
    db.prepare(
      "INSERT INTO agent_notes (id, created_at, kind, finding_id, text, status) VALUES ('old', '2026-01-01T00:00:00Z', 'answer', NULL, ?, 'open')",
    ).run(`old answer ${KEYS.github}`);
    assertNoKeys('old notes', store.notes(10));
    assertNoKeys('old note', store.findNote('old'));
    expect(store.findNote('old')?.text).toBe(`old answer ${REDACTED}`);
  });
});

describe('evaluation reasons', () => {
  it('are redacted and bounded before they are stored', () => {
    const db = openDatabase(':memory:');
    cleanup.push(() => db.close());
    const evals = new SqliteEvals(db);
    const failed = evals.create('enforced', 'a'.repeat(64), null, false);
    evals.claimNext();
    evals.finish(failed.id, {
      status: 'failed',
      results: [
        { description: 'ok', passed: true, reason: null },
        {
          description: 'leaky',
          passed: false,
          reason: `Expected no output but got ${KEYS.xai} ${'x'.repeat(1000)}`,
        },
      ],
    });
    const results = evals.results(failed.id);
    assertNoKeys('eval results', results);
    expect(results[1]?.reason).toContain(REDACTED);
    expect(results[1]?.reason?.length).toBeLessThanOrEqual(300);
    expect(results[0]?.reason).toBeNull();

    const broken = evals.create('enforced', 'a'.repeat(64), null, false);
    evals.claimNext();
    evals.finish(broken.id, {
      status: 'error',
      error: `Provider rejected ${KEYS.google}`,
    });
    assertNoKeys('eval error', evals.recent(5));
  });
});

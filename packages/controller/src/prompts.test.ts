import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
} from '@earendil-works/pi-ai';
import { afterEach, describe, expect, it } from 'vitest';
import {
  DEFAULT_SYSTEM_PROMPT,
  ProjectService,
  PromptService,
  RunService,
  SessionService,
  SqliteEvals,
  SqliteProjects,
  SqliteSessions,
  SqliteTelemetry,
  diffLines,
  openDatabase,
  type AgentModels,
} from './index';
import { SqliteSettings } from './settings';
import { markerScanner, protection } from './test-support';

const directories: string[] = [];
const closers: (() => void)[] = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
  for (const directory of directories.splice(0))
    rmSync(directory, { recursive: true, force: true });
});

function setup() {
  const directory = mkdtempSync(join(tmpdir(), 'agentgate-prompts-'));
  directories.push(directory);
  const db = openDatabase(join(directory, 'agentgate.sqlite'));
  closers.push(() => db.open && db.close());
  const projectRepository = new SqliteProjects(db);
  const evals = new SqliteEvals(db);
  const prompts = new PromptService(db, projectRepository, (runId) =>
    evals.status(runId),
  );
  const projectId = new ProjectService(projectRepository).create({
    name: 'P',
  }).id;
  /** Records a finished required-suite run for a version, as the worker would. */
  const evaluate = (version: number, status: 'passed' | 'failed') => {
    const text = prompts.find(projectId, version)?.text ?? null;
    const run = evals.create('enforced', 'a'.repeat(64), null, false, text);
    prompts.recordEvaluation(projectId, version, run.id);
    evals.claimNext();
    evals.finish(run.id, {
      status,
      results: [
        { description: 'case', passed: status === 'passed', reason: null },
      ],
    });
    return run.id;
  };
  return { db, projectRepository, evals, prompts, projectId, evaluate };
}

describe('versioned system prompt', () => {
  it('starts on the built-in version 0', () => {
    const { prompts, projectId } = setup();
    expect(prompts.active(projectId)).toEqual({
      version: 0,
      text: DEFAULT_SYSTEM_PROMPT,
    });
    expect(prompts.history(projectId)).toEqual([
      expect.objectContaining({ version: 0, active: true }),
    ]);
  });

  it('numbers saved versions and keeps them inactive until activated', () => {
    const { prompts, projectId } = setup();
    expect(prompts.save(projectId, '  Answer in French.  ').version).toBe(1);
    expect(prompts.save(projectId, 'Answer in German.').version).toBe(2);
    expect(prompts.active(projectId).version).toBe(0);
    expect(prompts.history(projectId).map((v) => v.version)).toEqual([2, 1, 0]);
    expect(prompts.find(projectId, 1)?.text).toBe('Answer in French.');
  });

  it('refuses a prompt that contains a credential, and an empty one', () => {
    const { prompts, projectId } = setup();
    expect(() =>
      prompts.save(
        projectId,
        'Use api_key = sk-abcdefghijklmnopqrstuvwxyz123456',
      ),
    ).toThrow(/credential/);
    expect(() => prompts.save(projectId, '   ')).toThrow();
    expect(prompts.history(projectId)).toHaveLength(1);
  });

  it('cannot activate a version that has not passed the required suite', () => {
    const { prompts, projectId, evaluate } = setup();
    prompts.save(projectId, 'Version one.');
    expect(() => prompts.activate(projectId, 1)).toThrow(/has not passed/);
    evaluate(1, 'failed');
    expect(prompts.find(projectId, 1)?.evalStatus).toBe('failed');
    expect(() => prompts.activate(projectId, 1)).toThrow(/has not passed/);
    expect(prompts.active(projectId).version).toBe(0);
  });

  it('activates a passed version and rolls back to an earlier one', () => {
    const { prompts, projectId, evaluate } = setup();
    prompts.save(projectId, 'Version one.');
    prompts.save(projectId, 'Version two.');
    evaluate(1, 'passed');
    evaluate(2, 'passed');
    prompts.activate(projectId, 2);
    expect(prompts.active(projectId)).toEqual({
      version: 2,
      text: 'Version two.',
    });
    prompts.activate(projectId, 1);
    expect(prompts.active(projectId).version).toBe(1);
    prompts.activate(projectId, 0);
    expect(prompts.active(projectId).version).toBe(0);
    expect(() => prompts.activate(projectId, 9)).toThrow(/Unknown/);
  });

  it('records the candidate prompt on the evaluation run it was checked by', () => {
    const { prompts, evals, projectId } = setup();
    prompts.save(projectId, 'Checked text.');
    const run = evals.create(
      'enforced',
      'a'.repeat(64),
      null,
      false,
      'Checked text.',
    );
    expect(evals.claimNext()).toMatchObject({
      id: run.id,
      systemPrompt: 'Checked text.',
    });
  });
});

describe('prompt version on runs', () => {
  it('runs with the active prompt and records its version on the run and the trace', async () => {
    const { db, prompts, projectRepository, projectId, evaluate } = setup();
    prompts.save(projectId, 'Always answer in one word.');
    evaluate(1, 'passed');
    prompts.activate(projectId, 1);
    const faux = fauxProvider();
    const registry = createModels();
    registry.setProvider(faux.provider);
    let sent = '';
    faux.setResponses([fauxAssistantMessage('Yes.')]);
    const models: AgentModels = {
      open: async () => ({
        model: faux.getModel(),
        streamFn: (target, context, options) => {
          sent = JSON.stringify(context);
          return registry.streamSimple(target, context, options);
        },
        getApiKey: () => 'unused',
        describeError: (raw) => raw,
      }),
    };
    const repository = new SqliteSessions(db);
    const sessions = new SessionService(repository, projectRepository);
    const session = sessions.createSession({
      projectId,
      model: { provider: 'ollama', modelId: 'faux' },
    });
    const telemetry = new SqliteTelemetry(db, new SqliteSettings(db));
    const runs = new RunService(repository, models, {
      guard: protection(db, markerScanner()).guard,
      telemetry,
      prompts,
    });
    const run = runs.enqueue({ sessionId: session.id, prompt: 'Ready?' });
    await runs.idle();
    expect(sent).toContain('Always answer in one word.');
    expect(sent).not.toContain(DEFAULT_SYSTEM_PROMPT);
    expect(sessions.promptVersion(run.id)).toBe(1);
    const chat = telemetry
      .find(run.id)
      ?.spans.find((span) => span.name === 'gen_ai.chat');
    expect(chat?.attributes['agentgate.prompt_version']).toBe(1);
  });
});

describe('diffLines', () => {
  it('marks added, removed and unchanged lines in order', () => {
    expect(diffLines('a\nb\nc', 'a\nx\nc\nd')).toEqual([
      { kind: 'same', text: 'a' },
      { kind: 'removed', text: 'b' },
      { kind: 'added', text: 'x' },
      { kind: 'same', text: 'c' },
      { kind: 'added', text: 'd' },
    ]);
    expect(diffLines('same', 'same')).toEqual([{ kind: 'same', text: 'same' }]);
  });
});

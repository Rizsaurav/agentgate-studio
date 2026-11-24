import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import {
  EvalService,
  SqliteEvals,
  configurationIdentity,
  guardrailRates,
  openDatabase,
} from './index';

const cleanup: (() => void)[] = [];
afterEach(() => {
  for (const task of cleanup.splice(0)) task();
});

/** A repository with a CLI fixture, launched with the production process boundary. */
function fakeRepo(evalScript: string) {
  const root = mkdtempSync(join(tmpdir(), 'agentgate-evalrepo-'));
  mkdirSync(join(root, 'evals'));
  mkdirSync(join(root, 'scanner'));
  mkdirSync(join(root, 'node_modules', 'promptfoo', 'dist', 'src'), {
    recursive: true,
  });
  mkdirSync(join(root, 'node_modules', 'tsx', 'dist'), { recursive: true });
  writeFileSync(join(root, 'node_modules', 'tsx', 'dist', 'loader.mjs'), '');
  writeFileSync(
    join(root, 'node_modules', 'promptfoo', 'dist', 'src', 'entrypoint.js'),
    evalScript,
  );
  writeFileSync(
    join(root, 'evals', 'promptfooconfig.yaml'),
    'description: x\n',
  );
  writeFileSync(
    join(root, 'scanner', 'requirements.txt'),
    'llm-guard==0.0.0\n',
  );
  writeFileSync(
    join(root, 'package.json'),
    JSON.stringify({ scripts: { eval: evalScript, 'eval:weak': evalScript } }),
  );
  const dbDirectory = mkdtempSync(join(tmpdir(), 'agentgate-evaldb-'));
  const db = openDatabase(join(dbDirectory, 'a.sqlite'));
  cleanup.push(() => {
    if (db.open) db.close();
    rmSync(root, { recursive: true, force: true });
    rmSync(dbDirectory, { recursive: true, force: true });
  });
  return { root, db, repository: new SqliteEvals(db) };
}
// CLI fixture source; no shell interpolation is involved.
const node = (code: string) => code;
const WRITES_RESULT = (exit: number) =>
  node(
    `const o=process.argv[process.argv.indexOf('-o')+1];require('fs').writeFileSync(o,JSON.stringify({results:{results:[{success:true,testCase:{description:'ok case'}},{success:false,testCase:{description:'bad case'},gradingResult:{reason:'r',componentResults:[{pass:false,reason:'Custom function returned false\\nsecret detail'}]}}]}}));process.exit(${exit})`,
  );

describe('evaluation worker', () => {
  it('persists a failing run with its configuration identity and per-case results', async () => {
    const { root, repository } = fakeRepo(WRITES_RESULT(100));
    const service = new EvalService(repository, root);
    const run = await service.enqueue('weak-demo');
    expect(run.status).toBe('queued');
    await service.idle();
    const [stored] = service.recent();
    expect(stored).toMatchObject({
      id: run.id,
      profile: 'weak-demo',
      status: 'failed',
      total: 2,
      passed: 1,
      failed: 1,
      error: null,
    });
    expect(stored?.configHash).toBe(run.configHash);
    expect(service.results(run.id)).toEqual([
      { description: 'ok case', passed: true, reason: null, measures: null },
      {
        description: 'bad case',
        passed: false,
        reason: 'Custom function returned false',
        measures: null,
      },
    ]);
  });

  it('marks a clean exit as passed', async () => {
    const script = WRITES_RESULT(0).replace('success:false', 'success:true');
    const { root, repository } = fakeRepo(script);
    const service = new EvalService(repository, root);
    await service.enqueue('enforced');
    await service.idle();
    expect(service.recent()[0]).toMatchObject({ status: 'passed', failed: 0 });
  });

  it('records infrastructure failures, timeouts, and missing output as errors, not failures', async () => {
    const cases: [string, number | undefined, string][] = [
      [node('process.exit(2)'), undefined, 'exited with code 2'],
      [node('process.exit(0)'), undefined, 'no result file'],
      [node('setTimeout(()=>{},60000)'), 300, 'timed out'],
    ];
    for (const [script, timeout, message] of cases) {
      const { root, repository } = fakeRepo(script);
      const service = new EvalService(repository, root, timeout);
      await service.enqueue('enforced');
      await service.idle();
      expect(service.recent()[0]).toMatchObject({ status: 'error' });
      expect(service.recent()[0]?.error).toContain(message);
    }
  });

  it('does not pass secrets from the parent environment to the suite', async () => {
    const { root, repository } = fakeRepo(
      node(
        `if(process.env.OPENAI_API_KEY||process.env.SECRET_TOKEN)process.exit(3);const o=process.argv[process.argv.indexOf('-o')+1];require('fs').writeFileSync(o,JSON.stringify({results:{results:[{success:true,testCase:{description:'env clean'}}]}}))`,
      ),
    );
    const service = new EvalService(repository, root, undefined, {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      OPENAI_API_KEY: 'sk-should-not-leak-000000',
      SECRET_TOKEN: 'x',
    });
    await service.enqueue('enforced');
    await service.idle();
    expect(service.recent()[0]?.status).toBe('passed');
  });

  it('refuses unknown profiles and an installation without the suite; recovers interrupted runs', async () => {
    const { root, db, repository } = fakeRepo(node('process.exit(0)'));
    const service = new EvalService(repository, root);
    await expect(service.enqueue('anything-else')).rejects.toThrow();
    const stale = repository.create('enforced', 'a'.repeat(64), null, false);
    repository.claimNext();
    service.start();
    await service.idle();
    expect(service.recent().find((r) => r.id === stale.id)).toMatchObject({
      status: 'error',
      error: 'Interrupted by an application restart.',
    });
    expect(
      new EvalService(new SqliteEvals(db), join(root, 'missing')).available,
    ).toBe(false);
  });

  it('changes the configuration hash when any evaluated file changes', async () => {
    const { root } = fakeRepo(node('process.exit(0)'));
    const before = await configurationIdentity(root);
    expect(before.configHash).toMatch(/^[0-9a-f]{64}$/);
    expect((await configurationIdentity(root)).configHash).toBe(
      before.configHash,
    );
    writeFileSync(
      join(root, 'evals', 'promptfooconfig.yaml'),
      'description: changed\n',
    );
    expect((await configurationIdentity(root)).configHash).not.toBe(
      before.configHash,
    );
  });
});

// Runs the real Promptfoo suite through the worker. Needs the scanner service.
describe.runIf(process.env.AGENTGATE_SCANNER_URL)(
  'live Promptfoo suite (integration)',
  () => {
    it('passes with protections enforced and fails the security cases when deliberately weakened', async () => {
      const root = join(__dirname, '..', '..', '..');
      const directory = mkdtempSync(join(tmpdir(), 'agentgate-evaldb-'));
      const db = openDatabase(join(directory, 'a.sqlite'));
      cleanup.push(() => {
        db.close();
        rmSync(directory, { recursive: true, force: true });
      });
      const service = new EvalService(new SqliteEvals(db), root);
      const weak = await service.enqueue('weak-demo');
      const enforced = await service.enqueue('enforced');
      await service.idle();
      const byId = new Map(service.recent().map((r) => [r.id, r]));
      expect(byId.get(enforced.id)).toMatchObject({
        status: 'passed',
        failed: 0,
      });
      expect(byId.get(weak.id)?.status).toBe('failed');
      const failures = service.results(weak.id).filter((r) => !r.passed);
      expect(failures.length).toBeGreaterThan(0);
      expect(
        failures.every((r) => r.description.startsWith('security /')),
      ).toBe(true);
      expect(byId.get(weak.id)?.configHash).toBe(
        byId.get(enforced.id)?.configHash,
      );
    }, 300_000);
  },
);

/** A suite result with tagged cases, as Promptfoo writes it (metadata is kept on testCase). */
const TAGGED = (cases: object[]) =>
  node(
    `const o=process.argv[process.argv.indexOf('-o')+1];require('fs').writeFileSync(o,JSON.stringify({results:{results:${JSON.stringify(cases)}}}));process.exit(100)`,
  );
const tagged = (
  description: string,
  success: boolean,
  measures?: string,
): object => ({
  success,
  testCase: {
    description,
    ...(measures ? { metadata: { measures, other: 'kept out' } } : {}),
  },
  ...(success ? {} : { gradingResult: { reason: 'failed' } }),
});

describe('false-positive and detection rates', () => {
  it('stores what each case measures and reports both rates for the run', async () => {
    const { root, repository } = fakeRepo(
      TAGGED([
        tagged('benign rules', true, 'false-positive'),
        tagged('benign runbook', false, 'false-positive'),
        tagged('direct injection', true, 'detection'),
        tagged('poisoned document', true, 'detection'),
        tagged('injection in a manual', false, 'detection'),
        tagged('path outside the folder', true),
      ]),
    );
    const service = new EvalService(repository, root);
    const run = await service.enqueue('enforced');
    await service.idle();
    const results = service.results(run.id);
    expect(results.map((r) => r.measures)).toEqual([
      'false-positive',
      'false-positive',
      'detection',
      'detection',
      'detection',
      null,
    ]);
    expect(guardrailRates(results)).toEqual({
      falsePositives: { count: 1, total: 2 },
      detections: { count: 2, total: 3 },
    });
  });

  it('turns a misspelt measure into an error instead of dropping the case', async () => {
    const { root, repository } = fakeRepo(
      TAGGED([tagged('typo', true, 'detecton')]),
    );
    const service = new EvalService(repository, root);
    await service.enqueue('enforced');
    await service.idle();
    expect(service.recent()[0]?.status).toBe('error');
  });

  it('has no rate without tagged cases, and a rate of zero when nothing is flagged', () => {
    expect(
      guardrailRates([{ description: 'x', passed: true, reason: null }]),
    ).toEqual({ falsePositives: null, detections: null });
    expect(
      guardrailRates([
        {
          description: 'benign',
          passed: true,
          reason: null,
          measures: 'false-positive',
        },
      ]),
    ).toEqual({ falsePositives: { count: 0, total: 1 }, detections: null });
  });

  it('every tagged case in the real suite is a known measure, with both kinds present', async () => {
    const { readFileSync } = await import('node:fs');
    const suite = readFileSync(
      join(import.meta.dirname, '../../../evals/tests/cases.yaml'),
      'utf8',
    );
    const measures = [...suite.matchAll(/^\s+measures:\s*(\S+)\s*$/gm)].map(
      (match) => match[1],
    );
    expect(new Set(measures)).toEqual(new Set(['false-positive', 'detection']));
  });
});

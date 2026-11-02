import { describe, expect, it } from 'vitest';
import { Watchdog, assess, type Probe } from './watchdog';

const ok = (name: string) => ({ name, ok: true, detail: 'ok', fix: '' });
const down = (name: string) => ({
  name,
  ok: false,
  detail: 'down',
  fix: 'fix',
});
const healthy: Probe = {
  services: [
    ok('Ollama (local models)'),
    ok('Security scanner (LLM Guard)'),
    ok('Reference folder'),
  ],
  installedModels: 2,
  lastEval: { id: 'e1', status: 'passed', passed: 12, total: 12 },
  blockedLast24h: 0,
  pull: null,
};

describe('watchdog rules', () => {
  it('reports nothing when everything is healthy', () => {
    expect(assess(healthy)).toEqual([]);
  });
  it('knows a safe fix for each offline service and needs no model for it', () => {
    const findings = assess({
      ...healthy,
      services: [
        down('Ollama (local models)'),
        down('Security scanner (LLM Guard)'),
        ok('Reference folder'),
      ],
    });
    expect(findings.map((f) => [f.id, f.remedy, f.needsAgent])).toEqual([
      ['ollama-down', 'start-ollama', false],
      ['scanner-down', 'start-scanner', false],
    ]);
  });
  it('sends a failed evaluation and a failed download to the assistant, once per run', () => {
    const findings = assess({
      ...healthy,
      lastEval: { id: 'e2', status: 'failed', passed: 9, total: 12 },
      pull: { model: 'x:1b', status: 'failed' },
    });
    expect(findings.filter((f) => f.needsAgent).map((f) => f.id)).toEqual([
      'pull-failed:x:1b',
      'eval-failed:e2',
    ]);
  });
  it('mentions blocked activity and a missing local model without alarm', () => {
    const findings = assess({
      ...healthy,
      installedModels: 0,
      blockedLast24h: 3,
    });
    expect(findings.map((f) => [f.id, f.severity])).toEqual([
      ['no-local-model', 'info'],
      ['blocked-activity', 'info'],
    ]);
  });
});

describe('watchdog fixes', () => {
  it('applies a safe fix, records it, and stops retrying after a few attempts', async () => {
    let clock = 0;
    const fixed: string[] = [];
    const actions: string[] = [];
    const watchdog = new Watchdog({
      probe: async () => ({
        ...healthy,
        services: [
          down('Ollama (local models)'),
          ok('Security scanner (LLM Guard)'),
          ok('Reference folder'),
        ],
      }),
      remedies: {
        'start-ollama': async () => {
          fixed.push('ollama');
          throw new Error('not installed');
        },
        'start-scanner': async () => 'unused',
      },
      onAction: (_finding, outcome) => actions.push(outcome),
      now: () => clock,
    });
    for (let i = 0; i < 5; i += 1) await watchdog.check();
    expect(fixed).toHaveLength(3);
    expect(actions[0]).toBe('Could not fix it: not installed');
    clock += 11 * 60_000;
    await watchdog.check();
    expect(fixed).toHaveLength(4);
  });
  it('hands findings that need judgement to the assistant and applies no fix for them', async () => {
    const asked: string[] = [];
    const watchdog = new Watchdog({
      probe: async () => ({
        ...healthy,
        lastEval: { id: 'e9', status: 'error', passed: 0, total: 0 },
      }),
      remedies: {
        'start-ollama': async () => 'x',
        'start-scanner': async () => 'x',
      },
      onNeedsAgent: (finding) => asked.push(finding.id),
    });
    await watchdog.check();
    expect(asked).toEqual(['eval-error:e9']);
    expect(watchdog.current()).toHaveLength(1);
  });
});

import { describe, expect, it } from 'vitest';
import {
  formatDuration,
  slowestSpan,
  summarizeTraces,
  usage,
  type Trace,
} from './index';

function trace(
  runId: string,
  startedAt: string,
  durationMs: number,
  status: Trace['status'],
  extra: Partial<Trace> = {},
): Trace {
  return {
    runId,
    projectId: 'p',
    model: 'ollama/m',
    startedAt,
    durationMs,
    status,
    rule: null,
    spans: [
      {
        name: 'agentgate.input_check',
        startMs: 0,
        durationMs: 40,
        status: 'ok',
        attributes: { 'agentgate.scanner.score': 0.01 },
      },
      {
        name: 'gen_ai.chat',
        startMs: 50,
        durationMs: durationMs - 60,
        status: 'ok',
        attributes: {
          'gen_ai.usage.input_tokens': 100,
          'gen_ai.usage.output_tokens': 20,
          'agentgate.cost_usd': 0.002,
        },
      },
    ],
    ...extra,
  };
}

describe('trace summaries', () => {
  it('names the stage that took the time and totals the usage', () => {
    const t = trace('a', '2026-11-17T10:00:00Z', 2000, 'completed');
    expect(slowestSpan(t)?.name).toBe('gen_ai.chat');
    expect(usage(t)).toEqual({
      inputTokens: 100,
      outputTokens: 20,
      costUsd: 0.002,
    });
    expect(usage({ ...t, spans: [] })).toEqual({
      inputTokens: null,
      outputTokens: null,
      costUsd: null,
    });
  });

  it('lists the slowest runs, the rules that blocked most, and usage per day', () => {
    const blocked = (id: string, rule: string, day: string) =>
      trace(id, `${day}T09:00:00Z`, 100, 'blocked', {
        rule,
        spans: [
          {
            name: 'agentgate.input_check',
            startMs: 0,
            durationMs: 90,
            status: 'blocked',
            attributes: { 'agentgate.rule': rule },
          },
        ],
      });
    const summary = summarizeTraces(
      [
        trace('fast', '2026-11-17T10:00:00Z', 500, 'completed'),
        trace('slow', '2026-11-16T10:00:00Z', 9000, 'completed'),
        blocked('b1', 'prompt-injection', '2026-11-17'),
        blocked('b2', 'prompt-injection', '2026-11-16'),
        blocked('b3', 'secret-in-input', '2026-11-17'),
      ],
      2,
    );
    expect(summary.runs).toBe(5);
    expect(summary.slowest).toEqual([
      {
        runId: 'slow',
        durationMs: 9000,
        status: 'completed',
        stage: 'Generation',
      },
      {
        runId: 'fast',
        durationMs: 500,
        status: 'completed',
        stage: 'Generation',
      },
    ]);
    expect(summary.blockedRules).toEqual([
      { rule: 'prompt-injection', count: 2 },
      { rule: 'secret-in-input', count: 1 },
    ]);
    expect(summary.perDay.map((d) => [d.day, d.runs, d.inputTokens])).toEqual([
      ['2026-11-17', 3, 100],
      ['2026-11-16', 2, 100],
    ]);
    expect(summary.perDay[0]?.costUsd).toBeCloseTo(0.002);
  });

  it('formats durations for people', () => {
    expect(formatDuration(850)).toBe('850 ms');
    expect(formatDuration(1240)).toBe('1.2 s');
    expect(formatDuration(125_000)).toBe('2 min 5 s');
  });
});

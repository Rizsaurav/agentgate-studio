import type { Span, SpanName, Trace } from './telemetry';

/** Plain names for the pipeline stages, shared by the run and project views (#11). */
export const SPAN_LABELS: Record<SpanName, string> = {
  'agentgate.input_check': 'Task check',
  'agentgate.retrieval': 'Retrieval',
  'agentgate.passage_screening': 'Passage screening',
  'gen_ai.chat': 'Generation',
  'agentgate.output_check': 'Answer check',
  'agentgate.delivery': 'Delivery',
};

/** The stage that took the most time, which is what a user asks first about a slow run. */
export function slowestSpan(trace: Trace): Span | undefined {
  return trace.spans.reduce<Span | undefined>(
    (slowest, span) =>
      !slowest || span.durationMs > slowest.durationMs ? span : slowest,
    undefined,
  );
}

/** Token and cost totals of one run, from its generation spans. */
export function usage(trace: Trace): {
  inputTokens: number | null;
  outputTokens: number | null;
  costUsd: number | null;
} {
  const chats = trace.spans.filter((span) => span.name === 'gen_ai.chat');
  const sum = (
    key:
      | 'gen_ai.usage.input_tokens'
      | 'gen_ai.usage.output_tokens'
      | 'agentgate.cost_usd',
  ) => {
    const values = chats.flatMap((span) => span.attributes[key] ?? []);
    return values.length ? values.reduce((a, b) => a + b, 0) : null;
  };
  return {
    inputTokens: sum('gen_ai.usage.input_tokens'),
    outputTokens: sum('gen_ai.usage.output_tokens'),
    costUsd: sum('agentgate.cost_usd'),
  };
}

export type ProjectTraceSummary = {
  runs: number;
  slowest: {
    runId: string;
    durationMs: number;
    status: Trace['status'];
    stage: string | null;
  }[];
  blockedRules: { rule: string; count: number }[];
  perDay: {
    day: string;
    runs: number;
    inputTokens: number;
    outputTokens: number;
    costUsd: number;
  }[];
};

/** Slowest runs, the rules that blocked most, and tokens and cost per day, newest day first. */
export function summarizeTraces(
  traces: Trace[],
  slowest = 5,
): ProjectTraceSummary {
  const rules = new Map<string, number>();
  const days = new Map<string, ProjectTraceSummary['perDay'][number]>();
  for (const trace of traces) {
    if (trace.status === 'blocked' && trace.rule)
      rules.set(trace.rule, (rules.get(trace.rule) ?? 0) + 1);
    const day = trace.startedAt.slice(0, 10);
    const entry = days.get(day) ?? {
      day,
      runs: 0,
      inputTokens: 0,
      outputTokens: 0,
      costUsd: 0,
    };
    const used = usage(trace);
    entry.runs += 1;
    entry.inputTokens += used.inputTokens ?? 0;
    entry.outputTokens += used.outputTokens ?? 0;
    entry.costUsd += used.costUsd ?? 0;
    days.set(day, entry);
  }
  return {
    runs: traces.length,
    slowest: traces
      .toSorted((a, b) => b.durationMs - a.durationMs)
      .slice(0, slowest)
      .map((trace) => {
        const span = slowestSpan(trace);
        return {
          runId: trace.runId,
          durationMs: trace.durationMs,
          status: trace.status,
          stage: span ? SPAN_LABELS[span.name] : null,
        };
      }),
    blockedRules: [...rules]
      .map(([rule, count]) => ({ rule, count }))
      .toSorted((a, b) => b.count - a.count || a.rule.localeCompare(b.rule)),
    perDay: [...days.values()].toSorted((a, b) => b.day.localeCompare(a.day)),
  };
}

/** Milliseconds as people read them: "850 ms", "1.2 s", "2 min 5 s". */
export function formatDuration(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)} ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)} s`;
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)} min ${seconds % 60} s`;
}

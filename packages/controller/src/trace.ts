import { z } from 'zod';
import type { Run, RunEvent } from './sessions';
import { securityEventSchema, type SecurityEvent } from './security';

/**
 * A security event without its stored evidence. The trace UI must never
 * receive evidence, so a later API route or client component cannot leak it
 * by rendering whatever the trace carries.
 */
export const securityEventSummarySchema = securityEventSchema.omit({
  evidence: true,
});
export type SecurityEventSummary = z.infer<typeof securityEventSummarySchema>;

/** Security events with evidence stripped, for trace output. */
export function toSecurityEventSummaries(
  events: SecurityEvent[],
): SecurityEventSummary[] {
  return events.map(({ evidence: _evidence, ...rest }) => rest);
}

export const runTraceStageSchema = z
  .object({
    key: z.enum(['task', 'retrieval', 'generation', 'output']),
    label: z.string(),
    status: z.enum([
      'done',
      'blocked',
      'failed',
      'not-run',
      'pending',
      'cancelled',
    ]),
    detail: z.string(),
  })
  .strict();
export type RunTraceStage = z.infer<typeof runTraceStageSchema>;

/** The one definition of a retrieved source; the type is inferred from it. */
export const traceSourceSchema = z
  .object({
    documentId: z.uuid(),
    title: z.string(),
    seq: z.number().int(),
  })
  .strict();
export type TraceSource = z.infer<typeof traceSourceSchema>;

/** Sources recorded in 'sources' run events. Throws on a malformed event. */
export function sourcesFromEvents(events: RunEvent[]): TraceSource[] {
  return events
    .filter((event) => event.type === 'sources')
    .flatMap((event) =>
      z.array(traceSourceSchema).parse(JSON.parse(event.text)),
    );
}

/** Document ids recorded in a 'screened' run event. Throws on malformed data. */
export function screenedDocumentIds(events: RunEvent[]): string[] {
  const event = events.find((e) => e.type === 'screened');
  if (!event) return [];
  return z.array(z.uuid()).parse(JSON.parse(event.text));
}

function stage(
  key: RunTraceStage['key'],
  label: string,
  status: RunTraceStage['status'],
  detail: string,
): RunTraceStage {
  return { key, label, status, detail };
}

/**
 * Build the four trace stages from already-stored data only.
 *
 * The runner's order is fixed (see runner.ts): input check, retrieval
 * screening, a 'screened' event, model opening, then a 'started' event,
 * generation, output check, and a 'completed' event. So:
 * - a retrieval or output block proves the input check passed;
 * - an output block proves retrieval and generation happened;
 * - a 'screened' event proves the input check and retrieval finished,
 *   even when model opening then fails and no 'started' event exists;
 * - a 'started' event proves the same, and a 'completed' event proves
 *   generation and the output check both finished.
 * Anything not provable from a stored event is 'not-run' or 'pending',
 * never claimed as done. In particular, a retrieval security event with
 * outcome 'quarantined' does not block a run: screenPassages withholds
 * that document and keeps the rest, so it is shown in the event list
 * but does not turn the retrieval stage red. Only outcome 'blocked'
 * blocks a stage.
 */
export function buildTraceStages(input: {
  run: Run;
  started: boolean;
  screened: boolean;
  screenedDocumentIds: string[];
  hasCompleted: boolean;
  sources: TraceSource[];
  securityEvents: SecurityEvent[];
}): RunTraceStage[] {
  const {
    run,
    started,
    screened,
    screenedDocumentIds: screenedIds,
    hasCompleted,
    sources,
    securityEvents,
  } = input;
  const isTerminal =
    run.status === 'completed' ||
    run.status === 'failed' ||
    run.status === 'cancelled' ||
    run.status === 'blocked';
  const distinctDocuments = new Set(sources.map((s) => s.documentId)).size;
  const blockedAt = (stageName: SecurityEvent['stage']) =>
    securityEvents.find(
      (event) => event.stage === stageName && event.outcome === 'blocked',
    );
  const inputBlocked = blockedAt('input');
  const retrievalBlocked = blockedAt('retrieval');
  const outputBlocked = blockedAt('output');
  const quarantinedDocumentIds = new Set(
    securityEvents
      .filter(
        (event) =>
          event.stage === 'retrieval' &&
          event.outcome === 'quarantined' &&
          event.documentId !== null,
      )
      .map((event) => event.documentId as string),
  );
  const quarantinedCount = quarantinedDocumentIds.size;
  const quarantinedNote =
    quarantinedCount > 0
      ? ` ${quarantinedCount} document${quarantinedCount === 1 ? '' : 's'} quarantined during retrieval and withheld.`
      : '';

  const taskStage: RunTraceStage = inputBlocked
    ? stage(
        'task',
        'Task check',
        'blocked',
        `${inputBlocked.rule}: ${inputBlocked.detail}`,
      )
    : started || screened || retrievalBlocked || outputBlocked
      ? stage('task', 'Task check', 'done', 'Task passed the input check.')
      : run.status === 'queued' || run.status === 'running'
        ? stage(
            'task',
            'Task check',
            'pending',
            'Task check has not finished yet.',
          )
        : run.status === 'blocked'
          ? stage(
              'task',
              'Task check',
              'blocked',
              run.error ?? 'Run was blocked.',
            )
          : stage('task', 'Task check', 'not-run', 'Task check did not run.');

  const retrievalStage: RunTraceStage = retrievalBlocked
    ? stage(
        'retrieval',
        'Retrieval',
        'blocked',
        `${retrievalBlocked.rule}: ${retrievalBlocked.detail}`,
      )
    : inputBlocked
      ? stage(
          'retrieval',
          'Retrieval',
          'not-run',
          'Retrieval did not run because the run was blocked at the task check.',
        )
      : started || screened || outputBlocked
        ? stage(
            'retrieval',
            'Retrieval',
            'done',
            distinctDocuments > 0
              ? `${distinctDocuments} document${distinctDocuments === 1 ? '' : 's'} retrieved.${quarantinedNote}`
              : screenedIds.length > 0
                ? `${new Set(screenedIds).size} document${new Set(screenedIds).size === 1 ? '' : 's'} retrieved.${quarantinedNote}`
                : `No documents were retrieved.${quarantinedNote}`,
          )
        : run.status === 'running'
          ? stage(
              'retrieval',
              'Retrieval',
              'pending',
              'Retrieval has not finished yet.',
            )
          : stage(
              'retrieval',
              'Retrieval',
              'not-run',
              isTerminal
                ? 'Retrieval did not run.'
                : 'Retrieval has not run yet.',
            );

  // Exhaustive over RunStatus: adding a status without a case here
  // is a type error in the default branch.
  const generationStage: RunTraceStage = ((): RunTraceStage => {
    switch (run.status) {
      case 'completed':
        return stage(
          'generation',
          'Generation',
          'done',
          'Answer was generated.',
        );
      case 'failed':
        return hasCompleted
          ? stage(
              'generation',
              'Generation',
              'done',
              'Answer was generated, but the run failed while saving it.',
            )
          : started
            ? stage(
                'generation',
                'Generation',
                'failed',
                run.error ?? 'Generation failed.',
              )
            : stage(
                'generation',
                'Generation',
                'not-run',
                'Generation did not start.',
              );
      case 'cancelled':
        return started
          ? stage(
              'generation',
              'Generation',
              'cancelled',
              'Run was cancelled during generation.',
            )
          : stage(
              'generation',
              'Generation',
              'not-run',
              'Run was cancelled before generation started.',
            );
      case 'blocked':
        return outputBlocked || started
          ? stage(
              'generation',
              'Generation',
              'done',
              'Answer was generated, then blocked by the answer check.',
            )
          : stage(
              'generation',
              'Generation',
              'not-run',
              'Generation did not start because the run was blocked.',
            );
      case 'queued':
        return stage(
          'generation',
          'Generation',
          'pending',
          'Generation is queued.',
        );
      case 'running':
        return stage(
          'generation',
          'Generation',
          'pending',
          started
            ? 'Generation is in progress.'
            : 'Generation has not started yet.',
        );
      default: {
        const neverStatus: never = run.status;
        throw new Error(`Unknown run status: ${String(neverStatus)}`);
      }
    }
  })();

  const outputStage: RunTraceStage = outputBlocked
    ? stage(
        'output',
        'Answer check',
        'blocked',
        `${outputBlocked.rule}: ${outputBlocked.detail}`,
      )
    : run.status === 'completed' || (run.status === 'failed' && hasCompleted)
      ? stage(
          'output',
          'Answer check',
          'done',
          run.status === 'failed'
            ? 'Answer passed the output check, but the run failed while saving it.'
            : 'Answer passed the output check and was delivered.',
        )
      : run.status === 'blocked' && started
        ? stage(
            'output',
            'Answer check',
            'blocked',
            run.error ?? 'Run was blocked.',
          )
        : stage(
            'output',
            'Answer check',
            'not-run',
            isTerminal
              ? 'Answer check did not run.'
              : 'Answer check has not run yet.',
          );

  return [taskStage, retrievalStage, generationStage, outputStage];
}

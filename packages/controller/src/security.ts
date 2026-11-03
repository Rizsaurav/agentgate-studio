import { randomUUID } from 'node:crypto';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import type { Passage } from './documents';
import {
  detectDisallowedOperation,
  detectExfiltrationLink,
  detectSecrets,
  safeExcerpt,
} from './policy';
import {
  ScannerUnavailableError,
  type InjectionScanner,
  type ScanVerdict,
} from './scanner';

export const securityEventSchema = z
  .object({
    id: z.uuid(),
    projectId: z.uuid(),
    runId: z.uuid().nullable(),
    documentId: z.uuid().nullable(),
    stage: z.enum(['input', 'ingestion', 'retrieval', 'output']),
    rule: z.string().min(1),
    source: z.string().min(1),
    outcome: z.enum(['blocked', 'quarantined', 'excluded', 'released']),
    detail: z.string().min(1),
    evidence: z.string().nullable(),
    score: z.number().nullable(),
    createdAt: z.iso.datetime(),
  })
  .strict();
export type SecurityEvent = z.infer<typeof securityEventSchema>;
export type NewSecurityEvent = Omit<SecurityEvent, 'id' | 'createdAt'>;

export interface SecurityEventRepository {
  record(event: NewSecurityEvent): void;
  recent(limit: number): SecurityEvent[];
  forRun(runId: string): SecurityEvent[];
}

const COLUMNS =
  'id, project_id AS projectId, run_id AS runId, document_id AS documentId, stage, rule, source, outcome, detail, evidence, score, created_at AS createdAt';
export class SqliteSecurityEvents implements SecurityEventRepository {
  constructor(private readonly db: Database.Database) {}
  record(event: NewSecurityEvent): void {
    const stored = securityEventSchema.parse({
      ...event,
      id: randomUUID(),
      createdAt: new Date().toISOString(),
    });
    this.db
      .prepare(
        `INSERT INTO security_events (id, project_id, run_id, document_id, stage, rule, source, outcome, detail, evidence, score, created_at)
         VALUES (@id, @projectId, @runId, @documentId, @stage, @rule, @source, @outcome, @detail, @evidence, @score, @createdAt)`,
      )
      .run(stored);
  }
  recent(limit: number): SecurityEvent[] {
    return z
      .array(securityEventSchema)
      .parse(
        this.db
          .prepare(
            `SELECT ${COLUMNS} FROM security_events ORDER BY created_at DESC, id LIMIT ?`,
          )
          .all(limit),
      );
  }
  forRun(runId: string): SecurityEvent[] {
    return z
      .array(securityEventSchema)
      .parse(
        this.db
          .prepare(
            `SELECT ${COLUMNS} FROM security_events WHERE run_id = ? ORDER BY created_at, id`,
          )
          .all(runId),
      );
  }
}

export type Blocked = { allowed: false; rule: string; reason: string };
export type Decision = { allowed: true } | Blocked;
export type RunContext = { projectId: string; runId: string };
export type PassageScreening = { passages: Passage[]; blocked: Blocked | null };

/** What the run loop needs from the protection pipeline. */
export interface RunGuard {
  checkInput(ctx: RunContext, prompt: string): Promise<Decision>;
  screenPassages(
    ctx: RunContext,
    passages: Passage[],
  ): Promise<PassageScreening>;
  inspectOutput(ctx: RunContext, text: string): Decision;
}

const UNAVAILABLE: Blocked = {
  allowed: false,
  rule: 'scanner-unavailable',
  reason:
    'The security scanner is unavailable, so the content was not delivered.',
};
const BATCH = 32;

/**
 * Deterministic restrictions plus LLM Guard prompt-injection scanning. Every
 * stage fails closed, and every blocking decision is recorded with its rule,
 * source, outcome, and a secret-free excerpt. This reduces risk; it does not
 * guarantee protection from all attacks.
 */
export class ProtectionPipeline implements RunGuard {
  constructor(
    private readonly scanner: InjectionScanner,
    private readonly events: SecurityEventRepository,
    private readonly withhold: (
      projectId: string,
      documentId: string,
      seqs: number[],
    ) => void,
  ) {}

  async checkInput(ctx: RunContext, prompt: string): Promise<Decision> {
    const stage = 'input';
    const source = 'user input';
    if (detectSecrets(prompt).length > 0)
      return this.block(ctx, {
        stage,
        source,
        rule: 'secret-in-input',
        reason: 'The task contains what looks like a credential.',
        evidence: null,
      });
    const operation = detectDisallowedOperation(prompt);
    if (operation)
      return this.block(ctx, {
        stage,
        source,
        rule: operation,
        reason: 'The task asks for a disallowed operation.',
        evidence: safeExcerpt(prompt),
      });
    const verdict = await this.scanOne(ctx, stage, source, prompt);
    if (verdict === 'unavailable') return UNAVAILABLE;
    if (verdict?.injection)
      return this.block(ctx, {
        stage,
        source,
        rule: 'prompt-injection',
        reason: 'The task looks like a prompt-injection attempt.',
        evidence: safeExcerpt(prompt),
        score: verdict.score,
      });
    return { allowed: true };
  }

  async screenPassages(
    ctx: RunContext,
    passages: Passage[],
  ): Promise<PassageScreening> {
    // Passages the user released after review are not scanned again; everything else is.
    const unreviewed = passages.filter((passage) => !passage.released);
    if (unreviewed.length === 0) return { passages, blocked: null };
    let verdicts: ScanVerdict[];
    try {
      verdicts = await this.scanner.scan(
        unreviewed.map((passage) => passage.text),
      );
    } catch (error) {
      this.requireScannerError(error);
      return {
        passages: [],
        blocked: this.block(ctx, {
          stage: 'retrieval',
          source: 'retrieved documents',
          rule: UNAVAILABLE.rule,
          reason: UNAVAILABLE.reason,
          evidence: null,
        }),
      };
    }
    const flagged = new Set<Passage>();
    unreviewed.forEach((passage, index) => {
      const verdict = verdicts[index];
      if (!verdict?.injection) return;
      flagged.add(passage);
      this.withhold(ctx.projectId, passage.documentId, [passage.seq]);
      this.events.record({
        projectId: ctx.projectId,
        runId: ctx.runId,
        documentId: passage.documentId,
        stage: 'retrieval',
        rule: 'prompt-injection',
        source: `${passage.title} (${passage.path})`,
        outcome: 'excluded',
        detail:
          'A retrieved passage looked like a prompt-injection attempt and was withheld from the model.',
        evidence: safeExcerpt(passage.text),
        score: verdict.score,
      });
    });
    return {
      passages: passages.filter((passage) => !flagged.has(passage)),
      blocked: null,
    };
  }

  /**
   * Scans every passage of a document at ingestion and returns the ones to withhold. Only flagged
   * passages are withheld, so one suspect paragraph does not discard a whole manual; each is
   * recorded for review. Throws if the document could not be scanned.
   */
  async screenDocument(
    ctx: { projectId: string; documentId: string; title: string; path: string },
    chunks: string[],
  ): Promise<{ withheld: number[] }> {
    const source = `${ctx.title} (${ctx.path})`;
    const withheld: number[] = [];
    try {
      for (let start = 0; start < chunks.length; start += BATCH) {
        const batch = chunks.slice(start, start + BATCH);
        const verdicts = await this.scanner.scan(batch);
        verdicts.forEach((verdict, index) => {
          if (!verdict.injection) return;
          withheld.push(start + index);
          this.events.record({
            projectId: ctx.projectId,
            runId: null,
            documentId: ctx.documentId,
            stage: 'ingestion',
            rule: 'prompt-injection',
            source,
            outcome: 'excluded',
            detail:
              'A passage contains instructions aimed at the model and was withheld for review.',
            evidence: safeExcerpt(batch[index] ?? ''),
            score: verdict.score,
          });
        });
      }
    } catch (error) {
      this.requireScannerError(error);
      this.events.record({
        projectId: ctx.projectId,
        runId: null,
        documentId: null,
        stage: 'ingestion',
        rule: UNAVAILABLE.rule,
        source,
        outcome: 'blocked',
        detail: UNAVAILABLE.reason,
        evidence: null,
        score: null,
      });
      throw error;
    }
    return { withheld };
  }

  inspectOutput(ctx: RunContext, text: string): Decision {
    const secrets = detectSecrets(text);
    if (secrets.length > 0)
      return this.block(ctx, {
        stage: 'output',
        source: 'model output',
        rule: 'secret-in-output',
        reason:
          'The answer contained what looks like a credential and was withheld.',
        evidence: null,
      });
    if (detectExfiltrationLink(text))
      return this.block(ctx, {
        stage: 'output',
        source: 'model output',
        rule: 'external-link-exfiltration',
        reason:
          'The answer contained a link that could send data to an external site and was withheld.',
        evidence: null,
      });
    return { allowed: true };
  }

  private block(
    ctx: RunContext,
    event: {
      stage: SecurityEvent['stage'];
      source: string;
      rule: string;
      reason: string;
      evidence: string | null;
      score?: number;
    },
  ): Blocked {
    this.events.record({
      projectId: ctx.projectId,
      runId: ctx.runId,
      documentId: null,
      stage: event.stage,
      rule: event.rule,
      source: event.source,
      outcome: 'blocked',
      detail: event.reason,
      evidence: event.evidence,
      score: event.score ?? null,
    });
    return { allowed: false, rule: event.rule, reason: event.reason };
  }

  private async scanOne(
    ctx: RunContext,
    stage: SecurityEvent['stage'],
    source: string,
    text: string,
  ): Promise<ScanVerdict | 'unavailable' | undefined> {
    try {
      return (await this.scanner.scan([text]))[0];
    } catch (error) {
      this.requireScannerError(error);
      this.block(ctx, {
        stage,
        source,
        rule: UNAVAILABLE.rule,
        reason: UNAVAILABLE.reason,
        evidence: null,
      });
      return 'unavailable';
    }
  }

  /** Only scanner outages fail closed here; any other error is a bug and must surface. */
  private requireScannerError(error: unknown): void {
    if (!(error instanceof ScannerUnavailableError)) throw error;
  }
}

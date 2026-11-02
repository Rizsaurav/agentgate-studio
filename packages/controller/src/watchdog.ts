import type { ServiceCheck } from './health';

const CHECK_INTERVAL_MS = 30_000;
const REMEDY_WINDOW_MS = 10 * 60_000;
const MAX_REMEDY_ATTEMPTS = 3;

export type Remedy = 'start-ollama' | 'start-scanner';
export type Finding = {
  /** Stable across checks so one problem is one finding, and investigated once. */
  id: string;
  severity: 'info' | 'warning' | 'critical';
  title: string;
  detail: string;
  /** A known safe fix that needs no model to decide. */
  remedy: Remedy | null;
  /** Worth a model's judgement: the cause is not obvious from the rules. */
  needsAgent: boolean;
};

/** Facts the rules judge; gathered from the real services and database by the caller. */
export type Probe = {
  services: ServiceCheck[];
  /** False until the user installs or picks a local model; cloud-only users never need Ollama. */
  usesLocalModels: boolean;
  installedModels: number | null;
  lastEval: {
    id: string;
    status: 'queued' | 'running' | 'passed' | 'failed' | 'error';
    passed: number;
    total: number;
  } | null;
  blockedLast24h: number;
  pull: { model: string; status: string } | null;
};

/** Plain rules, no model: what is wrong right now, and whether a safe fix is known. */
export function assess(probe: Probe): Finding[] {
  const findings: Finding[] = [];
  const service = (needle: string) =>
    probe.services.find((check) => check.name.toLowerCase().includes(needle));
  const ollama = service('ollama');
  const scanner = service('scanner');
  const docs = service('reference');
  if (probe.usesLocalModels && ollama && !ollama.ok)
    findings.push({
      id: 'ollama-down',
      severity: 'critical',
      title: 'Local models are offline',
      detail: 'Ollama is not running, so no local model can answer.',
      remedy: 'start-ollama',
      needsAgent: false,
    });
  if (scanner && !scanner.ok)
    findings.push({
      id: 'scanner-down',
      severity: 'critical',
      title: 'Security scanner is offline',
      detail:
        'Tasks and new documents are blocked until it is back (the app fails closed).',
      remedy: 'start-scanner',
      needsAgent: false,
    });
  if (docs && !docs.ok)
    findings.push({
      id: 'docs-missing',
      severity: 'warning',
      title: 'Reference folder is missing',
      detail: docs.detail,
      remedy: null,
      needsAgent: false,
    });
  if (probe.usesLocalModels && ollama?.ok && probe.installedModels === 0)
    findings.push({
      id: 'no-local-model',
      severity: 'info',
      title: 'No local model installed',
      detail: 'Install the recommended model from the Models page.',
      remedy: null,
      needsAgent: false,
    });
  if (probe.pull?.status === 'failed')
    findings.push({
      id: `pull-failed:${probe.pull.model}`,
      severity: 'warning',
      title: `Download of ${probe.pull.model} failed`,
      detail: 'The model download did not finish.',
      remedy: null,
      needsAgent: true,
    });
  const evaluation = probe.lastEval;
  if (
    evaluation &&
    (evaluation.status === 'failed' || evaluation.status === 'error')
  )
    findings.push({
      id: `eval-${evaluation.status}:${evaluation.id}`,
      severity: 'warning',
      title:
        evaluation.status === 'failed'
          ? `Evaluation failed (${evaluation.passed} of ${evaluation.total} passed)`
          : 'Evaluation could not run',
      detail: 'The required security suite did not pass.',
      remedy: null,
      needsAgent: true,
    });
  if (probe.blockedLast24h > 0)
    findings.push({
      id: 'blocked-activity',
      severity: 'info',
      title: `${probe.blockedLast24h} item(s) blocked in the last 24 hours`,
      detail: 'The protections stopped tasks, passages or documents.',
      remedy: null,
      needsAgent: false,
    });
  return findings;
}

type Options = {
  probe: () => Promise<Probe>;
  /** Each fix reports what it did, in a sentence. */
  remedies: Record<Remedy, () => Promise<string>>;
  /** Called with findings that need judgement; it decides for itself whether to spend tokens. */
  onNeedsAgent?: (finding: Finding) => void;
  /** Called after each automatic fix so it can be recorded. */
  onAction?: (finding: Finding, outcome: string) => void;
  now?: () => number;
};

/** Checks the whole system on a timer and applies known safe fixes, with a limit on retries. */
export class Watchdog {
  private findings: Finding[] = [];
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private readonly attempts = new Map<Remedy, number[]>();
  private readonly now: () => number;

  constructor(private readonly options: Options) {
    this.now = options.now ?? Date.now;
  }

  current(): Finding[] {
    return this.findings;
  }

  start(): void {
    if (this.timer) return;
    void this.check();
    this.timer = setInterval(() => void this.check(), CHECK_INTERVAL_MS);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  /** One pass: look, fix what is safe to fix, and flag what needs judgement. */
  async check(): Promise<Finding[]> {
    if (this.running) return this.findings;
    this.running = true;
    try {
      this.findings = assess(await this.options.probe());
      for (const finding of this.findings) {
        if (finding.remedy) await this.fix(finding, finding.remedy);
        else if (finding.needsAgent) this.options.onNeedsAgent?.(finding);
      }
      return this.findings;
    } finally {
      this.running = false;
    }
  }

  private async fix(finding: Finding, remedy: Remedy): Promise<void> {
    const since = this.now() - REMEDY_WINDOW_MS;
    const recent = (this.attempts.get(remedy) ?? []).filter((at) => at > since);
    this.attempts.set(remedy, recent);
    if (recent.length >= MAX_REMEDY_ATTEMPTS) return;
    recent.push(this.now());
    let outcome: string;
    try {
      outcome = await this.options.remedies[remedy]();
    } catch (error) {
      outcome = `Could not fix it: ${error instanceof Error ? error.message : 'unknown error'}`;
    }
    this.options.onAction?.(finding, outcome);
  }
}

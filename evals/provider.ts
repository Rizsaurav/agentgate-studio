import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxText,
} from '@earendil-works/pi-ai';
import {
  ContextService,
  DocumentService,
  LlmGuardScanner,
  ProjectService,
  ProtectionPipeline,
  RunService,
  SessionService,
  SqliteContext,
  SqliteDocuments,
  SqliteProjects,
  SqliteSecurityEvents,
  SqliteSessions,
  openDatabase,
  type AgentModels,
  type InjectionScanner,
  type RunGuard,
} from '../packages/controller/src/index';

/**
 * Promptfoo provider that runs the application's real pipeline (ingestion,
 * retrieval, scanning, generation, output inspection) against a temporary
 * database. The model is a scripted fixture so required checks need no key;
 * the point is to prove the application stops unsafe content whatever a model says.
 */
const varsSchema = z.object({
  question: z.string().min(1),
  /** Comma-separated directories under /fixtures, copied into the reference folder and referenced in order. */
  fixtures: z.string().optional(),
  documents: z
    .array(z.object({ name: z.string(), text: z.string() }))
    .optional(),
  referencePath: z.string().optional(),
  goal: z.string().optional(),
  modelAnswer: z.string().optional(),
});

const FIXTURES = join(
  dirname(fileURLToPath(import.meta.url)),
  '..',
  'fixtures',
);
type Config = { profile: 'enforced' | 'weak-demo' };

const clean: InjectionScanner = {
  scan: async (texts) => texts.map(() => ({ injection: false, score: 0 })),
};
/** DELIBERATELY WEAK (demo only): no scanning and no output inspection. Never used by default. */
const allowAll: RunGuard = {
  checkInput: async () => ({ allowed: true }),
  screenPassages: async (_ctx, passages) => ({ passages, blocked: null }),
  inspectOutput: () => ({ allowed: true }),
};

export default class AgentGateProvider {
  constructor(private readonly options: { config?: Config } = {}) {}

  id(): string {
    return `agentgate-pipeline:${this.options.config?.profile ?? 'enforced'}`;
  }

  async callApi(_prompt: string, context?: { vars?: Record<string, unknown> }) {
    const vars = varsSchema.parse(context?.vars);
    const weak = this.options.config?.profile === 'weak-demo';
    const directory = mkdtempSync(join(tmpdir(), 'agentgate-eval-'));
    const root = join(directory, 'docs');
    mkdirSync(root);
    const db = openDatabase(join(directory, 'agentgate.sqlite'));
    try {
      const fixtures = (vars.fixtures ?? '').split(',').filter(Boolean);
      for (const fixture of fixtures)
        cpSync(join(FIXTURES, fixture), join(root, fixture), {
          recursive: true,
        });
      for (const file of vars.documents ?? []) {
        mkdirSync(dirname(join(root, file.name)), { recursive: true });
        writeFileSync(join(root, file.name), file.text);
      }
      const projectRepository = new SqliteProjects(db);
      const documentRepository = new SqliteDocuments(db);
      const events = new SqliteSecurityEvents(db);
      const pipeline = new ProtectionPipeline(
        weak ? clean : new LlmGuardScanner(process.env.AGENTGATE_SCANNER_URL),
        events,
        (projectId, id, seqs) =>
          documentRepository.withhold(projectId, id, seqs),
      );
      const documents = new DocumentService(
        documentRepository,
        projectRepository,
        root,
        weak
          ? async () => ({ withheld: [] })
          : (document, chunks) => pipeline.screenDocument(document, chunks),
      );
      const project = new ProjectService(projectRepository).create({
        name: 'Eval',
      });
      const context = new ContextService(
        new SqliteContext(db),
        projectRepository,
      );
      if (vars.goal)
        context.add({ projectId: project.id, kind: 'goal', text: vars.goal });

      let ingestError: string | null = null;
      const quarantined: string[] = [];
      const withheld: string[] = [];
      const skipped: string[] = [];
      const paths = vars.referencePath
        ? [vars.referencePath]
        : [...fixtures, ...(vars.documents ? ['.'] : [])];
      try {
        for (const path of paths) {
          const result = await documents.reference({
            projectId: project.id,
            path,
          });
          quarantined.push(...result.quarantined.map((q) => q.document.title));
          withheld.push(
            ...result.added.filter((d) => d.withheld > 0).map((d) => d.title),
          );
          skipped.push(...result.skipped.map((s) => s.path));
        }
      } catch (error) {
        ingestError = error instanceof Error ? error.message : 'unknown error';
      }

      const faux = fauxProvider();
      const registry = createModels();
      registry.setProvider(faux.provider);
      faux.setResponses([
        (ctx) => {
          const last = ctx.messages.findLast((m) => m.role === 'user');
          const content = last?.content;
          const prompt =
            typeof content === 'string'
              ? content
              : (content ?? [])
                  .map((b) => (b.type === 'text' ? b.text : ''))
                  .join('');
          const excerpts = [
            ...prompt.matchAll(/<excerpt[^>]*>([\s\S]*?)<\/excerpt>/g),
          ].map((m) => (m[1] ?? '').replace(/\s+/g, ' ').trim());
          // Without a scripted answer the fixture answers only from excerpts it was actually given.
          const answer =
            vars.modelAnswer ??
            (excerpts.length > 0
              ? `According to the references: ${excerpts.join(' | ')}`
              : 'NO REFERENCES PROVIDED');
          return fauxAssistantMessage([fauxText(answer)]);
        },
      ]);
      const models: AgentModels = {
        open: async () => ({
          model: faux.getModel(),
          streamFn: (m, c, o) => registry.streamSimple(m, c, o),
          getApiKey: () => 'fixture',
          describeError: (raw) => raw,
        }),
      };
      const repository = new SqliteSessions(db);
      const sessions = new SessionService(repository, projectRepository);
      const session = sessions.createSession({
        projectId: project.id,
        model: { provider: 'ollama', modelId: 'scripted-fixture' },
      });
      const runner = new RunService(repository, models, {
        guard: weak ? allowAll : pipeline,
        knowledge: {
          context: (id) => context.render(id),
          retrieve: (id, query) => documents.retrieve(id, query),
        },
      });
      const run = runner.enqueue({
        sessionId: session.id,
        prompt: vars.question,
      });
      await runner.idle();
      const final = sessions.findRun(run.id);
      const answer = sessions
        .eventsAfter(run.id, 0)
        .filter((e) => e.type === 'text_delta')
        .map((e) => e.text)
        .join('');
      return {
        output: JSON.stringify({
          profile: weak ? 'weak-demo' : 'enforced',
          status: final?.status,
          error: final?.error,
          answer,
          sources: sessions.sources(run.id).map((s) => s.title),
          quarantined,
          withheld,
          skipped,
          ingestError,
          modelCalls: faux.state.callCount,
          findings: events
            .recent(50)
            .map((e) => ({ stage: e.stage, rule: e.rule, outcome: e.outcome })),
        }),
      };
    } finally {
      db.close();
      rmSync(directory, { recursive: true, force: true });
    }
  }
}

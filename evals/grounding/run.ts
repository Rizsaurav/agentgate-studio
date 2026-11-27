import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_RETRIEVAL,
  DEFAULT_SCANNER_URL,
  indexCorpus,
  LlmGuardScanner,
  NOT_COVERED,
  openAICompatibleRegistry,
  openDatabase,
  ProjectService,
  ProtectionPipeline,
  retrievalSetSchema,
  RunService,
  ScannerRetrievalModels,
  SessionService,
  SqliteProjects,
  SqliteSecurityEvents,
  SqliteSessions,
  type AgentModels,
} from '@agentgate/controller';

// Live grounding evaluation: does a real small model answer from the documents, and decline when they do not
// answer? Runs every question of a retrieval set through the real RunService, guard and scanner models,
// against a local OpenAI-compatible model server (llama.cpp's llama-server, Ollama, LM Studio):
//
//   AGENTGATE_EVAL_MODEL_URL=http://127.0.0.1:8080/v1 AGENTGATE_EVAL_MODEL=qwen3-1.7b \
//   npx tsx evals/grounding/run.ts --set kb --mode full [--limit 40]
//
// Modes: "keyword" (keyword top 4, no answer check: the system before this work), "gated" (hybrid search with
// the abstention gate, no answer check), "full" (gate, answer check, one revision, removal).
const here = dirname(fileURLToPath(import.meta.url));
const arg = (name: string) => {
  const index = process.argv.indexOf(`--${name}`);
  return index === -1 ? undefined : process.argv[index + 1];
};
const mode = (arg('mode') ?? 'full') as 'keyword' | 'gated' | 'full';
if (!['keyword', 'gated', 'full'].includes(mode))
  throw new Error(`Unknown mode "${mode}".`);
const minArg = arg('min');
if (minArg !== undefined && !Number.isFinite(Number(minArg)))
  throw new Error(`--min needs a number, not "${minArg}".`);
const setName = arg('set') ?? 'kb';
const limit = Number(arg('limit') ?? Infinity);
const only = arg('ids')?.split(',');
const set = retrievalSetSchema.parse(
  JSON.parse(
    readFileSync(
      join(here, '..', 'retrieval', `questions-${setName}.json`),
      'utf8',
    ),
  ),
);
const modelUrl =
  process.env.AGENTGATE_EVAL_MODEL_URL ?? 'http://127.0.0.1:8080/v1';
const modelId = process.env.AGENTGATE_EVAL_MODEL ?? 'local';
const scannerUrl = process.env.AGENTGATE_SCANNER_URL ?? DEFAULT_SCANNER_URL;

const retrievalModels = new ScannerRetrievalModels(scannerUrl);
const corpus = await indexCorpus(
  set,
  join(here, '..', '..', 'fixtures'),
  mode === 'keyword' ? undefined : retrievalModels,
  {
    ...DEFAULT_RETRIEVAL,
    ...(minArg !== undefined ? { minScore: Number(minArg) } : {}),
  },
);
const work = mkdtempSync(join(tmpdir(), 'agentgate-grounding-'));
const db = openDatabase(join(work, 'agentgate.sqlite'));
const projectRepository = new SqliteProjects(db);
const repository = new SqliteSessions(db);
const sessions = new SessionService(repository, projectRepository);
const project = new ProjectService(projectRepository).create({
  name: 'Grounding evaluation',
});
const guard = new ProtectionPipeline(
  new LlmGuardScanner(scannerUrl),
  new SqliteSecurityEvents(db),
  () => undefined,
);
const registry = openAICompatibleRegistry({
  id: 'custom',
  name: 'Evaluation model',
  baseUrl: modelUrl,
  modelIds: [modelId],
  apiKey: null,
});
const models: AgentModels = {
  open: async () => {
    const model = registry.getModel('custom', modelId);
    if (!model) throw new Error('The evaluation model is not set up.');
    return {
      model,
      streamFn: (target, context, options) =>
        registry.streamSimple(target, context, options),
      getApiKey: () => undefined,
      describeError: (raw) => raw,
    };
  },
};
const runner = new RunService(repository, models, {
  guard,
  timeoutMs: 180_000,
  knowledge: {
    context: () => '',
    retrieve: async (_projectId, query) => corpus.retrieve(query),
    hasDocuments: () => mode !== 'keyword',
  },
  ...(mode === 'full' ? { grounding: { models: retrievalModels } } : {}),
});

const declined = (answer: string) =>
  answer.includes(NOT_COVERED.replace(/\.$/, '')) ||
  /references (do not|don't) (cover|say|mention|contain)/i.test(answer);
/** The facts a labelled answer needs: its numbers, or else most of its content words. */
const hasFact = (answer: string, label: string) => {
  const text = answer.toLowerCase();
  // A table-row label: the answer is in the last cell; the other cells name the row.
  const phrase = label.includes('|')
    ? (label
        .split('|')
        .map((c) => c.trim())
        .filter(Boolean)
        .at(-1) ?? label)
    : label;
  const numbers = phrase.match(/\d+(?:[.,]\d+)?/g) ?? [];
  if (numbers.length) return numbers.every((n) => text.includes(n));
  const words = phrase.toLowerCase().match(/[a-z]{4,}/g) ?? [];
  return (
    words.length > 0 &&
    words.filter((w) => text.includes(w)).length / words.length >= 0.6
  );
};

type Row = {
  id: string;
  kind: string;
  answerable: boolean;
  answer: string;
  declined: boolean;
  correct: boolean;
  ms: number;
  grounding: string | undefined;
  sources: number;
};
const rows: Row[] = [];
for (const question of set.questions
  .filter((q) => !only || only.includes(q.id))
  .slice(0, limit)) {
  const session = sessions.createSession({
    projectId: project.id,
    model: { provider: 'custom', modelId },
  });
  const started = performance.now();
  const run = runner.enqueue({
    sessionId: session.id,
    prompt: question.question,
  });
  await runner.idle();
  const status = sessions.findRun(run.id)?.status;
  const answer = sessions
    .eventsAfter(run.id, 0)
    .filter((e) => e.type === 'text_delta')
    .map((e) => e.text)
    .join('');
  const answerable = question.answers.length > 0;
  rows.push({
    id: question.id,
    kind: question.kind ?? (answerable ? 'answerable' : 'unanswerable'),
    answerable,
    answer: status === 'completed' ? answer : `[${status}]`,
    declined: declined(answer),
    correct:
      answerable &&
      !declined(answer) &&
      question.answers.some((a) => hasFact(answer, a.contains)),
    ms: performance.now() - started,
    grounding: sessions
      .eventsAfter(run.id, 0)
      .find((e) => e.type === 'grounding')?.text,
    sources: (
      JSON.parse(
        sessions.eventsAfter(run.id, 0).find((e) => e.type === 'sources')
          ?.text ?? '[]',
      ) as unknown[]
    ).length,
  });
  process.stdout.write('.');
}
console.log('');
corpus.close();
db.close();
rmSync(work, { recursive: true, force: true });

const share = (n: number, of: number) =>
  of === 0 ? '–' : `${((n / of) * 100).toFixed(1)}%`;
const answerable = rows.filter((r) => r.answerable);
const unanswerable = rows.filter((r) => !r.answerable);
const kinds = [...new Set(rows.map((r) => r.kind))];
const lines = [
  `Grounding, mode ${mode}${minArg !== undefined ? ` (gate ${minArg})` : ''}, model ${modelId}: ${rows.length} questions, ${(rows.reduce((s, r) => s + r.ms, 0) / rows.length / 1000).toFixed(1)} s per question`,
  '',
  `- Answerable answered correctly: ${share(answerable.filter((r) => r.correct).length, answerable.length)}`,
  `- Answerable wrongly declined: ${share(answerable.filter((r) => r.declined).length, answerable.length)}`,
  `- Unanswerable declined (no hallucination): ${share(unanswerable.filter((r) => r.declined).length, unanswerable.length)}`,
  `- Unanswerable answered anyway (hallucination risk): ${share(unanswerable.filter((r) => !r.declined).length, unanswerable.length)}`,
  '',
  '| Kind | Questions | Correct | Declined |',
  '| --- | --- | --- | --- |',
  ...kinds.map((kind) => {
    const k = rows.filter((r) => r.kind === kind);
    return `| ${kind} | ${k.length} | ${k.filter((r) => r.correct).length} | ${k.filter((r) => r.declined).length} |`;
  }),
];
console.log(lines.join('\n'));
const out = arg('out');
if (out) writeFileSync(out, JSON.stringify({ mode, modelId, rows }, null, 2));

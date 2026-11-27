import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
} from '@earendil-works/pi-ai';
import { afterEach, describe, expect, it } from 'vitest';
import {
  checkGrounding,
  claimText,
  groundedQuestion,
  NOT_COVERED,
  sentences,
  uncoveredQuestion,
  withoutClaims,
} from './grounding';
import { chunkSections, type Passage } from './documents';
import {
  ProjectService,
  RunService,
  SessionService,
  SqliteProjects,
  SqliteSessions,
  openDatabase,
  type AgentModels,
} from './index';
import {
  contextual,
  fuse,
  gate,
  HybridRetriever,
  keywordQuery,
  type Candidate,
  type RetrievalIndex,
  type RetrievalModels,
} from './retrieval';
import { ScannerUnavailableError } from './scanner';
import { markerScanner, protection } from './test-support';

const passage = (text: string, extra: Partial<Passage> = {}): Passage => ({
  documentId: randomUUID(),
  title: 'Returns',
  path: 'returns.md',
  seq: 0,
  text,
  released: false,
  ...extra,
});

/**
 * A stand-in for the entailment model: a sentence is supported when every content word in it appears in the
 * premise, and contradicted when it states a number the premise does not have while the premise has one.
 */
const words = (text: string) =>
  text.toLowerCase().match(/[a-z]{4,}|\d+/g) ?? [];
const fakeEntail: Pick<RetrievalModels, 'entail'> = {
  entail: async (pairs) =>
    pairs.map(({ premise, hypothesis }) => {
      const known = new Set(words(premise));
      const claimed = words(hypothesis);
      const supported = claimed.every((w) => known.has(w));
      const numbers = claimed.filter((w) => /\d/.test(w));
      const contradicted =
        !supported && numbers.some((n) => !known.has(n)) && /\d/.test(premise);
      return {
        entailment: supported ? 0.95 : 0.05,
        contradiction: contradicted ? 0.9 : 0.05,
      };
    }),
};

describe('grounded answers', () => {
  it('numbers excerpts, names their section, and gives one fixed reply when they do not answer', () => {
    const prompt = groundedQuestion('How long?', [
      passage('Within 30 days.', { heading: 'Bikes' }),
    ]);
    expect(prompt).toContain('<excerpt id="1" source="Returns > Bikes">');
    expect(prompt).toContain(`reply exactly: ${NOT_COVERED}`);
    expect(prompt).toContain('citing it like [1]');
    expect(uncoveredQuestion('Gift cards?')).toContain(NOT_COVERED);
  });

  it('splits answers into sentences across lines and lists, and strips citations from claims', () => {
    const answer =
      'Bikes go back within 30 days [1]. E-bikes within 14 days [2].\n- Clearance items are final sale [1].';
    const claims = sentences(answer).map((s) => claimText(s.text));
    expect(claims).toEqual([
      'Bikes go back within 30 days.',
      'E-bikes within 14 days.',
      'Clearance items are final sale.',
    ]);
  });

  it('marks each claim supported, unsupported or contradicted against the excerpts', async () => {
    const check = await checkGrounding(
      'Bikes can be returned within 30 days of delivery [1]. Refunds arrive within a single week [1]. Helmets can be returned within 90 days [1].',
      [
        passage(
          'Bikes can be returned within 30 days of delivery. Helmets can be returned within 30 days if unused.',
        ),
      ],
      fakeEntail,
    );
    expect(check.claims.map((c) => c.status)).toEqual([
      'supported',
      'unsupported',
      'contradicted',
    ]);
    expect(check.supported).toBe(1);
  });

  it('removes rejected claims, leaves no empty list items, and falls back to the fixed reply', () => {
    const answer =
      'Returns take 30 days [1].\n- Refunds take five days.\n- Helmets are free.';
    expect(withoutClaims(answer, ['Refunds take five days.'])).toBe(
      'Returns take 30 days [1].\n- Helmets are free.',
    );
    expect(
      withoutClaims('Refunds take five business days.', [
        'Refunds take five business days.',
      ]),
    ).toBe(NOT_COVERED);
  });

  it('drops stray think tags and turns a citations-only reply into the fixed reply', () => {
    expect(withoutClaims('</think>\n\nReturns take 30 days [1].', [])).toBe(
      'Returns take 30 days [1].',
    );
    expect(
      withoutClaims('<think>\nmaybe 14?\n</think>Returns take 30 days.', []),
    ).toBe('Returns take 30 days.');
    expect(withoutClaims('[2]', [])).toBe(NOT_COVERED);
  });
});

describe('retrieval pieces', () => {
  it('drops stopwords from keyword queries and keeps codes with digits', () => {
    expect(keywordQuery('What is the error E12 on the display?')).toBe(
      '"error" OR "e12" OR "display"',
    );
    expect(keywordQuery('what is it')).toBeNull();
  });

  it('fuses rankings by reciprocal rank and gates on the best score', () => {
    expect(
      fuse(
        [
          [1, 2, 3],
          [3, 2, 9],
        ],
        60,
      ),
    ).toEqual([3, 2, 1, 9]);
    const candidate = (chunkId: number): Candidate => ({
      ...passage(`p${chunkId}`),
      chunkId,
      heading: '',
    });
    const scored = [
      { candidate: candidate(1), score: 0.9 },
      { candidate: candidate(2), score: 0.3 },
      { candidate: candidate(3), score: 0.001 },
    ];
    expect(
      gate(scored, { minScore: 0.5, keepScore: 0.01, limit: 4 }).map(
        (p) => p.text,
      ),
    ).toEqual(['p1', 'p2']);
    expect(gate(scored, { minScore: 0.95, keepScore: 0.01, limit: 4 })).toEqual(
      [],
    );
  });

  it('chunks by section and keeps the heading path', () => {
    const { chunks, headings } = chunkSections(
      '# Returns\n\nIntro.\n\n## Bikes\n\nThirty days.\n\n### Clearance\n\nFinal sale.\n\n```\n# not a heading\n```',
    );
    expect(chunks).toEqual([
      'Intro.',
      'Thirty days.',
      'Final sale.\n\n```\n# not a heading\n```',
    ]);
    expect(headings).toEqual(['', 'Bikes', 'Bikes > Clearance']);
    expect(
      contextual({ title: 'Returns', heading: 'Bikes', text: 'Thirty days.' }),
    ).toBe('Returns > Bikes\nThirty days.');
  });

  it('embeds missing chunks, searches both ways, and returns nothing when no passage answers', async () => {
    const rows: Candidate[] = [
      { ...passage('Bikes within 30 days.'), chunkId: 1, heading: 'Bikes' },
      { ...passage('Shipping takes 3 days.'), chunkId: 2, heading: 'Shipping' },
    ];
    const stored = new Map<number, Float32Array>();
    const index: RetrievalIndex = {
      keyword: () => [rows[0] as Candidate],
      vectors: () =>
        [...stored].map(([chunkId, vector]) => ({ chunkId, vector })),
      candidates: (ids) => rows.filter((r) => ids.includes(r.chunkId)),
      unembedded: () => rows.filter((r) => !stored.has(r.chunkId)),
      storeEmbeddings: (list) =>
        list.forEach((r) => stored.set(r.chunkId, r.vector)),
    };
    const models: RetrievalModels = {
      embed: async (texts) =>
        texts.map((t) => (t.includes('Shipping') ? [0, 1] : [1, 0])),
      rerank: async (query, texts) =>
        texts.map((t) =>
          query.includes('return') && t.includes('Bikes') ? 0.9 : 0.001,
        ),
      entail: async () => [],
    };
    const retriever = new HybridRetriever(index, models);
    const found = await retriever.retrieve('p', 'How long to return a bike?');
    expect(stored.size).toBe(2);
    expect(found.map((p) => p.text)).toEqual(['Bikes within 30 days.']);
    expect(found[0]?.score).toBe(0.9);
    expect(await retriever.retrieve('p', 'Do you sell gift cards?')).toEqual(
      [],
    );
  });
});

describe('the runner checks answers built on excerpts', () => {
  const directories: string[] = [];
  afterEach(() => {
    for (const d of directories.splice(0))
      rmSync(d, { recursive: true, force: true });
  });

  function rig(
    passages: Passage[],
    responses: Parameters<ReturnType<typeof fauxProvider>['setResponses']>[0],
    hasDocuments = true,
    failing: { retrieve?: boolean; entail?: boolean } = {},
  ) {
    const directory = mkdtempSync(join(tmpdir(), 'agentgate-grounding-'));
    directories.push(directory);
    const db = openDatabase(join(directory, 'agentgate.sqlite'));
    const projects = new ProjectService(new SqliteProjects(db));
    const repository = new SqliteSessions(db);
    const sessions = new SessionService(repository, new SqliteProjects(db));
    const faux = fauxProvider();
    const registry = createModels();
    registry.setProvider(faux.provider);
    faux.setResponses(responses);
    const models: AgentModels = {
      open: async () => ({
        model: faux.getModel(),
        streamFn: (target, context, options) =>
          registry.streamSimple(target, context, options),
        getApiKey: () => 'unused',
        describeError: (raw) => raw,
      }),
    };
    const runner = new RunService(repository, models, {
      guard: protection(db, markerScanner()).guard,
      knowledge: {
        context: () => '',
        retrieve: async () => {
          if (failing.retrieve)
            throw new ScannerUnavailableError('connection refused');
          return passages;
        },
        hasDocuments: () => hasDocuments,
      },
      grounding: {
        models: failing.entail
          ? {
              entail: async () => {
                throw new ScannerUnavailableError('connection refused');
              },
            }
          : fakeEntail,
      },
    });
    const session = sessions.createSession({
      projectId: projects.create({ name: 'P' }).id,
      model: { provider: 'ollama', modelId: 'faux' },
    });
    const ask = async (prompt: string) => {
      const run = runner.enqueue({ sessionId: session.id, prompt });
      await runner.idle();
      const events = sessions.eventsAfter(run.id, 0);
      return {
        answer: events
          .filter((e) => e.type === 'text_delta')
          .map((e) => e.text)
          .join(''),
        grounding: events.find((e) => e.type === 'grounding')?.text,
        status: sessions.findRun(run.id)?.status,
        history: sessions.transcript(session.id),
      };
    };
    return { faux, ask };
  }

  const refunds = [
    passage('Bikes can be returned within 30 days of delivery.'),
  ];

  it('delivers a supported answer as written, with one model call', async () => {
    const { faux, ask } = rig(refunds, [
      fauxAssistantMessage(
        'Bikes can be returned within 30 days of delivery [1].',
      ),
    ]);
    const result = await ask('How long do I have to return a bike?');
    expect(result.answer).toBe(
      'Bikes can be returned within 30 days of delivery [1].',
    );
    expect(JSON.parse(result.grounding ?? '{}')).toMatchObject({
      supported: 1,
      unsupported: 0,
      revised: false,
    });
    expect(faux.state.callCount).toBe(1);
  });

  it('asks once for a revision naming the unsupported sentence, and delivers the supported rewrite', async () => {
    let revisionPrompt = '';
    const { faux, ask } = rig(refunds, [
      fauxAssistantMessage(
        'Bikes can be returned within 30 days of delivery [1]. Shipping back is always free.',
      ),
      (context) => {
        const last = context.messages.at(-1);
        revisionPrompt =
          typeof last?.content === 'string'
            ? last.content
            : JSON.stringify(last?.content);
        return fauxAssistantMessage(
          'Bikes can be returned within 30 days of delivery [1].',
        );
      },
    ]);
    const result = await ask('How do returns work?');
    expect(revisionPrompt).toContain('Shipping back is always free.');
    expect(revisionPrompt).toContain(
      'Bikes can be returned within 30 days of delivery.',
    );
    expect(result.answer).toBe(
      'Bikes can be returned within 30 days of delivery [1].',
    );
    expect(JSON.parse(result.grounding ?? '{}')).toMatchObject({
      revised: true,
      removed: [],
    });
    expect(faux.state.callCount).toBe(2);
    // The history keeps the question and the delivered answer, not the revision exchange.
    expect(result.history.map((m) => m.role)).toEqual(['user', 'assistant']);
  });

  it('removes what the revision still cannot support, and answers with the fixed reply when nothing is left', async () => {
    const { ask } = rig(refunds, [
      fauxAssistantMessage('Gift cards never expire at all.'),
      fauxAssistantMessage('Gift cards are valid for five years.'),
    ]);
    const result = await ask('Do gift cards expire?');
    expect(result.status).toBe('completed');
    expect(result.answer).toBe(NOT_COVERED);
  });

  it('tells the model when the project has documents but none answers the question', async () => {
    let seen = '';
    const { ask } = rig(
      [],
      [
        (context) => {
          const last = context.messages.at(-1);
          seen =
            typeof last?.content === 'string'
              ? last.content
              : JSON.stringify(last?.content);
          return fauxAssistantMessage(NOT_COVERED);
        },
      ],
    );
    const result = await ask('What is the warranty on gift cards?');
    expect(seen).toContain('no passage answers this question');
    expect(result.answer).toBe(NOT_COVERED);
    expect(result.grounding).toBeUndefined();
  });

  it('fails closed, delivering no answer, when retrieval or the answer check is unreachable', async () => {
    const down = rig(refunds, [fauxAssistantMessage('Made up.')], true, {
      retrieve: true,
    });
    const noRetrieval = await down.ask('How long do I have to return a bike?');
    expect(noRetrieval.status).toBe('failed');
    expect(noRetrieval.answer).toBe('');
    expect(down.faux.state.callCount).toBe(0);

    const unchecked = rig(
      refunds,
      [fauxAssistantMessage('Bikes can be returned within 90 days [1].')],
      true,
      { entail: true },
    );
    const noCheck = await unchecked.ask('How long do I have to return a bike?');
    expect(noCheck.status).toBe('failed');
    expect(noCheck.answer).toBe('');
  });
});

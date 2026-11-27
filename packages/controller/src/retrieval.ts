import { createHash } from 'node:crypto';
import { z } from 'zod';
import type { Passage } from './documents';
import { ScannerUnavailableError } from './scanner';

/**
 * Hybrid retrieval with an abstention gate.
 *
 * 1. Candidates come from two searches over the same chunks: keyword (SQLite FTS5, bm25, stemmed) and
 *    semantic (embedding cosine similarity). Each misses what the other finds: exact codes and names versus
 *    paraphrases.
 * 2. The two rankings are merged by reciprocal rank fusion, which needs no score calibration between them.
 * 3. A cross-encoder reranker reads the question and each candidate together and scores how well the
 *    passage answers it.
 * 4. The gate, in two decisions. Answerable at all: the best passage must score at least `minScore`; when it
 *    does not, retrieval returns nothing, so a model is never handed text that merely shares words with the
 *    question, which is where small models invent answers. Which passages: every passage scoring at least
 *    `keepScore`, best first, up to `limit`, so the answer's neighbours come along for context.
 */

export type RetrievalOptions = {
  /** Candidates taken from each search before fusion. */
  candidates: number;
  /** Fused candidates the reranker reads. */
  rerank: number;
  /** Most passages given to the model. */
  limit: number;
  /** Reranker probability the best passage needs for the question to count as answerable. */
  minScore: number;
  /** Reranker probability any further passage needs to go along with the best one. */
  keepScore: number;
  /** Reciprocal rank fusion constant. */
  rrfK: number;
};

export const DEFAULT_RETRIEVAL: RetrievalOptions = {
  candidates: 40,
  rerank: 30,
  limit: 4,
  minScore: 0.02,
  keepScore: 0.01,
  rrfK: 60,
};

/** A chunk as search sees it: its text plus the document title and section it sits under. */
export type Candidate = Passage & { chunkId: number; heading: string };
export type RankedPassage = Passage & { heading: string; score: number };

export interface RetrievalModels {
  embed(texts: string[], query: boolean): Promise<number[][]>;
  rerank(query: string, texts: string[]): Promise<number[]>;
  entail(
    pairs: { premise: string; hypothesis: string }[],
  ): Promise<{ entailment: number; contradiction: number }[]>;
}

export interface RetrievalIndex {
  keyword(projectId: string, ftsQuery: string, limit: number): Candidate[];
  /** Unit vectors of every usable chunk in the project. */
  vectors(projectId: string): { chunkId: number; vector: Float32Array }[];
  candidates(chunkIds: number[]): Candidate[];
  /** Usable chunks that have no embedding yet. */
  unembedded(projectId: string, limit: number): Candidate[];
  storeEmbeddings(rows: { chunkId: number; vector: Float32Array }[]): void;
}

/** What a chunk means in its document: the title and section give a short passage its context. */
export function contextual(candidate: {
  title: string;
  heading: string;
  text: string;
}): string {
  const where = candidate.heading
    ? `${candidate.title} > ${candidate.heading}`
    : candidate.title;
  return `${where}\n${candidate.text}`;
}

/** Words that carry no meaning for keyword search; leaving them in lets any question match any passage. */
const STOPWORDS = new Set(
  (
    'the and for are but not you your yours with from that this these those what when where which who whom ' +
    'why how can could would should will shall may might must does did doing done have has had having was were ' +
    'been being into onto about over under than then there here their they them its our ours we us his her ' +
    'she him any all some each every more most other such only own same too very just also get got make made ' +
    'tell know need want like please use used using wants do'
  ).split(/\s+/),
);

/** Every term is quoted, so user text cannot inject FTS5 operators. Stopwords are dropped. */
export function keywordQuery(text: string): string | null {
  const terms = [
    ...new Set(text.toLowerCase().match(/[\p{L}\p{N}]{2,}/gu) ?? []),
  ].filter(
    (term) => !STOPWORDS.has(term) && (term.length >= 3 || /\d/.test(term)),
  );
  return terms.length > 0
    ? terms
        .slice(0, 16)
        .map((term) => `"${term}"`)
        .join(' OR ')
    : null;
}

/** Reciprocal rank fusion of several rankings of chunk ids. */
export function fuse(rankings: number[][], k: number): number[] {
  const scores = new Map<number, number>();
  for (const ranking of rankings)
    ranking.forEach((id, rank) =>
      scores.set(id, (scores.get(id) ?? 0) + 1 / (k + rank + 1)),
    );
  return [...scores.entries()].sort((a, b) => b[1] - a[1]).map(([id]) => id);
}

export function dot(a: Float32Array, b: Float32Array): number {
  let sum = 0;
  for (let i = 0; i < a.length; i += 1)
    sum += (a[i] as number) * (b[i] as number);
  return sum;
}

/** Applies the gate to reranked candidates: absolute floor, relative floor, limit. */
export function gate(
  scored: { candidate: Candidate; score: number }[],
  options: Pick<RetrievalOptions, 'limit' | 'minScore' | 'keepScore'>,
): RankedPassage[] {
  const sorted = [...scored].sort((a, b) => b.score - a.score);
  if ((sorted[0]?.score ?? 0) < options.minScore) return [];
  return sorted
    .filter(({ score }, index) => index === 0 || score >= options.keepScore)
    .slice(0, options.limit)
    .map(({ candidate, score }) => {
      const { chunkId: _chunkId, ...passage } = candidate;
      return { ...passage, score };
    });
}

export class HybridRetriever {
  constructor(
    private readonly index: RetrievalIndex,
    private readonly models: RetrievalModels,
    private readonly options: RetrievalOptions = DEFAULT_RETRIEVAL,
  ) {}

  async retrieve(projectId: string, query: string): Promise<RankedPassage[]> {
    const text = query.trim();
    if (!text) return [];
    await this.backfill(projectId);
    const fts = keywordQuery(text);
    const keyword = fts
      ? this.index
          .keyword(projectId, fts, this.options.candidates)
          .map((c) => c.chunkId)
      : [];
    const vectors = this.index.vectors(projectId);
    let semantic: number[] = [];
    if (vectors.length > 0) {
      const [queryVector] = await this.models.embed([text], true);
      const q = Float32Array.from(queryVector ?? []);
      semantic = vectors
        .map(({ chunkId, vector }) => ({ chunkId, score: dot(q, vector) }))
        .sort((a, b) => b.score - a.score)
        .slice(0, this.options.candidates)
        .map((v) => v.chunkId);
    }
    const fused = fuse([keyword, semantic], this.options.rrfK).slice(
      0,
      this.options.rerank,
    );
    if (fused.length === 0) return [];
    const candidates = this.index.candidates(fused);
    const scores = await this.models.rerank(text, candidates.map(contextual));
    return gate(
      candidates.map((candidate, i) => ({ candidate, score: scores[i] ?? 0 })),
      this.options,
    );
  }

  /** Embeds chunks indexed before embeddings existed, or while the models were unavailable. */
  private async backfill(projectId: string): Promise<void> {
    for (;;) {
      const pending = this.index.unembedded(projectId, 64);
      if (pending.length === 0) return;
      const vectors = await this.models.embed(pending.map(contextual), false);
      this.index.storeEmbeddings(
        pending.map((c, i) => ({
          chunkId: c.chunkId,
          vector: Float32Array.from(vectors[i] ?? []),
        })),
      );
    }
  }
}

const EMBED_TIMEOUT_MS = 30_000;
const vectorsSchema = z.object({ vectors: z.array(z.array(z.number())) });
const scoresSchema = z.object({ scores: z.array(z.number().min(0).max(1)) });
const entailSchema = z.object({
  results: z.array(
    z.object({
      entailment: z.number().min(0).max(1),
      contradiction: z.number().min(0).max(1),
    }),
  ),
});
const MAX_BATCH = 64;

/** The scanner service's retrieval models over HTTP. Any failure is "unavailable": callers fail closed. */
export class ScannerRetrievalModels implements RetrievalModels {
  private readonly baseUrl: string;
  /** Query embeddings by text: the same question asked again costs nothing. */
  private readonly queryCache = new Map<string, number[]>();

  constructor(
    baseUrl: string,
    private readonly timeoutMs = EMBED_TIMEOUT_MS,
  ) {
    this.baseUrl = new URL(baseUrl).origin;
  }

  async embed(texts: string[], query: boolean): Promise<number[][]> {
    const key = (t: string) => createHash('sha256').update(t).digest('hex');
    if (query && texts.length === 1) {
      const hit = this.queryCache.get(key(texts[0] as string));
      if (hit) return [hit];
    }
    const vectors: number[][] = [];
    for (let i = 0; i < texts.length; i += MAX_BATCH) {
      const body = await this.post('/embed', {
        texts: texts.slice(i, i + MAX_BATCH),
        query,
      });
      const parsed = vectorsSchema.safeParse(body);
      if (!parsed.success)
        throw new ScannerUnavailableError('it returned an unexpected response');
      vectors.push(...parsed.data.vectors);
    }
    if (vectors.length !== texts.length)
      throw new ScannerUnavailableError('it returned an unexpected response');
    if (query && texts.length === 1) {
      if (this.queryCache.size >= 500)
        this.queryCache.delete(this.queryCache.keys().next().value as string);
      this.queryCache.set(key(texts[0] as string), vectors[0] as number[]);
    }
    return vectors;
  }

  async rerank(query: string, texts: string[]): Promise<number[]> {
    const scores: number[] = [];
    for (let i = 0; i < texts.length; i += MAX_BATCH) {
      const parsed = scoresSchema.safeParse(
        await this.post('/rerank', {
          query,
          texts: texts.slice(i, i + MAX_BATCH),
        }),
      );
      if (!parsed.success)
        throw new ScannerUnavailableError('it returned an unexpected response');
      scores.push(...parsed.data.scores);
    }
    if (scores.length !== texts.length)
      throw new ScannerUnavailableError('it returned an unexpected response');
    return scores;
  }

  async entail(
    pairs: { premise: string; hypothesis: string }[],
  ): Promise<{ entailment: number; contradiction: number }[]> {
    const results: { entailment: number; contradiction: number }[] = [];
    for (let i = 0; i < pairs.length; i += MAX_BATCH) {
      const parsed = entailSchema.safeParse(
        await this.post('/entail', { pairs: pairs.slice(i, i + MAX_BATCH) }),
      );
      if (!parsed.success)
        throw new ScannerUnavailableError('it returned an unexpected response');
      results.push(...parsed.data.results);
    }
    if (results.length !== pairs.length)
      throw new ScannerUnavailableError('it returned an unexpected response');
    return results;
  }

  private async post(path: string, payload: unknown): Promise<unknown> {
    let response: Response;
    try {
      response = await fetch(`${this.baseUrl}${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (error) {
      throw new ScannerUnavailableError(
        error instanceof Error && error.name === 'TimeoutError'
          ? 'it timed out'
          : 'it could not be reached',
      );
    }
    if (!response.ok)
      throw new ScannerUnavailableError(`it returned HTTP ${response.status}`);
    try {
      return await response.json();
    } catch {
      throw new ScannerUnavailableError('it returned malformed data');
    }
  }
}

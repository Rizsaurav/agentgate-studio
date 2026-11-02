import { createHash } from 'node:crypto';
import { z } from 'zod';

export const DEFAULT_SCANNER_URL = 'http://127.0.0.1:8765';
const SCAN_TIMEOUT_MS = 10_000;
/** The same text is scanned at ingestion and again on every retrieval; a verdict is reused for this long. */
const CACHE_TTL_MS = 60 * 60_000;
const CACHE_MAX_ENTRIES = 4000;
const responseSchema = z.object({
  scanner: z.string(),
  results: z.array(
    z.object({ valid: z.boolean(), score: z.number().min(0).max(1) }).strict(),
  ),
});

export type ScanVerdict = { injection: boolean; score: number };

/** Raised for any scanner problem. Callers must treat it as "not scanned" and block. */
export class ScannerUnavailableError extends Error {
  constructor(reason: string) {
    super(`The security scanner is unavailable: ${reason}`);
    this.name = 'ScannerUnavailableError';
  }
}

export interface InjectionScanner {
  /** One verdict per input text, in order. */
  scan(texts: string[]): Promise<ScanVerdict[]>;
}

/** Adapter for the LLM Guard prompt-injection scanner service in /scanner. */
export class LlmGuardScanner implements InjectionScanner {
  private readonly baseUrl: string;
  /** Verdicts by content hash. Only real scanner answers are stored, so an outage still fails closed. */
  private readonly cache = new Map<
    string,
    { verdict: ScanVerdict; at: number }
  >();

  constructor(
    baseUrl: string = DEFAULT_SCANNER_URL,
    private readonly timeoutMs: number = SCAN_TIMEOUT_MS,
  ) {
    this.baseUrl = new URL(baseUrl).origin;
  }

  async scan(texts: string[]): Promise<ScanVerdict[]> {
    const now = Date.now();
    const keys = texts.map((text) =>
      createHash('sha256').update(text).digest('hex'),
    );
    const known = keys.map((key) => {
      const hit = this.cache.get(key);
      return hit && now - hit.at < CACHE_TTL_MS ? hit.verdict : undefined;
    });
    // Texts repeated within one call are sent once.
    const missing = [
      ...new Set(keys.filter((_key, index) => known[index] === undefined)),
    ];
    if (missing.length > 0) {
      const sent = missing.map((key) => texts[keys.indexOf(key)] as string);
      const fresh = await this.request(sent);
      missing.forEach((key, index) => {
        if (this.cache.size >= CACHE_MAX_ENTRIES)
          this.cache.delete(this.cache.keys().next().value as string);
        this.cache.set(key, { verdict: fresh[index] as ScanVerdict, at: now });
      });
    }
    return keys.map(
      (key, index) =>
        known[index] ?? (this.cache.get(key)?.verdict as ScanVerdict),
    );
  }

  private async request(texts: string[]): Promise<ScanVerdict[]> {
    let response: Response;
    try {
      response = await fetch(`${this.baseUrl}/scan`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ texts }),
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
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new ScannerUnavailableError('it returned malformed data');
    }
    const parsed = responseSchema.safeParse(body);
    if (!parsed.success || parsed.data.results.length !== texts.length)
      throw new ScannerUnavailableError('it returned an unexpected response');
    return parsed.data.results.map((result) => ({
      injection: !result.valid,
      score: result.score,
    }));
  }
}

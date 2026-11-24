import { createHash } from 'node:crypto';
import { detectExfiltrationLink, detectSecrets } from './policy';

// eslint-disable-next-line no-control-regex -- ANSI colour codes are control characters by definition.
export const ANSI = /\u001b\[[0-9;]*[A-Za-z]/g;
/** Timestamps and run-specific numbers differ between identical failures, so they are not part of a signature. */
const VOLATILE =
  /\d{4}-\d\d-\d\dT[\d:.]+Z?|\b\d+(?:\.\d+)?\s?(?:ms|s)\b|0x[0-9a-f]+|\b\d{3,}\b/gi;
const SIGNAL =
  /error|err!|fail|fatal|exception|panic|assert|cannot|unable|not found|denied|time(?:d)? ?out|exit code [1-9]|✗|✕|^\s+at\s/i;
/**
 * What `gh run view --log-failed` puts before each line: job, step and a timestamp. Job and step
 * are separated by tabs and may contain spaces ("End-to-end tests (required)"); older or plain
 * logs use single words separated by spaces.
 */
export const LINE_PREFIX =
  /^(?:[^\t]*\t[^\t]*\t|\S+\s+\S+\s+)?\d{4}-\d\d-\d\dT\S+\s?/;
const NOISE =
  /^\s*(?:##\[(?:group|endgroup|debug)\]|downloading|downloaded|fetching|resolving|extracting|npm warn|added \d+ packages|\d+% |\s*$)/i;

/**
 * Cuts a CI log to the lines that explain a failure: errors and their stack frames, without
 * download chatter, repeats or credential-like text. A log is data, never an instruction, and a
 * small model reads far fewer tokens for the same diagnosis.
 */
export function condenseLog(raw: string, maxChars = 1500): string {
  const kept: string[] = [];
  const seen = new Set<string>();
  for (const original of raw.replace(ANSI, '').split('\n')) {
    const line = original.replace(LINE_PREFIX, '').trimEnd();
    if (NOISE.test(line) || !SIGNAL.test(line)) continue;
    // Logs can echo secrets and links built to leak data: those lines never reach a model.
    if (detectSecrets(line).length > 0 || detectExfiltrationLink(line))
      continue;
    const key = line.replace(VOLATILE, '#').trim();
    if (seen.has(key)) continue;
    seen.add(key);
    kept.push(line.trim().slice(0, 240));
  }
  // Failures are usually explained at the end of a log, so the tail wins when it must be cut.
  let text = kept.join('\n');
  if (text.length > maxChars) {
    // Cut at a line boundary, so the first line shown is whole.
    const tail = text.slice(-maxChars);
    const start = tail.indexOf('\n');
    text = `…\n${start === -1 ? tail : tail.slice(start + 1)}`;
  }
  return text;
}

/** A stable identity for a failure, so the same one is diagnosed once instead of on every run. */
export function failureSignature(condensed: string): string {
  const normal = condensed
    .split('\n')
    .map((line) => line.replace(VOLATILE, '#').trim())
    .join('\n');
  return createHash('sha256').update(normal).digest('hex').slice(0, 16);
}

/**
 * Application-owned deterministic rules. These are a best-effort filter for
 * well-known credential formats, not a guarantee that no secret can pass.
 */
const SECRET_RULES: readonly {
  rule: string;
  pattern: RegExp;
  /** What to cut out when it differs from what is detected (a whole key block, not only its header). */
  span?: RegExp;
}[] = [
  {
    rule: 'private-key',
    pattern: /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    span: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/,
  },
  { rule: 'aws-access-key', pattern: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  // Also covers Anthropic (sk-ant-), OpenRouter (sk-or-), OpenAI and DeepSeek keys.
  { rule: 'api-key-sk', pattern: /\bsk-[A-Za-z0-9_-]{16,}/ },
  { rule: 'groq-key', pattern: /\bgsk_[A-Za-z0-9]{20,}/ },
  { rule: 'xai-key', pattern: /\bxai-[A-Za-z0-9]{20,}/ },
  { rule: 'huggingface-token', pattern: /\bhf_[A-Za-z0-9]{30,}/ },
  { rule: 'github-token', pattern: /\bgh[pousr]_[A-Za-z0-9]{30,}\b/ },
  { rule: 'github-fine-grained-token', pattern: /\bgithub_pat_\w{22,}/ },
  { rule: 'slack-token', pattern: /\bxox[baprs]-[A-Za-z0-9-]{10,}/ },
  { rule: 'google-api-key', pattern: /\bAIza[0-9A-Za-z_-]{35}\b/ },
  {
    rule: 'jwt',
    pattern: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/,
  },
  { rule: 'bearer-token', pattern: /\bBearer\s+[A-Za-z0-9._~+/-]{20,}=*/ },
  {
    rule: 'credential-assignment',
    pattern:
      /\b(?:api[_-]?key|secret|password|passwd|token)\b["']?\s*[:=]\s*["']?[^\s"']{12,}/i,
  },
];

const REDACTIONS = SECRET_RULES.map(({ pattern, span }) => {
  const source = span ?? pattern;
  return new RegExp(source.source, `${source.flags}g`);
});

export const REDACTED = '[redacted]';

/** Names of the rules that matched. Matched text is never returned, so findings are safe to store. */
export function detectSecrets(text: string): string[] {
  return SECRET_RULES.filter(({ pattern }) => pattern.test(text)).map(
    ({ rule }) => rule,
  );
}

/**
 * Text with every credential-shaped string replaced. Used where text leaves the app or is kept
 * (assistant notes and tool results, evaluation reasons). Best effort: a key with no
 * recognisable format passes through, so keys must still never be put into such text.
 */
export function redactSecrets(text: string): string {
  return REDACTIONS.reduce(
    (current, pattern) => current.replace(pattern, REDACTED),
    text,
  );
}

const DISALLOWED_OPERATIONS: readonly { rule: string; pattern: RegExp }[] = [
  {
    rule: 'destructive-shell',
    pattern: /\brm\s+-[a-z]*r[a-z]*f?\s+\/|\bmkfs\b|\bformat\s+c:/i,
  },
  {
    rule: 'destructive-sql',
    pattern: /\bdrop\s+(?:table|database)\b|\btruncate\s+table\b/i,
  },
  {
    rule: 'remote-code-execution',
    pattern: /\b(?:curl|wget)\b[^\n|]*\|\s*(?:sh|bash|zsh)\b/i,
  },
];

/** Operations no agent in this application may be asked to perform. First matching rule, or null. */
export function detectDisallowedOperation(text: string): string | null {
  return (
    DISALLOWED_OPERATIONS.find(({ pattern }) => pattern.test(text))?.rule ??
    null
  );
}

/** Markdown images/links that carry data in a URL query are a common exfiltration channel. */
const EXFILTRATION_LINK = /!?\[[^\]]*\]\(\s*https?:\/\/[^)\s]*\?[^)\s]+\)/i;
export function detectExfiltrationLink(text: string): boolean {
  return EXFILTRATION_LINK.test(text);
}

/** A short, secret-free excerpt that is safe to store and show; null when it cannot be made safe. */
export function safeExcerpt(text: string, max = 160): string | null {
  if (detectSecrets(text).length > 0) return null;
  const clean = text
    .replace(/[\p{Cc}\p{Cf}]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return clean.length > max ? `${clean.slice(0, max)}…` : clean || null;
}

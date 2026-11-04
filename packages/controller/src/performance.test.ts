import { tmpdir } from 'node:os';
import { afterEach, describe, expect, it, vi } from 'vitest';

const execFile = vi.hoisted(() =>
  vi.fn(
    (
      _file: string,
      _args: string[],
      _options: object,
      callback: (error: Error | null, stdout: string) => void,
    ) => callback(null, 'Test GPU, 8192\n'),
  ),
);
vi.mock('node:child_process', async (original) => ({
  ...(await original<typeof import('node:child_process')>()),
  execFile,
}));

const { inspectSystem, openDatabase } = await import('./index');

afterEach(() => {
  vi.useRealTimers();
});

describe('hardware probe', () => {
  it('asks the NVIDIA driver at most once per 10 minutes, and reads disk fresh each time', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-11-04T00:00:00Z'));
    const first = await Promise.all([
      inspectSystem(tmpdir()),
      inspectSystem(tmpdir()),
    ]);
    expect(first[0].gpu).toEqual({
      name: 'Test GPU',
      memoryBytes: 8192 * 1024 ** 2,
    });
    expect(execFile).toHaveBeenCalledTimes(1);

    vi.setSystemTime(new Date('2026-11-04T00:09:59Z'));
    await inspectSystem(tmpdir());
    expect(execFile).toHaveBeenCalledTimes(1);

    vi.setSystemTime(new Date('2026-11-04T00:10:00Z'));
    const later = await inspectSystem(tmpdir());
    expect(execFile).toHaveBeenCalledTimes(2);
    expect(later.freeDiskBytes).toBeGreaterThan(0);
  });
});

describe('lookup indexes', () => {
  // The lookups the app makes on every page view or worker poll, as the repositories write them.
  const lookups: [string, string, string][] = [
    [
      'runs of a session',
      'runs_by_session',
      'SELECT * FROM runs WHERE session_id = ? ORDER BY created_at, id',
    ],
    [
      'next queued run',
      'runs_queued',
      "SELECT * FROM runs WHERE status = 'queued' ORDER BY created_at, id LIMIT 1",
    ],
    [
      'sessions of a project',
      'sessions_by_project',
      'SELECT * FROM sessions WHERE project_id = ? ORDER BY created_at DESC, id ASC',
    ],
    [
      'security events of a run',
      'security_events_by_run',
      'SELECT * FROM security_events WHERE run_id = ? ORDER BY created_at, id',
    ],
    [
      'passages of a document',
      'chunks_by_document',
      'SELECT * FROM chunks WHERE document_id = ?',
    ],
  ];

  it.each(lookups)(
    '%s uses %s instead of scanning the table',
    (_label, index, sql) => {
      const db = openDatabase(':memory:');
      try {
        const plan = (
          db
            .prepare(`EXPLAIN QUERY PLAN ${sql}`)
            .all(...(sql.includes('?') ? ['x'] : [])) as { detail: string }[]
        )
          .map((row) => row.detail)
          .join(' | ');
        expect(plan).toContain(`USING INDEX ${index}`);
        expect(plan).not.toContain('TEMP B-TREE');
      } finally {
        db.close();
      }
    },
  );
});

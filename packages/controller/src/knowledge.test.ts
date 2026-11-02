import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
} from '@earendil-works/pi-ai';
import { afterEach, describe, expect, it } from 'vitest';
import {
  ContextService,
  DocumentService,
  ProjectService,
  RunService,
  SessionService,
  SqliteContext,
  SqliteDocuments,
  SqliteProjects,
  SqliteSessions,
  chunkText,
  detectSecrets,
  openDatabase,
  toFtsQuery,
  type AgentModels,
} from './index';
import { markerScanner, protection } from './test-support';

const directories: string[] = [];
const closers: (() => void)[] = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
  for (const directory of directories.splice(0))
    rmSync(directory, { recursive: true, force: true });
});
function temp() {
  const directory = mkdtempSync(join(tmpdir(), 'agentgate-'));
  directories.push(directory);
  return directory;
}

function setup(withRoot = true) {
  const base = temp();
  const root = join(base, 'docs');
  mkdirSync(root);
  const filename = join(base, 'db', 'agentgate.sqlite');
  const open = () => {
    const db = openDatabase(filename);
    closers.push(() => {
      if (db.open) db.close();
    });
    const projectRepository = new SqliteProjects(db);
    return {
      db,
      projectRepository,
      projects: new ProjectService(projectRepository),
      context: new ContextService(new SqliteContext(db), projectRepository),
      guard: protection(db, markerScanner()).guard,
      documents: protection(db, markerScanner(), withRoot ? root : null)
        .documents,
    };
  };
  return { base, root, filename, open, ...open() };
}

describe('secret rules', () => {
  it.each([
    ['sk-abcdefghijklmnop1234', 'api-key-sk'],
    ['AKIAABCDEFGHIJKLMNOP', 'aws-access-key'],
    ['-----BEGIN RSA PRIVATE KEY-----', 'private-key'],
    ['password = hunter2hunter2hunter2', 'credential-assignment'],
  ])('detects %s', (text, rule) => {
    expect(detectSecrets(`note: ${text}`)).toContain(rule);
  });
  it('does not flag ordinary prose and returns rule names only', () => {
    expect(
      detectSecrets('Refunds take 7 business days. Keep the receipt.'),
    ).toEqual([]);
  });
});

describe('shared project context', () => {
  it('stores goals, decisions, and outcomes, renders them, and persists', () => {
    const { filename, open, projects, context, db } = setup();
    const project = projects.create({ name: 'P' });
    expect(context.render(project.id)).toBe('');
    context.add({
      projectId: project.id,
      kind: 'goal',
      text: ' Ship the RAG app ',
    });
    context.add({
      projectId: project.id,
      kind: 'decision',
      text: 'Use SQLite FTS5',
    });
    context.add({
      projectId: project.id,
      kind: 'outcome',
      text: 'Retrieval verified',
    });
    db.close();
    const reopened = open();
    expect(reopened.context.render(project.id)).toBe(
      [
        'Project context approved by the user:',
        '',
        'Goals:\n- Ship the RAG app',
        '',
        'Approved decisions:\n- Use SQLite FTS5',
        '',
        'Verified outcomes:\n- Retrieval verified',
      ].join('\n'),
    );
    expect(filename).toBeTruthy();
  });

  it('rejects credentials, unknown projects, invalid kinds, and removes by project', () => {
    const { projects, context } = setup();
    const project = projects.create({ name: 'P' });
    const other = projects.create({ name: 'Other' });
    expect(() =>
      context.add({
        projectId: project.id,
        kind: 'goal',
        text: 'key sk-abcdefghijklmnop1234',
      }),
    ).toThrow('credential');
    expect(() =>
      context.add({ projectId: project.id, kind: 'secret', text: 'x' }),
    ).toThrow();
    expect(() =>
      context.add({ projectId: crypto.randomUUID(), kind: 'goal', text: 'x' }),
    ).toThrow('Unknown project');
    const item = context.add({
      projectId: project.id,
      kind: 'goal',
      text: 'keep',
    });
    context.remove(other.id, item.id);
    expect(context.list(project.id)).toHaveLength(1);
    context.remove(project.id, item.id);
    expect(context.list(project.id)).toHaveLength(0);
  });
});

describe('reference documents and retrieval', () => {
  it('ingests a folder, retrieves attributed passages, and survives restart', async () => {
    const { root, open, projects, documents, db } = setup();
    writeFileSync(
      join(root, 'returns.md'),
      '# Returns\n\nBicycles can be returned within 30 days.\n\nRefunds take 7 business days.',
    );
    writeFileSync(
      join(root, 'shipping.txt'),
      'Shipping takes five days to most places.',
    );
    writeFileSync(join(root, 'image.png'), 'ignored');
    const project = projects.create({ name: 'P' });
    const result = await documents.reference({
      projectId: project.id,
      path: '.',
    });
    expect(result.added.map((d) => d.title).sort()).toEqual([
      'Returns',
      'shipping',
    ]);
    const hits = documents.retrieve(
      project.id,
      'How many days do refunds take?',
    );
    expect(hits[0]).toMatchObject({ title: 'Returns' });
    expect(hits[0]?.text).toContain('Refunds take 7 business days');
    db.close();
    const reopened = open();
    expect(reopened.documents.retrieve(project.id, 'refunds')[0]?.title).toBe(
      'Returns',
    );
    const again = await reopened.documents.reference({
      projectId: project.id,
      path: 'returns.md',
    });
    expect(again.skipped[0]?.reason).toBe('Already referenced.');
  });

  it('keeps retrieval scoped to the project and removes documents completely', async () => {
    const { root, projects, documents } = setup();
    writeFileSync(
      join(root, 'a.md'),
      '# A\n\nThe zebra crossing opens at noon.',
    );
    const first = projects.create({ name: 'One' });
    const second = projects.create({ name: 'Two' });
    const [added] = (
      await documents.reference({ projectId: first.id, path: 'a.md' })
    ).added;
    expect(documents.retrieve(second.id, 'zebra')).toEqual([]);
    expect(documents.retrieve(first.id, 'zebra')).toHaveLength(1);
    documents.remove(second.id, added?.id);
    expect(documents.retrieve(first.id, 'zebra')).toHaveLength(1);
    documents.remove(first.id, added?.id);
    expect(documents.retrieve(first.id, 'zebra')).toEqual([]);
  });

  it('confines paths to the reference folder, including through symlinks', async () => {
    const { base, root, projects, documents } = setup();
    writeFileSync(join(base, 'outside.md'), '# Outside\n\nPrivate notes.');
    symlinkSync(join(base, 'outside.md'), join(root, 'link.md'));
    symlinkSync(base, join(root, 'dirlink'));
    const project = projects.create({ name: 'P' });
    for (const path of [
      '../outside.md',
      '/etc/hosts',
      'link.md',
      'dirlink',
      'missing.md',
      'a\0b',
    ])
      await expect(
        documents.reference({ projectId: project.id, path }),
        path,
      ).rejects.toThrow();
    expect(documents.list(project.id)).toEqual([]);
  });

  it('excludes secret-bearing, oversized, and empty files and reports why', async () => {
    const { root, projects, documents } = setup();
    writeFileSync(
      join(root, 'secret.md'),
      '# Notes\n\nKey: sk-abcdefghijklmnop1234',
    );
    writeFileSync(join(root, 'big.md'), 'x'.repeat(200_001));
    writeFileSync(join(root, 'empty.md'), '   ');
    writeFileSync(join(root, 'ok.md'), '# Fine\n\nHarmless text.');
    const project = projects.create({ name: 'P' });
    const result = await documents.reference({
      projectId: project.id,
      path: '.',
    });
    expect(result.added.map((d) => d.title)).toEqual(['Fine']);
    expect(result.skipped.map((s) => s.path).sort()).toEqual([
      'big.md',
      'empty.md',
      'secret.md',
    ]);
    expect(documents.retrieve(project.id, 'sk-abcdefghijklmnop1234')).toEqual(
      [],
    );
  });

  it('stores uploads safely inside the folder and they are then retrievable', async () => {
    const { root, projects, documents } = setup();
    const project = projects.create({ name: 'P' });
    const text = (value: string) => new TextEncoder().encode(value);
    const stored = documents.store([
      {
        name: '../../evil name!.md',
        bytes: text('# Rules\n\nBikes ship in boxes.'),
      },
      {
        name: '../../evil name!.md',
        bytes: text('# Again\n\nSecond copy of the rules.'),
      },
      { name: 'photo.png', bytes: text('x') },
      { name: 'empty.txt', bytes: text('') },
      { name: 'big.txt', bytes: new Uint8Array(200_001).fill(97) },
    ]);
    expect(stored.rejected.map((r) => r.name).sort()).toEqual([
      'big.txt',
      'empty.txt',
      'photo.png',
    ]);
    expect(stored.paths).toHaveLength(2);
    expect(new Set(stored.paths).size).toBe(2);
    for (const path of stored.paths) {
      expect(path).toMatch(
        /^uploads\/evil name_\.md$|^uploads\/evil name_-[0-9a-f]{8}\.md$/,
      );
      expect(existsSync(join(root, path))).toBe(true);
      await documents.reference({ projectId: project.id, path });
    }
    expect(documents.retrieve(project.id, 'bikes boxes')[0]?.text).toContain(
      'Bikes ship',
    );
    expect(
      documents.store(
        Array.from({ length: 12 }, (_, i) => ({
          name: `n${i}.md`,
          bytes: text('# T\n\nhello world'),
        })),
      ).rejected,
    ).toHaveLength(2);
  });

  it('refuses to reference anything when no folder is configured', async () => {
    const { projects, documents } = setup(false);
    const project = projects.create({ name: 'P' });
    expect(documents.configured).toBe(false);
    await expect(
      documents.reference({ projectId: project.id, path: '.' }),
    ).rejects.toThrow('No reference');
    expect(() => documents.store([])).toThrow('No reference');
  });

  it('neutralizes FTS operators and chunks long text within bounds', () => {
    expect(toFtsQuery('refund AND "x" OR NEAR(a b) * ^')).toBe(
      '"refund" OR "and" OR "near"',
    );
    expect(toFtsQuery('a b')).toBeNull();
    const chunks = chunkText(
      `${'word '.repeat(500)}\n\n${'more '.repeat(300)}`,
    );
    expect(chunks.length).toBeGreaterThan(2);
    for (const chunk of chunks) expect(chunk.length).toBeLessThanOrEqual(800);
    const { projects, documents } = setup();
    const project = projects.create({ name: 'P' });
    expect(documents.retrieve(project.id, 'refund" OR (x')).toEqual([]);
  });
});

describe('knowledge reaches the model', () => {
  it('injects context into the system prompt and untrusted excerpts into the call only', async () => {
    const { root, db, projects, context, documents, guard } = setup();
    writeFileSync(
      join(root, 'returns.md'),
      '# Returns\n\nRefunds take 7 business days.',
    );
    const project = projects.create({ name: 'P' });
    context.add({
      projectId: project.id,
      kind: 'goal',
      text: 'Answer support questions',
    });
    await documents.reference({ projectId: project.id, path: 'returns.md' });
    const faux = fauxProvider();
    const registry = createModels();
    registry.setProvider(faux.provider);
    const models: AgentModels = {
      open: async () => ({
        model: faux.getModel(),
        streamFn: (m, c, o) => registry.streamSimple(m, c, o),
        getApiKey: () => 'unused',
        describeError: (raw) => raw,
      }),
    };
    let system = '';
    let lastUser = '';
    faux.setResponses([
      (ctx) => {
        system = String(ctx.messages.find((m) => m.role === 'system')?.content);
        const user = ctx.messages.findLast((m) => m.role === 'user');
        lastUser = JSON.stringify(user?.content);
        return fauxAssistantMessage('Seven days [Returns].');
      },
    ]);
    const repository = new SqliteSessions(db);
    const sessions = new SessionService(repository, new SqliteProjects(db));
    const runner = new RunService(repository, models, {
      guard,
      knowledge: {
        context: (id) => context.render(id),
        retrieve: (id, query) => documents.retrieve(id, query),
      },
    });
    const session = sessions.createSession({
      projectId: project.id,
      model: { provider: 'ollama', modelId: 'faux' },
    });
    const run = runner.enqueue({
      sessionId: session.id,
      prompt: 'How long do refunds take?',
    });
    await runner.idle();

    expect(sessions.findRun(run.id)?.status).toBe('completed');
    expect(system).toContain('Answer support questions');
    expect(lastUser).toContain('Refunds take 7 business days');
    expect(lastUser).toContain('untrusted reference data');
    expect(sessions.sources(run.id)).toEqual([
      expect.objectContaining({ title: 'Returns', seq: 0 }),
    ]);
    // Excerpts are not persisted: history holds the user's own words.
    expect(JSON.stringify(sessions.transcript(session.id))).not.toContain(
      'Refunds take 7',
    );
    expect(sessions.view(session.id)[0]).toEqual({
      role: 'user',
      text: 'How long do refunds take?',
    });
  });
});

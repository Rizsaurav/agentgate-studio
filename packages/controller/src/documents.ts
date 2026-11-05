import { randomUUID } from 'node:crypto';
import {
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {
  basename,
  dirname,
  extname,
  isAbsolute,
  join,
  relative,
  resolve,
} from 'node:path';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import { detectSecrets, safeExcerpt } from './policy';
import { projectDocumentPathSchema } from './project-import';
import { projectIdSchema, type ProjectRepository } from './projects';

const MAX_FILE_BYTES = 200_000;
const MAX_FILES = 50;
const MAX_UPLOADS = 10;
const UPLOAD_FOLDER = 'uploads';
const MAX_CHUNK_CHARS = 800;
const ALLOWED_EXTENSIONS = ['.md', '.txt'];
export const DEFAULT_PASSAGES = 4;

export const documentStatusSchema = z.enum(['active', 'quarantined']);
export const documentSchema = z
  .object({
    id: z.uuid(),
    projectId: projectIdSchema,
    title: z.string().min(1),
    path: z.string().min(1),
    status: documentStatusSchema,
    createdAt: z.iso.datetime(),
    chunkCount: z.number().int().nonnegative(),
    /** Passages the scanner flagged; they never reach a model unless the user releases them. */
    withheld: z.number().int().nonnegative(),
  })
  .strict();
export type Document = z.infer<typeof documentSchema>;
export const passageSchema = z
  .object({
    documentId: z.uuid(),
    title: z.string(),
    path: z.string(),
    seq: z.number().int(),
    text: z.string(),
    /** The user reviewed this flagged passage and released it, so it is not scanned again. */
    released: z.boolean(),
  })
  .strict();
export type Passage = z.infer<typeof passageSchema>;
export const referenceSchema = z
  .object({
    projectId: projectIdSchema,
    path: z.string().trim().min(1, 'Enter a path.').max(300),
  })
  .strict();

export type NewDocument = {
  id: string;
  projectId: string;
  title: string;
  path: string;
  createdAt: string;
  chunks: string[];
  /** Indexes into `chunks` that the scanner flagged. */
  withheld: number[];
};
export interface DocumentRepository {
  add(document: NewDocument): void;
  list(projectId: string): Document[];
  remove(projectId: string, id: string): void;
  search(projectId: string, ftsQuery: string, limit: number): Passage[];
  withhold(projectId: string, documentId: string, seqs: number[]): void;
  release(projectId: string, documentId: string, seq: number): boolean;
  withheldPassages(
    projectId: string,
    documentId: string,
  ): { seq: number; text: string }[];
}

export type ReferenceResult = {
  added: Document[];
  quarantined: { document: Document; reason: string }[];
  skipped: { path: string; reason: string }[];
};

/** Returns the indexes of chunks that must be withheld; throws if the document could not be checked. */
export type DocumentScreen = (
  document: {
    projectId: string;
    documentId: string;
    title: string;
    path: string;
  },
  chunks: string[],
) => Promise<{ withheld: number[] }>;

// Zero-width, bidirectional and Unicode tag characters can hide text from a reader but not from a model.
const INVISIBLE =
  /[\u0000-\u0008\u000b-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]|[\u{e0000}-\u{e007f}]/gu;

/**
 * Removes invisible characters and layout whitespace before chunking, so the scanner and the model
 * read the same plain text. Text converted from PDFs is padded with runs of spaces that make
 * ordinary prose look like injected instructions; Markdown keeps its indentation for code blocks.
 */
export function normalizeText(text: string, extension: string): string {
  const keepIndent = extension === '.md';
  return text
    .replace(/\r\n?/g, '\n')
    .replace(INVISIBLE, '')
    .split('\n')
    .map((line) => {
      const indent = keepIndent ? (/^[ \t]*/.exec(line)?.[0] ?? '') : '';
      return (
        indent +
        line
          .slice(indent.length)
          .replace(/[ \t]+/g, ' ')
          .trim()
      );
    })
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** Splits on blank lines, then packs paragraphs into chunks of bounded size. */
export function chunkText(text: string): string[] {
  const chunks: string[] = [];
  let current = '';
  for (const paragraph of text.split(/\n\s*\n/)) {
    const piece = paragraph.trim();
    if (!piece) continue;
    if (current && current.length + piece.length + 2 > MAX_CHUNK_CHARS) {
      chunks.push(current);
      current = '';
    }
    for (let i = 0; i < piece.length; i += MAX_CHUNK_CHARS) {
      const part = piece.slice(i, i + MAX_CHUNK_CHARS);
      current = current ? `${current}\n\n${part}` : part;
      if (current.length >= MAX_CHUNK_CHARS) {
        chunks.push(current);
        current = '';
      }
    }
  }
  if (current) chunks.push(current);
  return chunks;
}

/** Every term is quoted, so user text cannot inject FTS5 operators. */
export function toFtsQuery(text: string): string | null {
  const terms = [
    ...new Set(text.toLowerCase().match(/[\p{L}\p{N}]{3,}/gu) ?? []),
  ].slice(0, 12);
  return terms.length > 0
    ? terms.map((term) => `"${term}"`).join(' OR ')
    : null;
}

export class SqliteDocuments implements DocumentRepository {
  constructor(private readonly db: Database.Database) {}

  add(document: NewDocument): void {
    this.db.transaction(() => {
      this.db
        .prepare(
          'INSERT INTO documents (id, project_id, title, path, status, created_at) VALUES (?, ?, ?, ?, ?, ?)',
        )
        .run(
          document.id,
          document.projectId,
          document.title,
          document.path,
          document.withheld.length === document.chunks.length
            ? 'quarantined'
            : 'active',
          document.createdAt,
        );
      const insertChunk = this.db.prepare(
        'INSERT INTO chunks (document_id, seq, text, state) VALUES (?, ?, ?, ?)',
      );
      const insertFts = this.db.prepare(
        'INSERT INTO chunks_fts (rowid, text) VALUES (?, ?)',
      );
      document.chunks.forEach((text, seq) => {
        const { lastInsertRowid } = insertChunk.run(
          document.id,
          seq,
          text,
          document.withheld.includes(seq) ? 'withheld' : 'ok',
        );
        insertFts.run(lastInsertRowid, text);
      });
    })();
  }

  list(projectId: string): Document[] {
    return z.array(documentSchema).parse(
      this.db
        .prepare(
          `SELECT d.id, d.project_id AS projectId, d.title, d.path, d.status, d.created_at AS createdAt,
                  (SELECT COUNT(*) FROM chunks c WHERE c.document_id = d.id) AS chunkCount,
                  (SELECT COUNT(*) FROM chunks c WHERE c.document_id = d.id AND c.state = 'withheld') AS withheld
           FROM documents d WHERE d.project_id = ? ORDER BY d.created_at, d.id`,
        )
        .all(projectId),
    );
  }

  withhold(projectId: string, documentId: string, seqs: number[]): void {
    this.db.transaction(() => {
      const mark = this.db.prepare(
        `UPDATE chunks SET state = 'withheld' WHERE document_id = ? AND seq = ? AND state = 'ok'
         AND document_id IN (SELECT id FROM documents WHERE project_id = ?)`,
      );
      for (const seq of seqs) mark.run(documentId, seq, projectId);
      this.refreshStatus(projectId, documentId);
    })();
  }

  release(projectId: string, documentId: string, seq: number): boolean {
    return this.db.transaction(() => {
      const { changes } = this.db
        .prepare(
          `UPDATE chunks SET state = 'released' WHERE document_id = ? AND seq = ? AND state = 'withheld'
           AND document_id IN (SELECT id FROM documents WHERE project_id = ?)`,
        )
        .run(documentId, seq, projectId);
      this.refreshStatus(projectId, documentId);
      return changes > 0;
    })();
  }

  withheldPassages(
    projectId: string,
    documentId: string,
  ): { seq: number; text: string }[] {
    return z.array(z.object({ seq: z.number().int(), text: z.string() })).parse(
      this.db
        .prepare(
          `SELECT c.seq, c.text FROM chunks c JOIN documents d ON d.id = c.document_id
             WHERE d.project_id = ? AND d.id = ? AND c.state = 'withheld' ORDER BY c.seq`,
        )
        .all(projectId, documentId),
    );
  }

  /** A document is quarantined only when none of its passages may be used. */
  private refreshStatus(projectId: string, documentId: string): void {
    this.db
      .prepare(
        `UPDATE documents SET status = CASE WHEN EXISTS
           (SELECT 1 FROM chunks WHERE document_id = documents.id AND state != 'withheld')
           THEN 'active' ELSE 'quarantined' END
         WHERE project_id = ? AND id = ?`,
      )
      .run(projectId, documentId);
  }

  remove(projectId: string, id: string): void {
    this.db.transaction(() => {
      const owned = this.db
        .prepare('SELECT 1 FROM documents WHERE id = ? AND project_id = ?')
        .get(id, projectId);
      if (!owned) return;
      this.db
        .prepare(
          'DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE document_id = ?)',
        )
        .run(id);
      this.db.prepare('DELETE FROM chunks WHERE document_id = ?').run(id);
      this.db.prepare('DELETE FROM documents WHERE id = ?').run(id);
    })();
  }

  search(projectId: string, ftsQuery: string, limit: number): Passage[] {
    return z.array(passageSchema).parse(
      this.db
        .prepare(
          `SELECT d.id AS documentId, d.title, d.path, c.seq, c.text, c.state = 'released' AS released
           FROM chunks_fts f
           JOIN chunks c ON c.id = f.rowid
           JOIN documents d ON d.id = c.document_id
           WHERE chunks_fts MATCH ? AND d.project_id = ? AND c.state != 'withheld'
           ORDER BY bm25(chunks_fts) LIMIT ?`,
        )
        .all(ftsQuery, projectId, limit)
        .map((row) => ({
          ...(row as Record<string, unknown>),
          released: (row as { released: number }).released === 1,
        })),
    );
  }
}

/** Writes a file only if it does not exist yet; returns whether it was written. */
function writeNew(path: string, bytes: Uint8Array): boolean {
  try {
    writeFileSync(path, bytes, { flag: 'wx' });
    return true;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') return false;
    throw error;
  }
}

/** Reference documents confined to one approved root directory. */
export class DocumentService {
  private readonly root: string | null;

  constructor(
    private readonly repository: DocumentRepository,
    private readonly projects: ProjectRepository,
    root: string | null,
    private readonly screen: DocumentScreen,
  ) {
    this.root = root === null ? null : realpathSync(resolve(root));
  }

  get configured(): boolean {
    return this.root !== null;
  }

  /**
   * Saves uploaded files inside the reference folder and returns their paths for `reference`.
   * Names are reduced to a safe basename; content is judged later by the same checks as any file.
   */
  store(files: { name: string; bytes: Uint8Array }[]): {
    paths: string[];
    rejected: { name: string; reason: string }[];
  } {
    if (this.root === null)
      throw new Error('No reference document folder is configured.');
    const folder = join(this.root, UPLOAD_FOLDER);
    mkdirSync(folder, { recursive: true });
    const paths: string[] = [];
    const rejected: { name: string; reason: string }[] = [];
    for (const file of files.slice(0, MAX_UPLOADS)) {
      const name = basename(file.name)
        .replace(/[^A-Za-z0-9._ -]/g, '_')
        .replace(/^\.+/, '_');
      if (!ALLOWED_EXTENSIONS.includes(extname(name)))
        rejected.push({
          name,
          reason: 'Only .md and .txt files are supported.',
        });
      else if (file.bytes.length === 0)
        rejected.push({ name, reason: 'The file is empty.' });
      else if (file.bytes.length > MAX_FILE_BYTES)
        rejected.push({ name, reason: 'The file is too large.' });
      else {
        // "wx" never overwrites: a name already used by an earlier upload gets a unique suffix.
        const extension = extname(name);
        const stem = name.slice(0, name.length - extension.length);
        let saved = name;
        if (!writeNew(join(folder, saved), file.bytes)) {
          saved = `${stem}-${randomUUID().slice(0, 8)}${extension}`;
          if (!writeNew(join(folder, saved), file.bytes))
            throw new Error('The file could not be saved.');
        }
        paths.push(`${UPLOAD_FOLDER}/${saved}`);
      }
    }
    for (const file of files.slice(MAX_UPLOADS))
      rejected.push({
        name: basename(file.name),
        reason: `Only ${MAX_UPLOADS} files can be added at once.`,
      });
    return { paths, rejected };
  }

  /** Stores manifest-selected files under a unique confined folder for normal reference checks. */
  storeProjectImport(files: { path: string; bytes: Uint8Array }[]): string[] {
    const root = this.root;
    if (root === null)
      throw new Error('No reference document folder is configured.');
    if (files.length === 0 || files.length > MAX_FILES)
      throw new Error(`Import between 1 and ${MAX_FILES} documents.`);
    const paths = files.map((file) =>
      projectDocumentPathSchema.parse(file.path),
    );
    if (new Set(paths).size !== paths.length)
      throw new Error('Imported document paths must be unique.');
    for (const [index, file] of files.entries()) {
      if (file.bytes.length === 0)
        throw new Error(`The imported file ${paths[index]} is empty.`);
      if (file.bytes.length > MAX_FILE_BYTES)
        throw new Error(`The imported file ${paths[index]} is too large.`);
    }

    const uploadRoot = join(root, UPLOAD_FOLDER);
    mkdirSync(uploadRoot, { recursive: true, mode: 0o700 });
    const realUploadRoot = realpathSync(uploadRoot);
    const uploadRootRelative = relative(root, realUploadRoot);
    if (uploadRootRelative.startsWith('..') || isAbsolute(uploadRootRelative))
      throw new Error('The upload folder is outside the reference folder.');

    const folder = join(uploadRoot, `import-${randomUUID()}`);
    mkdirSync(folder, { mode: 0o700 });
    try {
      return files.map((file, index) => {
        const path = paths[index];
        if (!path) throw new Error('An imported document path is missing.');
        const target = join(folder, ...path.split('/'));
        mkdirSync(dirname(target), { recursive: true, mode: 0o700 });
        const realParent = realpathSync(dirname(target));
        const parentRelative = relative(folder, realParent);
        if (parentRelative.startsWith('..') || isAbsolute(parentRelative))
          throw new Error('An imported document path is outside its folder.');
        writeFileSync(target, file.bytes, { flag: 'wx', mode: 0o600 });
        return relative(root, target);
      });
    } catch (error) {
      rmSync(folder, { recursive: true, force: true });
      throw error;
    }
  }

  async reference(input: unknown): Promise<ReferenceResult> {
    const { projectId, path } = referenceSchema.parse(input);
    if (!this.projects.find(projectId)) throw new Error('Unknown project.');
    const target = this.confine(path);
    const files = statSync(target).isDirectory()
      ? readdirSync(target)
          .filter((name) => ALLOWED_EXTENSIONS.includes(extname(name)))
          .sort()
          .slice(0, MAX_FILES)
          .map((name) => join(target, name))
      : [target];
    const existing = new Set(
      this.repository.list(projectId).map((document) => document.path),
    );
    const result: ReferenceResult = { added: [], quarantined: [], skipped: [] };
    for (const file of files) {
      const display = this.display(file);
      const skip = (reason: string) =>
        result.skipped.push({ path: display, reason });
      if (existing.has(display)) {
        skip('Already referenced.');
        continue;
      }
      const text = this.read(file);
      if (typeof text !== 'string') {
        skip(text.reason);
        continue;
      }
      const chunks = chunkText(normalizeText(text, extname(file)));
      if (detectSecrets(text).length > 0) {
        skip('Contains what looks like a credential, so it was not ingested.');
        continue;
      }
      if (chunks.length === 0) {
        skip('The file is empty.');
        continue;
      }
      const metadata = {
        id: randomUUID(),
        projectId,
        title: titleOf(text, file),
        path: display,
        createdAt: new Date().toISOString(),
      };
      const { withheld } = await this.screen(
        {
          projectId,
          documentId: metadata.id,
          title: metadata.title,
          path: display,
        },
        chunks,
      );
      this.repository.add({ ...metadata, chunks, withheld });
      const document = documentSchema.parse({
        ...metadata,
        status: withheld.length === chunks.length ? 'quarantined' : 'active',
        chunkCount: chunks.length,
        withheld: withheld.length,
      });
      if (document.status === 'active') result.added.push(document);
      else
        result.quarantined.push({
          document,
          reason: 'Every passage contains instructions aimed at the model.',
        });
    }
    return result;
  }

  withhold(projectId: string, documentId: string, seqs: number[]): void {
    this.repository.withhold(projectId, documentId, seqs);
  }

  /** Withheld passages for review, whole (a reviewer must see all of it), unless they hold a credential. */
  withheldPassages(
    projectId: unknown,
    documentId: unknown,
  ): { seq: number; excerpt: string }[] {
    return this.repository
      .withheldPassages(
        projectIdSchema.parse(projectId),
        z.uuid().parse(documentId),
      )
      .map(({ seq, text }) => ({
        seq,
        excerpt:
          safeExcerpt(text, MAX_CHUNK_CHARS) ??
          'Hidden: it looks like a credential.',
      }));
  }

  /**
   * The user reviewed a withheld passage and accepts it, so it reaches the model unscanned from now
   * on. Returns what was released, for the security record, or null if nothing was withheld there.
   */
  release(
    projectId: unknown,
    documentId: unknown,
    seq: unknown,
  ): { document: Document; excerpt: string } | null {
    const project = projectIdSchema.parse(projectId);
    const id = z.uuid().parse(documentId);
    const index = z.coerce.number().int().nonnegative().parse(seq);
    const passage = this.withheldPassages(project, id).find(
      (candidate) => candidate.seq === index,
    );
    if (!passage || !this.repository.release(project, id, index)) return null;
    const document = this.list(project).find((d) => d.id === id);
    return document ? { document, excerpt: passage.excerpt } : null;
  }

  list(projectId: unknown): Document[] {
    return this.repository.list(projectIdSchema.parse(projectId));
  }

  remove(projectId: unknown, id: unknown): void {
    this.repository.remove(
      projectIdSchema.parse(projectId),
      z.uuid().parse(id),
    );
  }

  retrieve(
    projectId: unknown,
    query: string,
    limit = DEFAULT_PASSAGES,
  ): Passage[] {
    const ftsQuery = toFtsQuery(query);
    return ftsQuery === null
      ? []
      : this.repository.search(
          projectIdSchema.parse(projectId),
          ftsQuery,
          limit,
        );
  }

  /** Resolve symlinks first so a link inside the root cannot point outside it. */
  private confine(path: string): string {
    if (this.root === null)
      throw new Error('No reference document folder is configured.');
    if (isAbsolute(path) || path.includes('\0'))
      throw new Error('Use a path relative to the reference folder.');
    let real: string;
    try {
      real = realpathSync(resolve(this.root, path));
    } catch {
      throw new Error('That path does not exist in the reference folder.');
    }
    const inside = relative(this.root, real);
    if (inside.startsWith('..') || isAbsolute(inside))
      throw new Error('That path is outside the reference folder.');
    return real;
  }

  private display(file: string): string {
    return this.root === null
      ? file
      : relative(this.root, file) || basename(file);
  }

  private read(file: string): string | { reason: string } {
    const info = statSync(file);
    if (!info.isFile()) return { reason: 'Not a regular file.' };
    if (!ALLOWED_EXTENSIONS.includes(extname(file)))
      return { reason: 'Only .md and .txt files are supported.' };
    if (info.size > MAX_FILE_BYTES) return { reason: 'The file is too large.' };
    const text = readFileSync(file, 'utf8');
    return text.includes('\0') ? { reason: 'Not a text file.' } : text;
  }
}

function titleOf(text: string, file: string): string {
  const heading = /^#\s+(.+)$/m.exec(text)?.[1]?.trim();
  return (heading ?? basename(file, extname(file))).slice(0, 120);
}

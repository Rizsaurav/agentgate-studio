import { randomUUID } from 'node:crypto';
import {
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import {
  basename,
  extname,
  isAbsolute,
  join,
  relative,
  resolve,
} from 'node:path';
import type Database from 'better-sqlite3';
import { z } from 'zod';
import { detectSecrets } from './policy';
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
  status: Document['status'];
  createdAt: string;
  chunks: string[];
};
export interface DocumentRepository {
  add(document: NewDocument): void;
  list(projectId: string): Document[];
  remove(projectId: string, id: string): void;
  search(projectId: string, ftsQuery: string, limit: number): Passage[];
  quarantine(projectId: string, id: string): void;
}

export type ReferenceResult = {
  added: Document[];
  quarantined: { document: Document; reason: string }[];
  skipped: { path: string; reason: string }[];
};

/** Decides whether an ingested document may be used; throws if it could not be checked. */
export type DocumentScreen = (
  document: {
    projectId: string;
    documentId: string;
    title: string;
    path: string;
  },
  chunks: string[],
) => Promise<{ allowed: true } | { allowed: false; reason: string }>;

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
          document.status,
          document.createdAt,
        );
      const insertChunk = this.db.prepare(
        'INSERT INTO chunks (document_id, seq, text) VALUES (?, ?, ?)',
      );
      const insertFts = this.db.prepare(
        'INSERT INTO chunks_fts (rowid, text) VALUES (?, ?)',
      );
      document.chunks.forEach((text, seq) => {
        const { lastInsertRowid } = insertChunk.run(document.id, seq, text);
        insertFts.run(lastInsertRowid, text);
      });
    })();
  }

  list(projectId: string): Document[] {
    return z.array(documentSchema).parse(
      this.db
        .prepare(
          `SELECT d.id, d.project_id AS projectId, d.title, d.path, d.status, d.created_at AS createdAt,
                  (SELECT COUNT(*) FROM chunks c WHERE c.document_id = d.id) AS chunkCount
           FROM documents d WHERE d.project_id = ? ORDER BY d.created_at, d.id`,
        )
        .all(projectId),
    );
  }

  quarantine(projectId: string, id: string): void {
    this.db
      .prepare(
        "UPDATE documents SET status = 'quarantined' WHERE project_id = ? AND id = ?",
      )
      .run(projectId, id);
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
          `SELECT d.id AS documentId, d.title, d.path, c.seq, c.text
           FROM chunks_fts f
           JOIN chunks c ON c.id = f.rowid
           JOIN documents d ON d.id = c.document_id
           WHERE chunks_fts MATCH ? AND d.project_id = ? AND d.status = 'active'
           ORDER BY bm25(chunks_fts) LIMIT ?`,
        )
        .all(ftsQuery, projectId, limit),
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
      const chunks = chunkText(text);
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
      const verdict = await this.screen(
        {
          projectId,
          documentId: metadata.id,
          title: metadata.title,
          path: display,
        },
        chunks,
      );
      const status = verdict.allowed
        ? ('active' as const)
        : ('quarantined' as const);
      this.repository.add({ ...metadata, status, chunks });
      const document = documentSchema.parse({
        ...metadata,
        status,
        chunkCount: chunks.length,
      });
      if (verdict.allowed) result.added.push(document);
      else result.quarantined.push({ document, reason: verdict.reason });
    }
    return result;
  }

  quarantine(projectId: string, documentId: string): void {
    this.repository.quarantine(projectId, documentId);
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

import type Database from 'better-sqlite3';
import {
  DocumentService,
  ProtectionPipeline,
  SqliteDocuments,
  SqliteProjects,
  SqliteSecurityEvents,
  type InjectionScanner,
  type SecretBackend,
} from './index';

/** Deterministic stand-in for the scanner service in logic tests; flags text containing a marker. */
export function markerScanner(
  marker = 'IGNORE ALL PREVIOUS',
): InjectionScanner {
  return {
    scan: async (texts) =>
      texts.map((text) => ({
        injection: text.toUpperCase().includes(marker),
        score: text.toUpperCase().includes(marker) ? 1 : 0,
      })),
  };
}

export function protection(
  db: Database.Database,
  scanner: InjectionScanner,
  root: string | null = null,
) {
  const projects = new SqliteProjects(db);
  const documentRepository = new SqliteDocuments(db);
  const events = new SqliteSecurityEvents(db);
  const guard = new ProtectionPipeline(scanner, events, (projectId, id) =>
    documentRepository.quarantine(projectId, id),
  );
  const documents = new DocumentService(
    documentRepository,
    projects,
    root,
    async (document, chunks) => guard.screenDocument(document, chunks),
  );
  return { guard, events, documents };
}

/** In-memory secret backend for tests; never touches the OS credential store. */
export class MemoryBackend implements SecretBackend {
  readonly values = new Map<string, string>();
  async get(account: string) {
    return this.values.get(account) ?? null;
  }
  async set(account: string, secret: string) {
    this.values.set(account, secret);
  }
  async delete(account: string) {
    this.values.delete(account);
  }
}

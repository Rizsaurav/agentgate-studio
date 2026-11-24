import type Database from 'better-sqlite3';
import {
  DocumentService,
  ProtectionPipeline,
  ScannerUnavailableError,
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
  const guard = new ProtectionPipeline(scanner, events, (projectId, id, seqs) =>
    documentRepository.withhold(projectId, id, seqs),
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

/** Scanner that throws a scanner-unavailable error only for matching texts. */
export function scannerThatThrowsOn(needle: string): InjectionScanner {
  return {
    scan: async (texts) => {
      if (texts.some((text) => text.includes(needle)))
        throw new ScannerUnavailableError('scanner unavailable');
      return texts.map(() => ({ injection: false, score: 0 }));
    },
  };
}

import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import Database from 'better-sqlite3';

const PROJECTS = `CREATE TABLE projects (
  id TEXT PRIMARY KEY NOT NULL,
  name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 80),
  created_at TEXT NOT NULL
) STRICT`;

const SESSIONS = `
CREATE TABLE sessions (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id),
  provider TEXT NOT NULL,
  model_id TEXT NOT NULL,
  created_at TEXT NOT NULL
) STRICT;
CREATE TABLE messages (
  session_id TEXT NOT NULL REFERENCES sessions(id),
  seq INTEGER NOT NULL,
  payload TEXT NOT NULL,
  PRIMARY KEY (session_id, seq)
) STRICT;
CREATE TABLE runs (
  id TEXT PRIMARY KEY NOT NULL,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  prompt TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('queued','running','completed','failed','cancelled')),
  error TEXT,
  created_at TEXT NOT NULL,
  finished_at TEXT
) STRICT;
CREATE TABLE run_events (
  run_id TEXT NOT NULL REFERENCES runs(id),
  seq INTEGER NOT NULL,
  type TEXT NOT NULL,
  text TEXT NOT NULL,
  PRIMARY KEY (run_id, seq)
) STRICT;`;

const CONTEXT_AND_DOCUMENTS = `
CREATE TABLE context_items (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id),
  kind TEXT NOT NULL CHECK(kind IN ('goal','decision','outcome')),
  text TEXT NOT NULL CHECK(length(text) BETWEEN 1 AND 500),
  created_at TEXT NOT NULL
) STRICT;
CREATE TABLE documents (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL REFERENCES projects(id),
  title TEXT NOT NULL,
  path TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('active','quarantined')),
  created_at TEXT NOT NULL,
  UNIQUE (project_id, path)
) STRICT;
CREATE TABLE chunks (
  id INTEGER PRIMARY KEY,
  document_id TEXT NOT NULL REFERENCES documents(id),
  seq INTEGER NOT NULL,
  text TEXT NOT NULL
) STRICT;
CREATE VIRTUAL TABLE chunks_fts USING fts5(text, tokenize = 'porter unicode61');`;

const SECURITY = `
CREATE TABLE runs_new (
  id TEXT PRIMARY KEY NOT NULL,
  session_id TEXT NOT NULL REFERENCES sessions(id),
  prompt TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('queued','running','completed','failed','cancelled','blocked')),
  error TEXT,
  created_at TEXT NOT NULL,
  finished_at TEXT
) STRICT;
INSERT INTO runs_new SELECT id, session_id, prompt, status, error, created_at, finished_at FROM runs;
DROP TABLE runs;
ALTER TABLE runs_new RENAME TO runs;
CREATE TABLE security_events (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL,
  run_id TEXT,
  document_id TEXT,
  stage TEXT NOT NULL CHECK(stage IN ('input','ingestion','retrieval','output')),
  rule TEXT NOT NULL,
  source TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK(outcome IN ('blocked','quarantined','excluded')),
  detail TEXT NOT NULL,
  evidence TEXT,
  score REAL,
  created_at TEXT NOT NULL
) STRICT;
CREATE INDEX security_events_by_time ON security_events(created_at DESC);`;

const EVALUATIONS = `
CREATE TABLE eval_runs (
  id TEXT PRIMARY KEY NOT NULL,
  profile TEXT NOT NULL CHECK(profile IN ('enforced','weak-demo')),
  status TEXT NOT NULL CHECK(status IN ('queued','running','passed','failed','error')),
  config_hash TEXT NOT NULL,
  git_sha TEXT,
  git_dirty INTEGER NOT NULL CHECK(git_dirty IN (0,1)),
  total INTEGER NOT NULL DEFAULT 0,
  passed INTEGER NOT NULL DEFAULT 0,
  failed INTEGER NOT NULL DEFAULT 0,
  error TEXT,
  created_at TEXT NOT NULL,
  finished_at TEXT
) STRICT;
CREATE TABLE eval_results (
  run_id TEXT NOT NULL REFERENCES eval_runs(id),
  idx INTEGER NOT NULL,
  description TEXT NOT NULL,
  passed INTEGER NOT NULL CHECK(passed IN (0,1)),
  reason TEXT,
  PRIMARY KEY (run_id, idx)
) STRICT;`;

const AGENT = `
CREATE TABLE agent_usage (
  day TEXT PRIMARY KEY NOT NULL,
  tokens INTEGER NOT NULL DEFAULT 0,
  calls INTEGER NOT NULL DEFAULT 0
) STRICT;
CREATE TABLE agent_settings (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
) STRICT;
CREATE TABLE agent_notes (
  id TEXT PRIMARY KEY NOT NULL,
  created_at TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('question','answer','finding','action','proposal')),
  finding_id TEXT,
  text TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','approved','dismissed'))
) STRICT;
CREATE INDEX agent_notes_created ON agent_notes(created_at);`;

// Passages are withheld one at a time; documents quarantined before this held no per-passage verdict,
// so all their passages start withheld (fail closed) and can be reviewed and released.
const WITHHELD_PASSAGES = `
ALTER TABLE chunks ADD COLUMN state TEXT NOT NULL DEFAULT 'ok' CHECK(state IN ('ok','withheld','released'));
UPDATE chunks SET state = 'withheld' WHERE document_id IN (SELECT id FROM documents WHERE status = 'quarantined');
CREATE TABLE security_events_new (
  id TEXT PRIMARY KEY NOT NULL,
  project_id TEXT NOT NULL,
  run_id TEXT,
  document_id TEXT,
  stage TEXT NOT NULL CHECK(stage IN ('input','ingestion','retrieval','output')),
  rule TEXT NOT NULL,
  source TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK(outcome IN ('blocked','quarantined','excluded','released')),
  detail TEXT NOT NULL,
  evidence TEXT,
  score REAL,
  created_at TEXT NOT NULL
) STRICT;
INSERT INTO security_events_new SELECT * FROM security_events;
DROP TABLE security_events;
ALTER TABLE security_events_new RENAME TO security_events;
CREATE INDEX security_events_by_time ON security_events(created_at DESC);`;

/** Ordered migrations; PRAGMA user_version is the number applied. Never edit an applied entry. */
const MIGRATIONS = [
  PROJECTS,
  SESSIONS,
  CONTEXT_AND_DOCUMENTS,
  SECURITY,
  EVALUATIONS,
  AGENT,
  WITHHELD_PASSAGES,
];

/** Single owner of the application database file, schema, and migrations. */
export function openDatabase(filename: string): Database.Database {
  if (filename !== ':memory:') {
    mkdirSync(dirname(filename), { recursive: true, mode: 0o700 });
  }
  const db = new Database(filename);
  try {
    if (filename !== ':memory:') chmodSync(filename, 0o600);
    db.pragma('foreign_keys = ON');
    db.pragma('busy_timeout = 5000');
    db.pragma('journal_mode = WAL');
    const version = db.pragma('user_version', { simple: true });
    if (
      typeof version !== 'number' ||
      version < 0 ||
      version > MIGRATIONS.length
    )
      throw new Error('Unsupported database version.');
    // Table rebuilds need foreign keys off (SQLite's documented procedure); verify afterwards.
    db.pragma('foreign_keys = OFF');
    db.transaction(() => {
      MIGRATIONS.slice(version).forEach((migration) => db.exec(migration));
      if ((db.pragma('foreign_key_check') as unknown[]).length > 0)
        throw new Error('Migration left inconsistent foreign keys.');
      db.pragma(`user_version = ${MIGRATIONS.length}`);
    })();
    db.pragma('foreign_keys = ON');
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}

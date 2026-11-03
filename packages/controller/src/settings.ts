import type Database from 'better-sqlite3';

/** Small non-secret settings, one text value per key. Secrets belong in the credential store. */
export class SqliteSettings {
  constructor(private readonly db: Database.Database) {}

  get(key: string): string | undefined {
    const row = this.db
      .prepare('SELECT value FROM agent_settings WHERE key = ?')
      .get(key) as { value: string } | undefined;
    return row?.value;
  }

  set(key: string, value: string): void {
    this.db
      .prepare(
        'INSERT INTO agent_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      )
      .run(key, value);
  }

  delete(key: string): void {
    this.db.prepare('DELETE FROM agent_settings WHERE key = ?').run(key);
  }
}

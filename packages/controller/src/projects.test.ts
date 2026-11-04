import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';
import { ProjectService, SqliteProjects, openDatabase } from './index';

const directories: string[] = [];
const connections: Database.Database[] = [];
afterEach(() => {
  for (const connection of connections.splice(0)) connection.close();
  for (const directory of directories.splice(0))
    rmSync(directory, { recursive: true, force: true });
});
function setup() {
  const directory = mkdtempSync(join(tmpdir(), 'agentgate-'));
  directories.push(directory);
  const filename = join(directory, 'workspace', 'agentgate.sqlite');
  const db = openDatabase(filename);
  connections.push(db);
  return {
    filename,
    db,
    service: new ProjectService(new SqliteProjects(db)),
  };
}

describe('project persistence vertical slice', () => {
  it('creates a project and reopens the same data after the connection restarts', () => {
    const { filename, db, service } = setup();
    const project = service.create({ name: '  Reference RAG  ' });
    expect(project.name).toBe('Reference RAG');
    db.close();
    connections.pop();
    const reopened = openDatabase(filename);
    connections.push(reopened);
    const restarted = new ProjectService(new SqliteProjects(reopened));
    expect(restarted.list()).toEqual([project]);
    expect(restarted.find(project.id)).toEqual(project);
    expect(statSync(filename).mode & 0o777).toBe(0o600);
  });

  it.each([
    {},
    { name: '' },
    { name: '   ' },
    { name: 'a'.repeat(81) },
    { name: 'hidden\u0000text' },
    { name: 'x', apiKey: 'not-a-real-key' },
    { name: 42 },
  ])('rejects invalid input without writing: %j', (input) => {
    const { service } = setup();
    expect(() => service.create(input)).toThrow();
    expect(service.list()).toEqual([]);
  });

  it('stores SQL-looking text literally and permits duplicate display names', () => {
    const { service } = setup();
    const name = "'); DROP TABLE projects; --";
    const first = service.create({ name });
    const second = service.create({ name });
    expect(first.id).not.toBe(second.id);
    expect(service.list()).toHaveLength(2);
    expect(service.find(first.id)?.name).toBe(name);
  });

  it('distinguishes a missing project from an invalid identifier', () => {
    const { service } = setup();
    expect(service.find(randomUUID())).toBeNull();
    expect(() => service.find('../private')).toThrow();
  });

  it('rejects corrupt persisted output instead of returning it to the UI', () => {
    const { filename, service } = setup();
    const raw = new Database(filename);
    raw
      .prepare('INSERT INTO projects (id, name, created_at) VALUES (?, ?, ?)')
      .run('invalid-id', 'Project', 'not-a-date');
    raw.close();
    expect(() => service.list()).toThrow();
  });

  it('refuses unknown database versions without rewriting them', () => {
    const { filename, db } = setup();
    db.close();
    connections.pop();
    const raw = new Database(filename);
    raw.pragma('user_version = 99');
    expect(() => openDatabase(filename)).toThrow(
      'Unsupported database version',
    );
    expect(raw.pragma('user_version', { simple: true })).toBe(99);
    raw.close();
  });
});

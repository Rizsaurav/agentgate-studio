import { z } from 'zod';
import type Database from 'better-sqlite3';
import type { ContextService } from './context';
import type { DocumentService, ReferenceResult } from './documents';
import { detectSecrets } from './policy';
import type { Project, ProjectService } from './projects';
import { projectIdSchema, projectNameSchema } from './projects';

const manifestText = (max: number) =>
  z
    .string()
    .trim()
    .min(1)
    .max(max)
    .refine((text) => detectSecrets(text).length === 0, {
      message: 'Project manifests cannot contain credentials.',
    });

export const projectDocumentPathSchema = z
  .string()
  .min(1)
  .max(300)
  .refine(
    (path) =>
      !path.startsWith('/') &&
      !/^[A-Za-z]:/.test(path) &&
      !path.includes('\\') &&
      !/[\p{Cc}\p{Cf}]/u.test(path) &&
      path
        .split('/')
        .every((part) => part !== '' && part !== '.' && part !== '..') &&
      (path.endsWith('.md') || path.endsWith('.txt')),
    'Use a relative .md or .txt path inside the imported folder.',
  );

export const expectedBehaviorSchema = z
  .object({
    prompt: manifestText(500),
    outcome: z.enum(['allowed', 'blocked']),
  })
  .strict();

export const projectManifestSchema = z
  .object({
    name: projectNameSchema,
    goals: z.array(manifestText(500)).max(50).default([]),
    decisions: z.array(manifestText(500)).max(50).default([]),
    documents: z.array(projectDocumentPathSchema).min(1).max(50),
    suggestedQuestions: z.array(manifestText(250)).max(20).default([]),
    expectedBehaviors: z.array(expectedBehaviorSchema).max(50).default([]),
  })
  .strict()
  .superRefine((manifest, context) => {
    if (new Set(manifest.documents).size !== manifest.documents.length) {
      context.addIssue({
        code: 'custom',
        path: ['documents'],
        message: 'Document paths must be unique.',
      });
    }
  });
export type ProjectManifest = z.infer<typeof projectManifestSchema>;

export function parseProjectManifest(text: string): ProjectManifest {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error('The project manifest is not valid JSON.');
  }
  return projectManifestSchema.parse(value);
}

export const projectImportMetadataSchema = z
  .object({
    projectId: projectIdSchema,
    suggestedQuestions: z.array(manifestText(250)).max(20),
    expectedBehaviors: z.array(expectedBehaviorSchema).max(50),
  })
  .strict();
export type ProjectImportMetadata = z.infer<typeof projectImportMetadataSchema>;

export interface ProjectImportMetadataRepository {
  save(metadata: ProjectImportMetadata): void;
  find(projectId: string): ProjectImportMetadata | null;
}

export class SqliteProjectImports implements ProjectImportMetadataRepository {
  constructor(private readonly db: Database.Database) {}

  save(metadata: ProjectImportMetadata): void {
    const value = projectImportMetadataSchema.parse(metadata);
    this.db
      .prepare(
        `INSERT INTO project_import_metadata (project_id, suggested_questions, expected_behaviors)
         VALUES (?, ?, ?)
         ON CONFLICT(project_id) DO UPDATE SET
           suggested_questions = excluded.suggested_questions,
           expected_behaviors = excluded.expected_behaviors`,
      )
      .run(
        value.projectId,
        JSON.stringify(value.suggestedQuestions),
        JSON.stringify(value.expectedBehaviors),
      );
  }

  find(projectId: string): ProjectImportMetadata | null {
    const row = this.db
      .prepare(
        'SELECT suggested_questions AS suggestedQuestions, expected_behaviors AS expectedBehaviors FROM project_import_metadata WHERE project_id = ?',
      )
      .get(projectId) as
      { suggestedQuestions: string; expectedBehaviors: string } | undefined;
    if (!row) return null;
    const suggestedQuestions: unknown = JSON.parse(row.suggestedQuestions);
    const expectedBehaviors: unknown = JSON.parse(row.expectedBehaviors);
    return projectImportMetadataSchema.parse({
      projectId,
      suggestedQuestions,
      expectedBehaviors,
    });
  }
}

export class ProjectImportFailure extends Error {
  constructor(
    readonly projectId: string,
    message: string,
  ) {
    super(message);
    this.name = 'ProjectImportFailure';
  }
}

export class ProjectImportService {
  constructor(
    private readonly projects: ProjectService,
    private readonly context: ContextService,
    private readonly documents: DocumentService,
    private readonly metadata: ProjectImportMetadataRepository,
  ) {}

  async import(input: {
    manifestText: string;
    files: { path: string; bytes: Uint8Array }[];
  }): Promise<{ project: Project; references: ReferenceResult[] }> {
    if (Buffer.byteLength(input.manifestText, 'utf8') > 100_000)
      throw new Error('The project manifest is too large.');
    const manifest = parseProjectManifest(input.manifestText);
    if (
      input.files.length !== manifest.documents.length ||
      input.files.length === 0
    )
      throw new Error('Select every document listed in the project manifest.');
    const files = input.files.map((file) => ({
      path: projectDocumentPathSchema.parse(file.path),
      bytes: file.bytes,
    }));
    const paths = files.map((file) => file.path);
    if (
      new Set(paths).size !== paths.length ||
      manifest.documents.some((path) => !paths.includes(path))
    )
      throw new Error('The selected files do not match the project manifest.');
    for (const file of files) {
      if (file.bytes.length === 0)
        throw new Error(`The imported file ${file.path} is empty.`);
      if (file.bytes.length > 200_000)
        throw new Error(`The imported file ${file.path} is too large.`);
    }
    if (files.reduce((sum, file) => sum + file.bytes.length, 0) > 10_000_000)
      throw new Error(
        'The selected project documents are too large to import.',
      );
    if (!this.documents.configured)
      throw new Error('No reference document folder is configured.');

    const project = this.projects.create({ name: manifest.name });
    try {
      for (const goal of manifest.goals)
        this.context.add({ projectId: project.id, kind: 'goal', text: goal });
      for (const decision of manifest.decisions)
        this.context.add({
          projectId: project.id,
          kind: 'decision',
          text: decision,
        });
      const storedPaths = this.documents.storeProjectImport(files);
      const references: ReferenceResult[] = [];
      for (const path of storedPaths)
        references.push(
          await this.documents.reference({ projectId: project.id, path }),
        );
      this.metadata.save({
        projectId: project.id,
        suggestedQuestions: manifest.suggestedQuestions,
        expectedBehaviors: manifest.expectedBehaviors,
      });
      return { project, references };
    } catch (error) {
      throw new ProjectImportFailure(
        project.id,
        error instanceof Error
          ? error.message
          : 'The project was created, but importing its contents did not finish.',
      );
    }
  }
}

import { z } from 'zod';
import { repositorySchema } from './github-ci';

export const projectNameSchema = z
  .string()
  .trim()
  .min(1, 'Enter a project name.')
  .max(80, 'Use at most 80 characters.')
  .regex(/^[^\p{Cc}\p{Cf}]+$/u, 'Use a name without control characters.');
export const createProjectSchema = z
  .object({ name: projectNameSchema })
  .strict();
export const projectIdSchema = z.uuid();
export const projectSchema = z
  .object({
    id: projectIdSchema,
    name: projectNameSchema,
    createdAt: z.iso.datetime(),
    /** The GitHub repository whose CI the project shows, as `owner/name`; null until connected. */
    repository: z.string().nullable(),
  })
  .strict();
export type Project = z.infer<typeof projectSchema>;

export interface ProjectRepository {
  create(name: string): Project;
  list(): Project[];
  find(id: string): Project | null;
  setRepository(id: string, repository: string | null): void;
  remove(id: string): void;
}

export class ProjectService {
  constructor(private readonly repository: ProjectRepository) {}

  create(input: unknown): Project {
    const { name } = createProjectSchema.parse(input);
    return projectSchema.parse(this.repository.create(name));
  }

  list(): Project[] {
    return z.array(projectSchema).parse(this.repository.list());
  }

  find(id: unknown): Project | null {
    return projectSchema
      .nullable()
      .parse(this.repository.find(projectIdSchema.parse(id)));
  }

  /** Connects a GitHub repository (owner/name or a github.com URL), or disconnects it with an empty value. */
  setRepository(id: unknown, repositoryInput: unknown): Project {
    const projectId = projectIdSchema.parse(id);
    if (!this.repository.find(projectId)) throw new Error('Project not found.');
    const raw =
      typeof repositoryInput === 'string' ? repositoryInput.trim() : '';
    this.repository.setRepository(
      projectId,
      raw === '' ? null : repositorySchema.parse(raw),
    );
    return projectSchema.parse(this.repository.find(projectId));
  }

  remove(id: unknown): void {
    this.repository.remove(projectIdSchema.parse(id));
  }
}

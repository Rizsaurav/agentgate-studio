import 'server-only';
import { mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import {
  AGENT_PROVIDER,
  AgentModel,
  AgentStore,
  CloudCatalog,
  EvalService,
  SqliteEvals,
  ContextService,
  DocumentService,
  SqliteContext,
  SqliteDocuments,
  EnvironmentBackend,
  KeychainBackend,
  ModelRouter,
  DEFAULT_OLLAMA_URL,
  HuggingFaceCatalog,
  DEFAULT_SCANNER_URL,
  LlmGuardScanner,
  ModelPuller,
  OllamaCatalog,
  ProtectionPipeline,
  SqliteSecurityEvents,
  ProjectService,
  ProjectImportService,
  RunService,
  SecretCredentialStore,
  CLOUD_PROVIDERS,
  CUSTOM_PROVIDER,
  CustomEndpoint,
  SqliteSettings,
  SessionService,
  SqliteProjects,
  SqliteProjectImports,
  SqliteSessions,
  openDatabase,
  startOllama,
} from '@agentgate/controller';

type Controller = {
  projects: ProjectService;
  projectImports: SqliteProjectImports;
  projectImportService: ProjectImportService;
  sessions: SessionService;
  runs: RunService;
  ollama: OllamaCatalog;
  cloud: CloudCatalog;
  customEndpoint: CustomEndpoint;
  context: ContextService;
  documents: DocumentService;
  security: SqliteSecurityEvents;
  evals: EvalService;
  repoRoot: string;
  puller: ModelPuller;
  agentStore: AgentStore;
  agentModel: AgentModel;
  catalog: HuggingFaceCatalog;
  endpoints: { ollamaUrl: string; scannerUrl: string; docsRoot: string | null };
};
const globalController = globalThis as typeof globalThis & {
  controller?: Controller;
};

/** One controller per process, retained through development reloads. */
function controller(): Controller {
  if (!globalController.controller) {
    const dataDir = process.env.AGENTGATE_DATA_DIR;
    if (dataDir !== undefined && !dataDir.trim())
      throw new Error('AGENTGATE_DATA_DIR must not be empty.');
    const directory = dataDir
      ? resolve(dataDir)
      : join(homedir(), '.agentgate');
    const db = openDatabase(join(directory, 'agentgate.sqlite'));
    const projectRepository = new SqliteProjects(db);
    const sessionRepository = new SqliteSessions(db);
    // Containers have no operating system credential store, so they read keys from the environment.
    const secrets =
      process.env.AGENTGATE_SECRETS === 'env'
        ? new EnvironmentBackend()
        : new KeychainBackend();
    const ollamaUrl = new URL(
      process.env.AGENTGATE_OLLAMA_URL ?? DEFAULT_OLLAMA_URL,
    ).origin;
    const ollama = new OllamaCatalog(ollamaUrl);
    const agentStore = new AgentStore(db);
    const cloud = new CloudCatalog(
      new SecretCredentialStore(secrets, CLOUD_PROVIDERS),
    );
    const customEndpoint = new CustomEndpoint(
      new SqliteSettings(db),
      new SecretCredentialStore(secrets, [CUSTOM_PROVIDER]),
    );
    // Reference documents are read only from this folder; by default it lives beside the database.
    const docsRoot = resolve(
      /* turbopackIgnore: true */
      process.env.AGENTGATE_DOCS_ROOT || join(directory, 'documents'),
    );
    mkdirSync(docsRoot, { recursive: true });
    const projectService = new ProjectService(projectRepository);
    const projectImports = new SqliteProjectImports(db);
    const context = new ContextService(
      new SqliteContext(db),
      projectRepository,
    );
    const documentRepository = new SqliteDocuments(db);
    const security = new SqliteSecurityEvents(db);
    // The scanner runs as a separate local service; if it is down, protected stages fail closed.
    const guard = new ProtectionPipeline(
      new LlmGuardScanner(process.env.AGENTGATE_SCANNER_URL),
      security,
      (projectId, documentId, seqs) =>
        documentRepository.withhold(projectId, documentId, seqs),
    );
    const documents = new DocumentService(
      documentRepository,
      projectRepository,
      docsRoot,
      (document, chunks) => guard.screenDocument(document, chunks),
    );
    const projectImportService = new ProjectImportService(
      projectService,
      context,
      documents,
      projectImports,
    );
    // The evaluation suite is version-controlled in the repository, not in the data directory.
    // Resolved at runtime on purpose, so the bundler must not trace the whole repository.
    const repoRoot = resolve(
      /* turbopackIgnore: true */
      process.env.AGENTGATE_REPO_ROOT ?? join(process.cwd(), '..', '..'),
    );
    const evals = new EvalService(new SqliteEvals(db), repoRoot);
    evals.start();
    const runs = new RunService(
      sessionRepository,
      // Ollama is started the first time a local model is used, not when the app opens.
      new ModelRouter(ollama, cloud, customEndpoint, async () => {
        agentStore.setUsesLocalModels();
        return startOllama(ollamaUrl);
      }),
      {
        guard,
        knowledge: {
          context: (projectId) => context.render(projectId),
          retrieve: (projectId, query) => documents.retrieve(projectId, query),
        },
      },
    );
    runs.start();
    globalController.controller = {
      projects: projectService,
      projectImports,
      projectImportService,
      sessions: new SessionService(sessionRepository, projectRepository),
      runs,
      ollama,
      cloud,
      customEndpoint,
      context,
      documents,
      security,
      evals,
      repoRoot,
      puller: new ModelPuller(process.env.AGENTGATE_OLLAMA_URL),
      agentStore,
      agentModel: new AgentModel(
        new SecretCredentialStore(secrets, [AGENT_PROVIDER]),
        process.env.AGENTGATE_AGENT_MODEL || undefined,
      ),
      catalog: new HuggingFaceCatalog(process.env.AGENTGATE_HF_URL),
      endpoints: {
        ollamaUrl,
        scannerUrl: new URL(
          process.env.AGENTGATE_SCANNER_URL ?? DEFAULT_SCANNER_URL,
        ).origin,
        docsRoot: docsRoot,
      },
    };
  }
  return globalController.controller;
}
export const projects = () => controller().projects;
export const projectImports = () => controller().projectImports;
export const projectImportService = () => controller().projectImportService;
export const sessions = () => controller().sessions;
export const runs = () => controller().runs;
export const ollama = () => controller().ollama;
export const cloud = () => controller().cloud;
export const customEndpoint = () => controller().customEndpoint;
export const context = () => controller().context;
export const documents = () => controller().documents;
export const security = () => controller().security;
export const evals = () => controller().evals;
export const repoRoot = () => controller().repoRoot;
export const agentStore = () => controller().agentStore;
export const agentModel = () => controller().agentModel;
export const catalog = () => controller().catalog;
export const puller = () => controller().puller;
export const endpoints = () => controller().endpoints;

'use server';
import { redirect } from 'next/navigation';
import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import {
  createProjectSchema,
  createSessionSchema,
  isLocalMutation,
  questionSchema,
  runIdSchema,
  sendPromptSchema,
} from '@agentgate/controller';
import {
  agentModel,
  agentStore,
  cloud,
  context,
  customEndpoint,
  documents,
  endpoints,
  evals,
  projects,
  puller,
  runs,
  security,
  sessions,
} from '@/lib/controller';
import { assistant } from '@/lib/assistant';

export type CreateProjectState = { error: string | null };
export async function createProject(
  _previous: CreateProjectState,
  form: FormData,
): Promise<CreateProjectState> {
  const requestHeaders = await headers();
  if (
    !isLocalMutation(requestHeaders.get('origin'), requestHeaders.get('host'))
  ) {
    return {
      error: 'Project changes require a request from this local workspace.',
    };
  }
  const parsed = createProjectSchema.safeParse({ name: form.get('name') });
  if (!parsed.success)
    return {
      error: parsed.error.issues[0]?.message ?? 'Enter a valid project name.',
    };
  let id: string;
  try {
    id = projects().create(parsed.data).id;
  } catch {
    // Deliberately avoid logging database errors that could include private names/paths.
    return {
      error:
        'The project could not be saved. Check local storage access and try again.',
    };
  }
  revalidatePath('/');
  redirect(`/projects/${id}`);
}

async function isLocalRequest(): Promise<boolean> {
  const requestHeaders = await headers();
  return isLocalMutation(
    requestHeaders.get('origin'),
    requestHeaders.get('host'),
  );
}

export type StartSessionState = { error: string | null };
export async function startSession(
  _previous: StartSessionState,
  form: FormData,
): Promise<StartSessionState> {
  if (!(await isLocalRequest()))
    return { error: 'Requests must come from this local workspace.' };
  // Option values are `provider/modelId`; model ids may themselves contain slashes or colons.
  const choice = String(form.get('model') ?? '');
  const separator = choice.indexOf('/');
  const parsed = createSessionSchema.safeParse({
    projectId: form.get('projectId'),
    model: {
      provider: choice.slice(0, separator),
      modelId: choice.slice(separator + 1),
    },
  });
  if (!parsed.success) return { error: 'Choose an installed model.' };
  let id: string;
  try {
    id = sessions().createSession(parsed.data).id;
  } catch {
    return { error: 'The session could not be created.' };
  }
  redirect(`/projects/${parsed.data.projectId}/sessions/${id}`);
}

export type SendPromptResult =
  { runId: string; error: null } | { runId: null; error: string };
export async function sendPrompt(
  sessionId: string,
  prompt: string,
): Promise<SendPromptResult> {
  if (!(await isLocalRequest()))
    return {
      runId: null,
      error: 'Requests must come from this local workspace.',
    };
  const parsed = sendPromptSchema.safeParse({ sessionId, prompt });
  if (!parsed.success)
    return {
      runId: null,
      error: parsed.error.issues[0]?.message ?? 'Enter a valid task.',
    };
  try {
    return { runId: runs().enqueue(parsed.data).id, error: null };
  } catch (error) {
    return {
      runId: null,
      error:
        error instanceof Error && error.message.includes('active run')
          ? error.message
          : 'The task could not be started.',
    };
  }
}

export async function cancelRun(runId: string): Promise<void> {
  if (!(await isLocalRequest())) return;
  const parsed = runIdSchema.safeParse(runId);
  if (parsed.success) runs().cancel(parsed.data);
}

export type ConnectState = { error: string | null; saved: boolean };
export async function connectProvider(
  _previous: ConnectState,
  form: FormData,
): Promise<ConnectState> {
  if (!(await isLocalRequest()))
    return {
      error: 'Requests must come from this local workspace.',
      saved: false,
    };
  try {
    await cloud().connect(form.get('provider'), form.get('apiKey'));
  } catch (error) {
    // Messages from connect() are validation text or fixed provider-failure text, never raw provider output.
    return {
      error:
        error instanceof Error
          ? firstLine(error.message)
          : 'The key could not be saved.',
      saved: false,
    };
  }
  revalidatePath('/models');
  return { error: null, saved: true };
}

/** The form is reset after every submission, so the non-secret fields come back to refill it. The key never does. */
export type CustomEndpointState = ConnectState & {
  values: { name: string; baseUrl: string; models: string } | null;
};
export async function connectCustomEndpoint(
  _previous: CustomEndpointState,
  form: FormData,
): Promise<CustomEndpointState> {
  const values = {
    name: String(form.get('name') ?? ''),
    baseUrl: String(form.get('baseUrl') ?? ''),
    models: String(form.get('models') ?? ''),
  };
  if (!(await isLocalRequest()))
    return {
      error: 'Requests must come from this local workspace.',
      saved: false,
      values,
    };
  try {
    await customEndpoint().connect({
      ...values,
      apiKey: String(form.get('apiKey') ?? ''),
    });
  } catch (error) {
    // Validation text or fixed provider-failure text; the server's own reply is never shown.
    return {
      error:
        error instanceof Error
          ? firstLine(error.message)
          : 'The endpoint could not be saved.',
      saved: false,
      values,
    };
  }
  revalidatePath('/models');
  return { error: null, saved: true, values };
}

export async function disconnectCustomEndpoint(): Promise<void> {
  if (!(await isLocalRequest())) return;
  await customEndpoint().disconnect();
  revalidatePath('/models');
}

export async function disconnectProvider(form: FormData): Promise<void> {
  if (!(await isLocalRequest())) return;
  await cloud().disconnect(form.get('provider'));
  revalidatePath('/models');
}

function firstLine(message: string): string {
  try {
    const issues: unknown = JSON.parse(message);
    if (Array.isArray(issues) && issues[0]?.message)
      return String(issues[0].message);
  } catch {
    // Not a validation error list: it is already plain text.
  }
  return message.slice(0, 200);
}

export type FormState = { error: string | null; notice: string | null };

/** Validation and policy messages are written for people; anything else becomes a generic message. */
function userMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.name === 'ZodError')
    return firstLine(error.message);
  return error instanceof Error &&
    error.cause === undefined &&
    error.message.length < 200
    ? error.message
    : fallback;
}

export async function addContext(
  _previous: FormState,
  form: FormData,
): Promise<FormState> {
  if (!(await isLocalRequest()))
    return {
      error: 'Requests must come from this local workspace.',
      notice: null,
    };
  try {
    context().add({
      projectId: form.get('projectId'),
      kind: form.get('kind'),
      text: form.get('text'),
    });
  } catch (error) {
    return {
      error: userMessage(error, 'The context could not be saved.'),
      notice: null,
    };
  }
  revalidatePath(`/projects/${form.get('projectId')}`);
  return { error: null, notice: 'Added to the shared context.' };
}

export async function removeContext(form: FormData): Promise<void> {
  if (!(await isLocalRequest())) return;
  context().remove(form.get('projectId'), form.get('id'));
  revalidatePath(`/projects/${form.get('projectId')}`);
}

type ReferenceResult = Awaited<
  ReturnType<ReturnType<typeof documents>['reference']>
>;

/** One message for the whole batch: an error only when nothing could be added. */
function referenceFeedback(
  results: ReferenceResult[],
  rejected: { name: string; reason: string }[] = [],
): FormState {
  const added = results.reduce((sum, result) => sum + result.added.length, 0);
  const problems = [
    ...rejected.map((r) => `${r.name}: ${r.reason}`),
    ...results.flatMap((result) => [
      ...result.quarantined.map(
        (q) => `${q.document.path}: quarantined (${q.reason})`,
      ),
      ...result.added
        .filter((document) => document.withheld > 0)
        .map(
          (document) =>
            `${document.path}: ${document.withheld} of ${document.chunkCount} passages withheld for review.`,
        ),
      ...result.skipped.map((skip) => `${skip.path}: ${skip.reason}`),
    ]),
  ].join(' ');
  return {
    error: added === 0 && problems ? problems : null,
    notice: `Added ${added} document(s).${added > 0 && problems ? ` Notes: ${problems}` : ''}`,
  };
}

export async function addReference(
  _previous: FormState,
  form: FormData,
): Promise<FormState> {
  if (!(await isLocalRequest()))
    return {
      error: 'Requests must come from this local workspace.',
      notice: null,
    };
  try {
    const projectId = form.get('projectId');
    const uploads = await Promise.all(
      form
        .getAll('files')
        .filter(
          (entry): entry is File => entry instanceof File && entry.size > 0,
        )
        .map(async (file) => ({
          name: file.name,
          bytes: new Uint8Array(await file.arrayBuffer()),
        })),
    );
    // Chosen files take priority; the typed path is for files already in the reference folder.
    const stored = uploads.length > 0 ? documents().store(uploads) : null;
    const paths = stored ? stored.paths : [form.get('path')];
    const results: ReferenceResult[] = [];
    for (const path of paths)
      results.push(await documents().reference({ projectId, path }));
    revalidatePath(`/projects/${projectId}`);
    return referenceFeedback(results, stored?.rejected);
  } catch (error) {
    return {
      error: userMessage(error, 'The documents could not be added.'),
      notice: null,
    };
  }
}

export async function removeReference(form: FormData): Promise<void> {
  if (!(await isLocalRequest())) return;
  documents().remove(form.get('projectId'), form.get('id'));
  revalidatePath(`/projects/${form.get('projectId')}`);
}

/** Releases a withheld passage after the user reviewed it; the override is kept with the security events. */
export async function releasePassage(form: FormData): Promise<void> {
  if (!(await isLocalRequest())) return;
  const projectId = String(form.get('projectId'));
  const released = documents().release(
    projectId,
    form.get('documentId'),
    form.get('seq'),
  );
  if (released)
    security().record({
      projectId,
      runId: null,
      documentId: released.document.id,
      stage: 'ingestion',
      rule: 'user-release',
      source: `${released.document.title} (${released.document.path})`,
      outcome: 'released',
      detail:
        'The user reviewed a withheld passage and released it to the model.',
      evidence: released.excerpt.slice(0, 160),
      score: null,
    });
  revalidatePath(`/projects/${projectId}`);
}

/** Records an assistant answer the user has checked as a verified outcome in the shared context. */
export async function saveOutcome(form: FormData): Promise<void> {
  if (!(await isLocalRequest())) return;
  const projectId = String(form.get('projectId'));
  const text = String(form.get('text') ?? '').slice(0, 500);
  // Policy rejections (for example a credential in the text) throw and surface the error page.
  context().add({ projectId, kind: 'outcome', text });
  revalidatePath(`/projects/${projectId}`);
}

export async function startEvaluation(form: FormData): Promise<void> {
  if (!(await isLocalRequest())) return;
  await evals().enqueue(form.get('profile'));
  revalidatePath('/evaluations');
}

export type PullResult = { error: string | null };
export async function pullModel(
  model: string,
  fallbacks: string[] = [],
): Promise<PullResult> {
  if (!(await isLocalRequest()))
    return { error: 'Requests must come from this local workspace.' };
  return installLocalModel(model, fallbacks);
}

/** Installs and starts Ollama in the background if needed, then the download. Local models are opt-in. */
async function installLocalModel(
  model: unknown,
  fallbacks: unknown[] = [],
): Promise<PullResult> {
  try {
    agentStore().setUsesLocalModels();
    puller().start(model, Array.isArray(fallbacks) ? fallbacks : []);
  } catch (error) {
    return { error: userMessage(error, 'The download could not be started.') };
  }
  return { error: null };
}

export async function cancelPull(): Promise<void> {
  if (await isLocalRequest()) puller().cancel();
}

export async function connectAssistant(
  _previous: ConnectState,
  form: FormData,
): Promise<ConnectState> {
  if (!(await isLocalRequest()))
    return {
      error: 'Requests must come from this local workspace.',
      saved: false,
    };
  try {
    await agentModel().connect(form.get('apiKey'));
  } catch (error) {
    return {
      error:
        error instanceof Error
          ? firstLine(error.message)
          : 'The key could not be saved.',
      saved: false,
    };
  }
  return { error: null, saved: true };
}

export async function disconnectAssistant(): Promise<void> {
  if (await isLocalRequest()) await agentModel().disconnect();
}

export async function setAssistantEnabled(enabled: boolean): Promise<void> {
  if (await isLocalRequest()) agentStore().setEnabled(enabled === true);
}

/** Starts the question in the background; the answer shows up in the assistant's feed. */
export async function askAssistant(question: string): Promise<PullResult> {
  if (!(await isLocalRequest()))
    return { error: 'Requests must come from this local workspace.' };
  const { supervisor } = assistant();
  try {
    const parsed = questionSchema.parse(question);
    const reason = await supervisor.unavailable();
    if (reason) return { error: reason };
    void supervisor.ask(parsed).catch((error: unknown) => {
      agentStore().addNote(
        'action',
        `Could not answer: ${error instanceof Error ? error.message : 'unknown error'}`,
      );
    });
  } catch (error) {
    return { error: userMessage(error, 'The question could not be sent.') };
  }
  return { error: null };
}

/** Installing a model is never automatic: the assistant proposes, and only this action starts the download. */
export async function decideProposal(
  id: string,
  approve: boolean,
): Promise<PullResult> {
  if (!(await isLocalRequest()))
    return { error: 'Requests must come from this local workspace.' };
  const note = agentStore().findNote(id);
  if (note?.kind !== 'proposal' || note.status !== 'open')
    return { error: 'That suggestion is no longer open.' };
  if (approve) {
    const started = await installLocalModel(note.text);
    if (started.error) return started;
  }
  agentStore().setStatus(id, approve ? 'approved' : 'dismissed');
  return { error: null };
}

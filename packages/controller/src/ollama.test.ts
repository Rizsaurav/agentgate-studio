import { mkdtempSync, rmSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  createModels,
  fauxAssistantMessage,
  fauxProvider,
  fauxThinking,
} from '@earendil-works/pi-ai';
import { afterEach, describe, expect, it } from 'vitest';
import {
  OllamaCatalog,
  ProjectService,
  RunService,
  SessionService,
  SqliteProjects,
  SqliteSessions,
  openDatabase,
  type AgentModels,
} from './index';
import { markerScanner, protection } from './test-support';

const MODEL = 'hf.co/bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF:Q6_K';
const directories: string[] = [];
const servers: Server[] = [];
const closers: (() => void)[] = [];
afterEach(() => {
  for (const close of closers.splice(0)) close();
  for (const server of servers.splice(0)) server.close();
  for (const directory of directories.splice(0))
    rmSync(directory, { recursive: true, force: true });
});

/**
 * Ollama as it behaves for a model it tags as "thinking": the whole reply arrives as reasoning
 * with empty content, unless the request asks for no reasoning.
 */
async function thinkingOllama() {
  const bodies: Record<string, unknown>[] = [];
  const server = createServer((request, response) => {
    let raw = '';
    request.on('data', (chunk) => (raw += chunk));
    request.on('end', () => {
      if (request.url === '/api/tags') {
        response.setHeader('content-type', 'application/json');
        return void response.end(
          JSON.stringify({ models: [{ name: MODEL, size: 1 }] }),
        );
      }
      if (request.url !== '/v1/chat/completions') {
        response.statusCode = 404;
        return void response.end();
      }
      const body = JSON.parse(raw) as Record<string, unknown>;
      bodies.push(body);
      const delta =
        body.reasoning_effort === 'none'
          ? { content: 'Returns are accepted within 30 days.' }
          : { content: '', reasoning: 'Returns are accepted within 30 days.' };
      const chunk = (choice: object) =>
        `data: ${JSON.stringify({ id: 'c1', object: 'chat.completion.chunk', created: 1, model: MODEL, choices: [choice] })}\n\n`;
      response.setHeader('content-type', 'text/event-stream');
      response.end(
        chunk({ index: 0, delta: { role: 'assistant', ...delta } }) +
          chunk({ index: 0, delta: {}, finish_reason: 'stop' }) +
          'data: [DONE]\n\n',
      );
    });
  });
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;
  return { url: `http://127.0.0.1:${port}`, bodies };
}

function setup(models: AgentModels) {
  const directory = mkdtempSync(join(tmpdir(), 'agentgate-ollama-'));
  directories.push(directory);
  const db = openDatabase(join(directory, 'agentgate.sqlite'));
  closers.push(() => db.open && db.close());
  const projectRepository = new SqliteProjects(db);
  const repository = new SqliteSessions(db);
  const sessions = new SessionService(repository, projectRepository);
  const projectId = new ProjectService(projectRepository).create({
    name: 'P',
  }).id;
  const sessionId = sessions.createSession({
    projectId,
    model: { provider: 'ollama', modelId: MODEL },
  }).id;
  const runs = new RunService(repository, models, {
    guard: protection(db, markerScanner()).guard,
  });
  const ask = async (prompt: string) => {
    const run = runs.enqueue({ sessionId, prompt });
    await runs.idle();
    return {
      run: sessions.findRun(run.id),
      text: repository
        .eventsAfter(run.id, 0)
        .filter((event) => event.type === 'text_delta')
        .map((event) => event.text)
        .join(''),
    };
  };
  return { ask };
}

describe('Ollama answers', () => {
  it('asks for no reasoning, so a model tagged as thinking answers in plain text', async () => {
    const ollama = await thinkingOllama();
    const { ask } = setup(new OllamaCatalog(ollama.url));
    const { run, text } = await ask('How long do I have to return a bike?');
    expect(ollama.bodies[0]?.reasoning_effort).toBe('none');
    expect(run?.status).toBe('completed');
    expect(text).toBe('Returns are accepted within 30 days.');
  });

  it('fails a run whose reply has no answer text instead of completing it empty', async () => {
    const faux = fauxProvider();
    const registry = createModels();
    registry.setProvider(faux.provider);
    faux.setResponses([fauxAssistantMessage([fauxThinking('Hidden only.')])]);
    const { ask } = setup({
      open: async () => ({
        model: faux.getModel(),
        streamFn: (target, context, options) =>
          registry.streamSimple(target, context, options),
        getApiKey: () => undefined,
        describeError: (message) => message,
      }),
    });
    const { run, text } = await ask('Hello?');
    expect(run).toMatchObject({
      status: 'failed',
      error: expect.stringContaining('no answer text'),
    });
    expect(text).toBe('');
  });
});

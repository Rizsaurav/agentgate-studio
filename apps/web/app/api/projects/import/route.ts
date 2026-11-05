import { headers } from 'next/headers';
import { isLocalMutation } from '@agentgate/controller';
import { projectSources } from '@/lib/controller';
import { projectProgressStream } from '@/lib/progress-stream';

export const dynamic = 'force-dynamic';
const MAX_REQUEST_BYTES = 55_000_000;

async function readBoundedBody(request: Request): Promise<ArrayBuffer | null> {
  if (!request.body) return new ArrayBuffer(0);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_REQUEST_BYTES) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const body = new ArrayBuffer(size);
  const bytes = new Uint8Array(body);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

export async function POST(request: Request) {
  if (
    !isLocalMutation(
      request.headers.get('origin'),
      request.headers.get('host') ?? (await headers()).get('host'),
    )
  )
    return new Response('Forbidden', { status: 403 });

  const contentLength = Number(request.headers.get('content-length') ?? 0);
  if (contentLength > MAX_REQUEST_BYTES)
    return Response.json(
      { error: 'The selected folder is larger than 50 MB.' },
      { status: 413 },
    );

  let form: FormData;
  try {
    const body = await readBoundedBody(request);
    if (!body)
      return Response.json(
        { error: 'The selected folder is larger than 50 MB.' },
        { status: 413 },
      );
    form = await new Response(body, { headers: request.headers }).formData();
  } catch {
    return Response.json(
      { error: 'The import request is invalid.' },
      { status: 400 },
    );
  }
  const name = form.get('name');
  if (typeof name !== 'string')
    return Response.json({ error: 'Enter a project name.' }, { status: 400 });

  const sourceType = form.get('sourceType');
  if (sourceType === 'github') {
    const url = form.get('url');
    if (typeof url !== 'string')
      return Response.json(
        { error: 'Enter a GitHub repository URL.' },
        { status: 400 },
      );
    return projectProgressStream(request, (signal, onProgress) =>
      projectSources().cloneFromGitHub({ url, name }, { signal, onProgress }),
    );
  }

  if (sourceType !== 'folder')
    return Response.json(
      { error: 'Choose a project folder or GitHub URL.' },
      { status: 400 },
    );

  let paths: unknown;
  try {
    paths = JSON.parse(String(form.get('paths') ?? ''));
  } catch {
    return Response.json(
      { error: 'The selected folder paths are invalid.' },
      { status: 400 },
    );
  }
  if (!Array.isArray(paths))
    return Response.json(
      { error: 'The selected folder paths are invalid.' },
      { status: 400 },
    );
  const relativePaths: string[] = [];
  for (const path of paths) {
    if (typeof path !== 'string')
      return Response.json(
        { error: 'The selected folder paths are invalid.' },
        { status: 400 },
      );
    relativePaths.push(path);
  }
  const uploads = form.getAll('files');
  if (
    uploads.length !== relativePaths.length ||
    uploads.some((file) => !(file instanceof File))
  )
    return Response.json(
      { error: 'The selected folder files are invalid.' },
      { status: 400 },
    );
  const files: { path: string; bytes: Uint8Array }[] = [];
  for (const [index, upload] of uploads.entries()) {
    if (!(upload instanceof File))
      return Response.json(
        { error: 'The selected folder files are invalid.' },
        { status: 400 },
      );
    const path = relativePaths[index];
    if (path === undefined)
      return Response.json(
        { error: 'The selected folder paths are invalid.' },
        { status: 400 },
      );
    files.push({
      path,
      bytes: new Uint8Array(await upload.arrayBuffer()),
    });
  }
  return projectProgressStream(request, (signal, onProgress) =>
    projectSources().importFolder({ name, files }, { signal, onProgress }),
  );
}

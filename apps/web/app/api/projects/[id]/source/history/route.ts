import { isLocalMutation, projectIdSchema } from '@agentgate/controller';
import { headers } from 'next/headers';
import { projectSources } from '@/lib/controller';
import { projectProgressStream } from '@/lib/progress-stream';

export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  const requestHeaders = await headers();
  if (
    !isLocalMutation(
      request.headers.get('origin') ?? requestHeaders.get('origin'),
      request.headers.get('host') ?? requestHeaders.get('host'),
    )
  )
    return new Response('Forbidden', { status: 403 });
  const { id } = await params;
  if (!projectIdSchema.safeParse(id).success)
    return Response.json({ error: 'Project not found.' }, { status: 404 });
  const source = projectSources().find(id);
  if (!source?.sourceUrl)
    return Response.json(
      { error: 'This project has no GitHub repository.' },
      { status: 404 },
    );
  return projectProgressStream(request, async (signal, onProgress) => {
    await projectSources().fetchFullHistory(id, { signal, onProgress });
    return { fullHistory: true };
  });
}

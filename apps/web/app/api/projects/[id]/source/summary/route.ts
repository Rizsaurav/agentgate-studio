import { isLocalMutation, projectIdSchema } from '@agentgate/controller';
import { headers } from 'next/headers';
import { projectSources } from '@/lib/controller';

export async function PATCH(
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
  try {
    const source = projectSources().updateSummary(id, await request.json());
    return Response.json(source.summary, {
      headers: { 'cache-control': 'no-store' },
    });
  } catch (error) {
    return Response.json(
      {
        error:
          error instanceof Error && error.name === 'ZodError'
            ? 'The project summary is invalid.'
            : 'The project summary could not be saved.',
      },
      { status: 400 },
    );
  }
}

import { headers } from 'next/headers';
import { isLocalHost, projectIdSchema } from '@agentgate/controller';
import { projects } from '@/lib/controller';
import { githubCi } from '@/lib/github';

export const dynamic = 'force-dynamic';

/** The failing jobs and log tail of one failed run, loaded when its details are opened. */
export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string; runId: string }> },
) {
  if (!isLocalHost((await headers()).get('host')))
    return new Response('Forbidden', { status: 403 });
  const { id, runId } = await params;
  if (!projectIdSchema.safeParse(id).success || !/^\d{1,15}$/.test(runId))
    return new Response('Not found', { status: 404 });
  const repository = projects().find(id)?.repository;
  if (!repository) return new Response('Not found', { status: 404 });
  try {
    const failure = await githubCi().failure(repository, runId);
    return failure
      ? Response.json({ failure, error: null })
      : Response.json({ failure: null, error: 'This run did not fail.' });
  } catch (error) {
    return Response.json({
      failure: null,
      // describeGhError's fixed sentences only; gh output is never passed on.
      error:
        error instanceof Error && error.message.length < 200
          ? error.message
          : 'The run could not be read.',
    });
  }
}

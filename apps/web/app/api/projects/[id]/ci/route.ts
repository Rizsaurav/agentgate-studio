import { headers } from 'next/headers';
import { isLocalHost, projectIdSchema } from '@agentgate/controller';
import { projects } from '@/lib/controller';
import { githubCi } from '@/lib/github';

export const dynamic = 'force-dynamic';

/** The newest run of each workflow in the project's repository, polled by the CI strip. No token is ever included. */
export async function GET(
  _request: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  if (!isLocalHost((await headers()).get('host')))
    return new Response('Forbidden', { status: 403 });
  const { id } = await params;
  if (!projectIdSchema.safeParse(id).success)
    return new Response('Not found', { status: 404 });
  const project = projects().find(id);
  if (!project) return new Response('Not found', { status: 404 });
  if (!project.repository) return Response.json({ connected: false });
  return Response.json({
    connected: true,
    repository: project.repository,
    ...(await githubCi().status(project.repository)),
  });
}

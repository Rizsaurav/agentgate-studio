import { headers } from 'next/headers';
import { isLocalHost } from '@agentgate/controller';
import { puller } from '@/lib/controller';

export const dynamic = 'force-dynamic';

/** Current model download progress and the queue behind it, polled by the model views. */
export async function GET() {
  if (!isLocalHost((await headers()).get('host')))
    return new Response('Forbidden', { status: 403 });
  return Response.json(
    { current: puller().state(), queued: puller().queued() },
    { headers: { 'cache-control': 'no-store' } },
  );
}

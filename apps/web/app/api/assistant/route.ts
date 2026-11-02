import { headers } from 'next/headers';
import { DEFAULT_LIMITS, isLocalHost } from '@agentgate/controller';
import { assistant } from '@/lib/assistant';
import { agentModel, agentStore } from '@/lib/controller';

export const dynamic = 'force-dynamic';

/** What the assistant sees and has done, polled by its panel. Contains no keys and no document text. */
export async function GET() {
  if (!isLocalHost((await headers()).get('host')))
    return new Response('Forbidden', { status: 403 });
  const { supervisor, watchdog } = assistant();
  const store = agentStore();
  const configured = await agentModel().configured();
  return Response.json(
    {
      enabled: store.enabled(),
      configured,
      working: supervisor.working(),
      unavailable: await supervisor.unavailable(),
      tokensLeft: supervisor.tokensLeft(),
      dailyTokens:
        Number(process.env.AGENTGATE_AGENT_DAILY_TOKENS) ||
        DEFAULT_LIMITS.dailyTokens,
      model: agentModel().modelId,
      findings: watchdog.current(),
      notes: store.notes(30),
    },
    { headers: { 'cache-control': 'no-store' } },
  );
}

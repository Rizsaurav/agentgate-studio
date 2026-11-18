import { headers } from 'next/headers';
import {
  SPEND_WARNING,
  fixForProposal,
  isLocalHost,
} from '@agentgate/controller';
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
  const used = supervisor.dailyTokens - supervisor.tokensLeft();
  return Response.json(
    {
      enabled: store.enabled(),
      configured,
      working: supervisor.working(),
      unavailable: await supervisor.unavailable(),
      tokensLeft: supervisor.tokensLeft(),
      // The supervisor's own limit, so the panel shows the cap that is enforced.
      dailyTokens: supervisor.dailyTokens,
      spending: store.spending(),
      // True from 80 percent of the daily cap, so the panel can warn before it stops.
      nearCap: used >= SPEND_WARNING * supervisor.dailyTokens,
      model: agentModel().modelId,
      findings: watchdog.current(),
      // The panel needs to know what approving a proposal does: run an action or install a model.
      notes: store.notes(30).map((note) => ({
        ...note,
        request:
          note.kind !== 'proposal'
            ? null
            : fixForProposal(note.text)
              ? 'action'
              : 'install',
      })),
    },
    { headers: { 'cache-control': 'no-store' } },
  );
}

import 'server-only';
import { homedir } from 'node:os';
import {
  inspectSystem,
  type CatalogModel,
  type SystemProfile,
} from '@agentgate/controller';
import { catalog } from '@/lib/controller';

const gb = (bytes: number) => Math.round(bytes / 1024 ** 3);

/** This computer in one line, from what the operating system reports. */
export function describeSystem(system: SystemProfile): string {
  return [
    system.chip,
    `${gb(system.memoryBytes)} GB memory`,
    system.gpu ? `${system.gpu.name} (${gb(system.gpu.memoryBytes)} GB)` : null,
    `${gb(system.freeDiskBytes)} GB free`,
  ]
    .filter(Boolean)
    .join(', ');
}

export type Recommendations = {
  summary: string;
  models: CatalogModel[];
  error: string | null;
  /** Set when Hugging Face was unreachable and the saved catalog from this time was used. */
  offlineSince: string | null;
};

/** Reads this computer, then asks Hugging Face which models suit it. */
export async function loadRecommendations(): Promise<Recommendations> {
  const system = await inspectSystem(homedir());
  const summary = describeSystem(system);
  try {
    const { models, offlineSince } = await catalog().recommend(system);
    return { summary, models, error: null, offlineSince };
  } catch (error) {
    // Logged by name only; the page explains what to do.
    console.error(
      'Model catalog unavailable:',
      error instanceof Error ? error.name : 'unknown',
    );
    return {
      summary,
      models: [],
      error:
        'Could not load the model list from Hugging Face. Check your internet connection, or type a model name below.',
      offlineSince: null,
    };
  }
}

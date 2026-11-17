import type { CatalogModel } from './hf-catalog';

/**
 * How the model setup lists are ordered and cut (#48). One rule for the three lists: the first
 * `VISIBLE` items show, the rest wait behind a "More" control. The ordering decides what makes the
 * cut, so what the user already has (connected providers, installed models, recent choices) always does.
 */
export const VISIBLE = 4;

/** Providers most people start with, in the order they are offered when nothing is connected. */
export const PREFERRED_PROVIDERS = [
  'openrouter',
  'anthropic',
  'openai',
  'google',
];

/** Connected first, then the preferred ones, then the rest, each group in its original order. */
export function orderProviders<T extends { id: string; connected: boolean }>(
  items: T[],
): T[] {
  const rank = (item: T) => {
    if (item.connected) return 0;
    const preferred = PREFERRED_PROVIDERS.indexOf(item.id);
    return preferred === -1 ? 1 + PREFERRED_PROVIDERS.length : 1 + preferred;
  };
  return items
    .map((item, index) => ({ item, index }))
    .sort((a, b) => rank(a.item) - rank(b.item) || a.index - b.index)
    .map(({ item }) => item);
}

/** Installed first, then the best fit, then models that fit (largest first), then the ones that do not. */
export function orderLocalModels(
  models: CatalogModel[],
  installed: ReadonlySet<string>,
): CatalogModel[] {
  return models.toSorted(
    (a, b) =>
      Number(installed.has(b.id)) - Number(installed.has(a.id)) ||
      Number(b.best) - Number(a.best) ||
      Number(b.fits) - Number(a.fits) ||
      b.parametersB - a.parametersB,
  );
}

export type ModelGroup = { label: string; provider: string; models: string[] };
export type ModelChoice = {
  provider: string;
  model: string;
  group: string;
  value: string;
};

function choice(group: ModelGroup, model: string): ModelChoice {
  return {
    provider: group.provider,
    model,
    group: group.label,
    value: `${group.provider}/${model}`,
  };
}

/**
 * Up to `VISIBLE` models for a new conversation: the ones used recently in this project (still
 * available), then each provider's first model, without repeats.
 */
export function suggestModels(
  groups: ModelGroup[],
  recent: string[],
): ModelChoice[] {
  const available = new Map(
    groups.flatMap((group) =>
      group.models.map((model) => {
        const c = choice(group, model);
        return [c.value, c] as const;
      }),
    ),
  );
  const picked = new Map<string, ModelChoice>();
  for (const value of recent) {
    const found = available.get(value);
    if (found) picked.set(value, found);
  }
  for (const group of groups) {
    const first = group.models[0];
    if (first !== undefined)
      picked.set(`${group.provider}/${first}`, choice(group, first));
  }
  return [...picked.values()].slice(0, VISIBLE);
}

/** Models whose name contains every word of `query` (case-insensitive), at most `limit`, grouped by provider order. */
export function searchModels(
  groups: ModelGroup[],
  query: string,
  limit = 50,
): ModelChoice[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return [];
  const results: ModelChoice[] = [];
  for (const group of groups)
    for (const model of group.models) {
      const name = `${group.label} ${model}`.toLowerCase();
      if (words.every((word) => name.includes(word)))
        results.push(choice(group, model));
      if (results.length === limit) return results;
    }
  return results;
}

import { describe, expect, it } from 'vitest';
import type { CatalogModel } from './hf-catalog';
import {
  VISIBLE,
  orderLocalModels,
  orderProviders,
  searchModels,
  suggestModels,
  type ModelGroup,
} from './model-lists';

const providers = [
  'openrouter',
  'anthropic',
  'openai',
  'google',
  'groq',
  'deepseek',
  'mistral',
  'xai',
];

describe('model setup lists (#48)', () => {
  it('offers OpenRouter, Anthropic, OpenAI and Google first when nothing is connected', () => {
    const ordered = orderProviders(
      providers.map((id) => ({ id, connected: false })),
    );
    expect(ordered.slice(0, VISIBLE).map((p) => p.id)).toEqual([
      'openrouter',
      'anthropic',
      'openai',
      'google',
    ]);
  });

  it('always shows connected providers among the first four', () => {
    const ordered = orderProviders(
      providers.map((id) => ({
        id,
        connected: id === 'xai' || id === 'mistral',
      })),
    );
    expect(ordered.slice(0, VISIBLE).map((p) => p.id)).toEqual([
      'mistral',
      'xai',
      'openrouter',
      'anthropic',
    ]);
  });

  it('puts installed models, then the best fit, ahead of the rest', () => {
    const model = (
      id: string,
      parametersB: number,
      extra: Partial<CatalogModel> = {},
    ) =>
      ({
        id,
        label: id,
        parametersB,
        fits: true,
        best: false,
        ...extra,
      }) as CatalogModel;
    const models = [
      model('big', 14),
      model('huge', 70, { fits: false }),
      model('best', 8, { best: true }),
      model('small', 1),
      model('mid', 4),
      model('installed', 0.5),
    ];
    const ordered = orderLocalModels(models, new Set(['installed']));
    expect(ordered.map((m) => m.id)).toEqual([
      'installed',
      'best',
      'big',
      'mid',
      'small',
      'huge',
    ]);
  });

  const groups: ModelGroup[] = [
    {
      label: 'Ollama',
      provider: 'ollama',
      models: ['qwen2.5:0.5b', 'gemma3:270m'],
    },
    {
      label: 'OpenRouter',
      provider: 'openrouter',
      models: [
        ...Array.from({ length: 400 }, (_, i) => `vendor/model-${i}`),
        'deepseek/deepseek-v4.1-flash',
      ],
    },
  ];

  it('suggests recent models first, then each provider’s first, at most four', () => {
    const suggested = suggestModels(groups, [
      'openrouter/deepseek/deepseek-v4.1-flash',
      'gone/model',
      'ollama/gemma3:270m',
    ]);
    expect(suggested.map((c) => c.value)).toEqual([
      'openrouter/deepseek/deepseek-v4.1-flash',
      'ollama/gemma3:270m',
      'ollama/qwen2.5:0.5b',
      'openrouter/vendor/model-0',
    ]);
    expect(suggestModels(groups, [])).toHaveLength(2);
  });

  it('finds a model among hundreds by part of its name', () => {
    expect(searchModels(groups, 'v4.1 flash').map((c) => c.value)).toEqual([
      'openrouter/deepseek/deepseek-v4.1-flash',
    ]);
    expect(searchModels(groups, 'GEMMA').map((c) => c.model)).toEqual([
      'gemma3:270m',
    ]);
    expect(searchModels(groups, 'model', 10)).toHaveLength(10);
    expect(searchModels(groups, '   ')).toEqual([]);
  });
});

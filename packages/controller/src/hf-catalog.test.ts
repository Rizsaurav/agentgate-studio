import { createServer, type Server } from 'node:http';
import { afterEach, describe, expect, it } from 'vitest';
import { HuggingFaceCatalog } from './index';

const GIB = 1024 ** 3;
const servers: Server[] = [];
afterEach(async () => {
  for (const server of servers.splice(0)) {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

const sizes = (q8: number, q6: number, q5: number, q4: number) => ({
  Q8_0: q8,
  Q6_K: q6,
  Q5_K_M: q5,
  Q4_K_M: q4,
});
/** Repositories shaped like Hugging Face's responses; sizes are in GB. */
const REPOS: Record<
  string,
  { downloads: number; files: Record<string, number> }
> = {
  'bartowski/Llama-3.2-3B-Instruct-GGUF': {
    downloads: 900,
    files: sizes(3.4, 2.6, 2.3, 2.0),
  },
  'lmstudio-community/Meta-Llama-3.2-3B-Instruct-GGUF': {
    downloads: 100,
    files: sizes(3.4, 2.6, 2.3, 2.0),
  },
  'bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF': {
    downloads: 300,
    files: sizes(6.5, 5.2, 4.6, 4.0),
  },
  'bartowski/Qwen2.5-14B-Instruct-GGUF': {
    downloads: 500,
    files: sizes(15.7, 12.1, 10.5, 9.0),
  },
  'bartowski/Qwen2.5-32B-Instruct-GGUF': {
    downloads: 400,
    files: sizes(34, 26, 23, 19.9),
  },
  'bartowski/Some-Embed-7B-Instruct-GGUF': {
    downloads: 999,
    files: sizes(8, 6, 5, 4),
  },
  'bartowski/Plain-Base-7B-GGUF': { downloads: 999, files: sizes(8, 6, 5, 4) },
};

async function fakeHub(calls: string[] = []) {
  const server = createServer((request, response) => {
    const url = request.url ?? '';
    calls.push(url);
    response.setHeader('content-type', 'application/json');
    if (url.startsWith('/api/models?')) {
      const author = new URL(url, 'http://x').searchParams.get('author');
      return void response.end(
        JSON.stringify(
          Object.entries(REPOS)
            .filter(([id]) => id.startsWith(`${author}/`))
            .map(([id, repo]) => ({ id, downloads: repo.downloads })),
        ),
      );
    }
    const repo =
      REPOS[url.replace('/api/models/', '').replace('/tree/main', '')];
    if (!repo) {
      response.statusCode = 404;
      return void response.end('{}');
    }
    const name = url.split('/')[4] ?? '';
    const base = name.replace('-GGUF', '');
    response.end(
      JSON.stringify([
        { path: 'README.md', size: 1000 },
        ...Object.entries(repo.files).map(([q, gb]) => ({
          path: `${base}-${q}.gguf`,
          size: gb * GIB,
        })),
        { path: `${base}-Q4_K_M-00001-of-00002.gguf`, size: 99 * GIB },
      ]),
    );
  });
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  return `http://127.0.0.1:${typeof address === 'object' && address ? address.port : 0}`;
}
const machine = (
  gb: number,
  diskGb: number,
  appleSilicon: boolean,
  gpuGb: number | null = null,
) => ({
  memoryBytes: gb * GIB,
  freeDiskBytes: diskGb * GIB,
  appleSilicon,
  gpu: gpuGb === null ? null : { name: 'Test GPU', memoryBytes: gpuGb * GIB },
});

describe('live model catalog', () => {
  it('picks the largest model that fits and the best quantization for it', async () => {
    const catalog = new HuggingFaceCatalog(await fakeHub());
    const models = await catalog.recommend(machine(24, 500, true));
    // 24 GB x 0.65 - 1.5 GB = 14.1 GB for the model.
    const best = models.find((model) => model.best);
    expect(best).toMatchObject({
      id: 'hf.co/bartowski/Qwen2.5-14B-Instruct-GGUF:Q6_K',
      quantization: 'Q6_K',
      downloadGb: 12.1,
      fits: true,
    });
    expect(models.find((m) => m.label.includes('32B'))).toMatchObject({
      fits: false,
      blocker: 'memory',
      quantization: 'Q4_K_M',
    });
  });

  it('ignores embedding models, non-instruct models, and split files', async () => {
    const models = await new HuggingFaceCatalog(await fakeHub()).recommend(
      machine(64, 500, true),
    );
    expect(models.map((m) => m.label).sort()).toEqual([
      'Llama 3.2 3B Instruct',
      'Qwen2.5 14B Instruct',
      'Qwen2.5 32B Instruct',
      'Qwen3 4B Instruct 2507',
    ]);
    expect(models.every((m) => m.downloadGb < 90)).toBe(true);
  });

  it('shrinks the choice on a small computer and explains a disk shortage', async () => {
    const catalog = new HuggingFaceCatalog(await fakeHub());
    // 8 GB x 0.5 - 1.5 GB = 2.5 GB: the 3B model fits at Q5_K_M only.
    const small = await catalog.recommend(machine(8, 500, false));
    expect(small.find((m) => m.best)).toMatchObject({
      quantization: 'Q5_K_M',
      label: 'Llama 3.2 3B Instruct',
    });
    const cramped = await catalog.recommend(machine(8, 2, false));
    expect(cramped.some((m) => m.best)).toBe(false);
    expect(cramped.find((m) => m.label.includes('3B'))?.blocker).toBe('disk');
  });

  it('sizes the model to a graphics card when there is one', async () => {
    const catalog = new HuggingFaceCatalog(await fakeHub());
    // 64 GB of system memory but a 6 GB card: 6 x 0.9 - 1.5 = 3.9 GB, so only the 3B model fits (Q8_0).
    const withCard = await catalog.recommend(machine(64, 500, false, 6));
    expect(withCard.find((m) => m.best)).toMatchObject({
      label: 'Llama 3.2 3B Instruct',
      quantization: 'Q8_0',
    });
    const without = await catalog.recommend(machine(64, 500, false));
    expect(without.find((m) => m.best)?.label).toContain('32B');
  });

  it('asks Hugging Face once and reuses the answer', async () => {
    const calls: string[] = [];
    const catalog = new HuggingFaceCatalog(await fakeHub(calls));
    await catalog.recommend(machine(16, 500, true));
    const first = calls.length;
    await catalog.recommend(machine(8, 500, false));
    expect(calls.length).toBe(first);
  });

  it('fails with a clear error when Hugging Face is unreachable', async () => {
    await expect(
      new HuggingFaceCatalog('http://127.0.0.1:9').recommend(
        machine(16, 500, true),
      ),
    ).rejects.toThrow();
  });
});

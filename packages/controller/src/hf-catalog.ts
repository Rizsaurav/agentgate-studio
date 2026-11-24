import { z } from 'zod';
import type { SystemProfile } from './system';

const GIB = 1024 ** 3;
const DEFAULT_HF_URL = 'https://huggingface.co';
const REQUEST_TIMEOUT_MS = 8000;
const CACHE_MS = 60 * 60_000;
const CANDIDATES_PER_PUBLISHER = 40;
const REPOS_TO_INSPECT = 14;
/** Memory the runtime needs beyond the weights (context cache, buffers). */
const RUNTIME_OVERHEAD_GB = 1.5;
/** Share of memory a model may use; the rest stays for the system and this app. */
const MEMORY_SHARE = { appleSilicon: 0.65, other: 0.5 } as const;
/** Share of a graphics card's memory a model may fill. */
const GPU_MEMORY_SHARE = 0.9;
const DISK_HEADROOM = 1.5;
/** Highest quality first. A quantization is a smaller, slightly less exact copy of the same model. */
const QUANTIZATIONS = ['Q8_0', 'Q6_K', 'Q5_K_M', 'Q4_K_M'] as const;

/**
 * Publishers whose GGUF conversions of public models are widely used. This is a trust policy,
 * not a model list: only repositories from these accounts are ever suggested.
 */
export const TRUSTED_PUBLISHERS = [
  'bartowski',
  'unsloth',
  'lmstudio-community',
  'ggml-org',
] as const;

const searchSchema = z.array(
  z.object({ id: z.string(), downloads: z.number().default(0) }).loose(),
);
const treeSchema = z.array(
  z.object({ path: z.string(), size: z.number().optional() }).loose(),
);

export type CatalogModel = {
  /** What Ollama is asked to pull. */
  id: string;
  label: string;
  quantization: string;
  downloadGb: number;
  parametersB: number;
  downloads: number;
  fits: boolean;
  blocker: 'memory' | 'disk' | null;
  best: boolean;
};

type Candidate = {
  repo: string;
  label: string;
  parametersB: number;
  downloads: number;
  files: Map<string, number>;
};

const INSTRUCTION_TUNED = /instruct|chat|[-_]it(?:[-_]|$)/i;
const NOT_A_CHAT_MODEL = /embed|rerank|reward|vision|[-_]vl[-_]|guard|whisper/i;

/**
 * Readable name without the publisher's naming habits, so the same model uploaded by two
 * publishers ("Meta-Llama-3.1-8B", "Llama-3.1-8B") collapses to one entry.
 */
function cleanLabel(base: string): string {
  const tokens = base.split(/[-_ ]+/).filter(Boolean);
  const digit = tokens.findIndex((token) => /\d/.test(token));
  if (digit <= 0) return tokens.join(' ');
  const previous = tokens[digit - 1] ?? '';
  const family =
    /^[A-Za-z]+$/.test(previous) &&
    !(tokens[digit] ?? '').toLowerCase().startsWith(previous.toLowerCase());
  return tokens.slice(family ? digit - 1 : digit).join(' ');
}

function describeRepo(
  repo: string,
): { label: string; parametersB: number } | null {
  const name = repo.split('/')[1] ?? '';
  const base = name.replace(/[-_]GGUF$/i, '');
  if (!INSTRUCTION_TUNED.test(base) || NOT_A_CHAT_MODEL.test(base)) return null;
  const size = /(\d+(?:\.\d+)?)B/i.exec(base);
  if (!size?.[1]) return null;
  return { label: cleanLabel(base), parametersB: Number(size[1]) };
}

/** Only single-file conversions: split files (`-00001-of-00003`) would need merging. */
function quantizationOf(path: string): string | null {
  if (/-\d{5}-of-\d{5}/.test(path)) return null;
  const match = /[-_.](Q8_0|Q6_K|Q5_K_M|Q4_K_M)\.gguf$/.exec(path);
  return match?.[1] ?? null;
}

/**
 * Live catalog of Ollama-installable models from Hugging Face. It picks the model and the
 * quantization that fit this computer, so nobody has to know what a quantization is.
 */
export class HuggingFaceCatalog {
  private cache: { at: number; candidates: Candidate[] } | null = null;
  private readonly baseUrl: string;

  constructor(baseUrl: string = DEFAULT_HF_URL) {
    this.baseUrl = new URL(baseUrl).origin;
  }

  async recommend(
    system: Pick<
      SystemProfile,
      'memoryBytes' | 'freeDiskBytes' | 'appleSilicon' | 'gpu'
    >,
  ): Promise<CatalogModel[]> {
    const candidates = await this.candidates();
    // A graphics card is fast only while the model fits in its own memory; otherwise use system memory.
    const memoryBudgetGb = system.gpu
      ? (system.gpu.memoryBytes / GIB) * GPU_MEMORY_SHARE - RUNTIME_OVERHEAD_GB
      : (system.memoryBytes / GIB) *
          (system.appleSilicon
            ? MEMORY_SHARE.appleSilicon
            : MEMORY_SHARE.other) -
        RUNTIME_OVERHEAD_GB;
    const diskGb = system.freeDiskBytes / GIB;
    const models = candidates.flatMap((candidate): CatalogModel[] => {
      const sized = QUANTIZATIONS.flatMap((quantization) => {
        const bytes = candidate.files.get(quantization);
        return bytes === undefined ? [] : [{ quantization, gb: bytes / GIB }];
      });
      // Smallest option, to explain a rejection; best quality that fits memory and disk otherwise.
      const smallest = sized[sized.length - 1];
      const choice =
        sized.find(
          (option) =>
            option.gb <= memoryBudgetGb && option.gb * DISK_HEADROOM <= diskGb,
        ) ?? smallest;
      if (!choice) return [];
      const blocker =
        choice.gb > memoryBudgetGb
          ? ('memory' as const)
          : choice.gb * DISK_HEADROOM > diskGb
            ? ('disk' as const)
            : null;
      return [
        {
          id: `hf.co/${candidate.repo}:${choice.quantization}`,
          label: candidate.label,
          quantization: choice.quantization,
          downloadGb: Math.round(choice.gb * 10) / 10,
          parametersB: candidate.parametersB,
          downloads: candidate.downloads,
          fits: blocker === null,
          blocker,
          best: false,
        },
      ];
    });
    // Largest model that fits is the best choice; popularity breaks ties.
    const ranked = models.sort(
      (a, b) => a.parametersB - b.parametersB || a.downloads - b.downloads,
    );
    const best = [...ranked].reverse().find((model) => model.fits);
    return ranked.map((model) => ({ ...model, best: model === best }));
  }

  private async candidates(): Promise<Candidate[]> {
    if (this.cache && Date.now() - this.cache.at < CACHE_MS)
      return this.cache.candidates;
    const listings = await Promise.all(
      TRUSTED_PUBLISHERS.map(async (author) =>
        searchSchema.parse(
          await this.get(
            `/api/models?author=${author}&filter=gguf&pipeline_tag=text-generation&sort=downloads&limit=${CANDIDATES_PER_PUBLISHER}`,
          ),
        ),
      ),
    );
    const chosen = listings
      .flat()
      .flatMap((entry) => {
        const described = describeRepo(entry.id);
        return described
          ? [{ repo: entry.id, downloads: entry.downloads, ...described }]
          : [];
      })
      .sort((a, b) => b.downloads - a.downloads)
      // The same model from several publishers: keep the most downloaded copy.
      .filter(
        (entry, index, all) =>
          all.findIndex(
            (other) => other.label.toLowerCase() === entry.label.toLowerCase(),
          ) === index,
      )
      .slice(0, REPOS_TO_INSPECT);
    const candidates = await Promise.all(
      chosen.map(async (entry): Promise<Candidate> => {
        const tree = treeSchema.parse(
          await this.get(`/api/models/${entry.repo}/tree/main`),
        );
        const files = new Map<string, number>();
        for (const file of tree) {
          const quantization = quantizationOf(file.path);
          if (quantization && file.size) files.set(quantization, file.size);
        }
        return { ...entry, files };
      }),
    );
    const usable = candidates.filter((candidate) => candidate.files.size > 0);
    if (usable.length === 0)
      throw new Error('Hugging Face returned no installable models.');
    this.cache = { at: Date.now(), candidates: usable };
    return usable;
  }

  private async get(path: string): Promise<unknown> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    if (!response.ok)
      throw new Error(`Hugging Face answered ${response.status}.`);
    return response.json();
  }
}

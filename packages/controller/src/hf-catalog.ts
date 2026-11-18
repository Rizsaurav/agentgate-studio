import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
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
export const TRUSTED_PUBLISHERS: readonly string[] = [
  'bartowski',
  'unsloth',
  'lmstudio-community',
  'ggml-org',
];

const publisherSchema = z
  .string()
  .regex(
    /^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/,
    'Not a Hugging Face account name.',
  );

/**
 * The publishers to search: AGENTGATE_HF_PUBLISHERS (comma-separated) when set, else the trusted
 * defaults. Models from any other account are marked untrusted, and the UI says so.
 */
export function catalogPublishers(value: string | undefined): string[] {
  const listed = (value ?? '')
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean);
  return listed.length === 0
    ? [...TRUSTED_PUBLISHERS]
    : [...new Set(listed.map((name) => publisherSchema.parse(name)))];
}

const searchSchema = z.array(
  z
    .object({
      id: z.string(),
      downloads: z.number().default(0),
      // false, or 'auto' / 'manual' when access must be requested on Hugging Face first.
      gated: z.union([z.boolean(), z.string()]).optional(),
      tags: z.array(z.string()).default([]),
    })
    .loose(),
);
const treeSchema = z.array(
  z
    .object({
      path: z.string(),
      size: z.number().optional(),
      lfs: z.object({ oid: z.string() }).loose().optional(),
    })
    .loose(),
);
const SHA256 = /^[a-f0-9]{64}$/;

const candidateSchema = z
  .object({
    repo: z.string(),
    label: z.string(),
    parametersB: z.number(),
    downloads: z.number(),
    license: z.string().nullable(),
    files: z.array(
      z.tuple([
        z.string(),
        z.object({ bytes: z.number(), sha256: z.string().nullable() }),
      ]),
    ),
  })
  .strict();
/** The last good catalog on disk, so the Models page works without a connection. */
const savedCatalogSchema = z
  .object({
    savedAt: z.iso.datetime(),
    candidates: z.array(candidateSchema).min(1),
  })
  .strict();

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
  /** SPDX-style id from the repository's tags, such as apache-2.0; null when none is given. */
  license: string | null;
  /** False for a publisher added through AGENTGATE_HF_PUBLISHERS that is not a trusted default. */
  trusted: boolean;
  /** The SHA-256 Hugging Face publishes for the file, checked after the download. */
  sha256: string | null;
};

/** Models, and when the live catalog could not be reached, the time of the saved copy used. */
export type CatalogResult = {
  models: CatalogModel[];
  offlineSince: string | null;
};

type Candidate = z.infer<typeof candidateSchema>;
type Loaded = { candidates: Candidate[]; offlineSince: string | null };

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
  private cache: ({ at: number } & Loaded) | null = null;
  private readonly baseUrl: string;
  private readonly publishers: string[];
  private readonly cacheFile: string | null;

  constructor(
    baseUrl: string = DEFAULT_HF_URL,
    options: { publishers?: string[]; cacheFile?: string } = {},
  ) {
    this.baseUrl = new URL(baseUrl).origin;
    this.publishers = options.publishers ?? [...TRUSTED_PUBLISHERS];
    this.cacheFile = options.cacheFile ?? null;
  }

  /** The published SHA-256 of a catalog model's file, from the live or saved catalog. */
  async expectedDigest(modelId: string): Promise<string | null> {
    const match = /^hf\.co\/([^:]+):(.+)$/.exec(modelId);
    if (!match) return null;
    const { candidates } = await this.candidates().catch(() => ({
      candidates: [] as Candidate[],
    }));
    const file = candidates
      .find((candidate) => candidate.repo === match[1])
      ?.files.find(([quantization]) => quantization === match[2]);
    return file?.[1].sha256 ?? null;
  }

  async recommend(
    system: Pick<
      SystemProfile,
      'memoryBytes' | 'freeDiskBytes' | 'appleSilicon' | 'gpu'
    >,
  ): Promise<CatalogResult> {
    const { candidates, offlineSince } = await this.candidates();
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
      const files = new Map(candidate.files);
      const sized = QUANTIZATIONS.flatMap((quantization) => {
        const file = files.get(quantization);
        return file === undefined
          ? []
          : [{ quantization, gb: file.bytes / GIB, sha256: file.sha256 }];
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
          license: candidate.license,
          trusted: TRUSTED_PUBLISHERS.includes(
            candidate.repo.split('/')[0] ?? '',
          ),
          sha256: choice.sha256,
        },
      ];
    });
    // Largest model that fits is the best choice; popularity breaks ties.
    const ranked = models.sort(
      (a, b) => a.parametersB - b.parametersB || a.downloads - b.downloads,
    );
    const best = [...ranked].reverse().find((model) => model.fits);
    return {
      models: ranked.map((model) => ({ ...model, best: model === best })),
      offlineSince,
    };
  }

  /**
   * The live catalog, cached in memory for an hour and saved to disk. When Hugging Face cannot be
   * reached, the last saved copy is used instead, and the result says from when it is.
   */
  private async candidates(): Promise<Loaded> {
    if (this.cache && Date.now() - this.cache.at < CACHE_MS) return this.cache;
    let candidates: Candidate[];
    try {
      candidates = await this.fetchCandidates();
    } catch (error) {
      const saved = this.readSaved();
      if (!saved) throw error;
      // Not cached in memory, so the next request tries the live catalog again.
      return { candidates: saved.candidates, offlineSince: saved.savedAt };
    }
    this.cache = { at: Date.now(), candidates, offlineSince: null };
    this.save(candidates);
    return this.cache;
  }

  private readSaved(): z.infer<typeof savedCatalogSchema> | null {
    if (!this.cacheFile || !existsSync(this.cacheFile)) return null;
    let raw: unknown;
    try {
      raw = JSON.parse(readFileSync(this.cacheFile, 'utf8'));
    } catch (error) {
      if (error instanceof SyntaxError) return null;
      throw error;
    }
    // A damaged or outdated file is ignored; the next live answer replaces it.
    const parsed = savedCatalogSchema.safeParse(raw);
    return parsed.success ? parsed.data : null;
  }

  private save(candidates: Candidate[]): void {
    if (!this.cacheFile) return;
    const temporary = `${this.cacheFile}.tmp`;
    writeFileSync(
      temporary,
      JSON.stringify({ savedAt: new Date().toISOString(), candidates }),
      { mode: 0o600 },
    );
    renameSync(temporary, this.cacheFile);
  }

  private async fetchCandidates(): Promise<Candidate[]> {
    const listings = await Promise.all(
      this.publishers.map(async (author) =>
        searchSchema.parse(
          await this.get(
            `/api/models?author=${encodeURIComponent(author)}&filter=gguf&pipeline_tag=text-generation&sort=downloads&limit=${CANDIDATES_PER_PUBLISHER}&expand%5B%5D=downloads&expand%5B%5D=gated&expand%5B%5D=tags`,
          ),
        ),
      ),
    );
    const chosen = listings
      .flat()
      // Gated models need an accepted license and a token to download, so they cannot install.
      .filter((entry) => entry.gated === undefined || entry.gated === false)
      .flatMap((entry) => {
        const described = describeRepo(entry.id);
        const license =
          entry.tags
            .find((tag) => tag.startsWith('license:'))
            ?.slice('license:'.length) ?? null;
        return described
          ? [
              {
                repo: entry.id,
                downloads: entry.downloads,
                license,
                ...described,
              },
            ]
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
        const files: Candidate['files'] = [];
        for (const file of tree) {
          const quantization = quantizationOf(file.path);
          const sha256 = file.lfs?.oid ?? null;
          if (quantization && file.size)
            files.push([
              quantization,
              {
                bytes: file.size,
                sha256: sha256 && SHA256.test(sha256) ? sha256 : null,
              },
            ]);
        }
        return { ...entry, files };
      }),
    );
    const usable = candidates.filter((candidate) => candidate.files.length > 0);
    if (usable.length === 0)
      throw new Error('Hugging Face returned no installable models.');
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

import { describe, expect, it } from 'vitest';
import { HuggingFaceCatalog } from './index';

/**
 * F5 (#24): a contract test against the real huggingface.co, run weekly by the Scheduled checks
 * workflow (AGENTGATE_HF_CONTRACT=1) and skipped otherwise, so `npm test` stays offline. It fails
 * when the API stops answering in the shape the catalog relies on.
 */
const GIB = 1024 ** 3;

describe.skipIf(!process.env.AGENTGATE_HF_CONTRACT)(
  'Hugging Face API contract',
  () => {
    it('lists installable models from the trusted publishers with sizes, licences and checksums', async () => {
      const catalog = new HuggingFaceCatalog();
      const { models, offlineSince } = await catalog.recommend({
        memoryBytes: 32 * GIB,
        freeDiskBytes: 500 * GIB,
        appleSilicon: true,
        gpu: null,
      });

      expect(offlineSince).toBeNull();
      expect(models.length).toBeGreaterThanOrEqual(4);
      expect(models.filter((model) => model.best)).toHaveLength(1);
      for (const model of models) {
        expect(model.id).toMatch(/^hf\.co\/[\w.-]+\/[\w.-]+:[\w.]+$/);
        expect(model.trusted).toBe(true);
        expect(model.downloadGb).toBeGreaterThan(0);
        expect(model.parametersB).toBeGreaterThan(0);
      }
      // Some repositories carry no licence tag or checksum; most must, or the fields are gone.
      const share = (count: number) => count / models.length;
      expect(share(models.filter((m) => m.license).length)).toBeGreaterThan(
        0.5,
      );
      expect(
        share(models.filter((m) => m.sha256?.match(/^[a-f0-9]{64}$/)).length),
      ).toBeGreaterThan(0.5);

      const withDigest = models.find((model) => model.sha256);
      if (!withDigest) throw new Error('No model carries a checksum.');
      expect(await catalog.expectedDigest(withDigest.id)).toBe(
        withDigest.sha256,
      );
    }, 60_000);
  },
);

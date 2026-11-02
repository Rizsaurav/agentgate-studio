import { execFile } from 'node:child_process';
import { statfsSync } from 'node:fs';
import { arch, cpus, platform, totalmem } from 'node:os';

const GPU_PROBE_TIMEOUT_MS = 3000;
const MIB = 1024 ** 2;

export type SystemProfile = {
  chip: string;
  cores: number;
  memoryBytes: number;
  freeDiskBytes: number;
  /** Apple silicon shares one memory pool between the CPU and GPU, so all of it counts. */
  appleSilicon: boolean;
  /** A separate graphics card with its own memory (NVIDIA), or null when there is none. */
  gpu: { name: string; memoryBytes: number } | null;
};

/** Asks the NVIDIA driver for the card's name and memory. Absent or failing driver means no usable GPU. */
function probeNvidia(): Promise<SystemProfile['gpu']> {
  return new Promise((resolve) => {
    execFile(
      'nvidia-smi',
      ['--query-gpu=name,memory.total', '--format=csv,noheader,nounits'],
      { timeout: GPU_PROBE_TIMEOUT_MS },
      (error, stdout) => {
        // This is an optional probe: most computers have no NVIDIA driver, which is not an error.
        if (error) return resolve(null);
        const [name, memory] = (stdout.split('\n')[0] ?? '')
          .split(',')
          .map((part) => part.trim());
        const megabytes = Number(memory);
        resolve(
          name && Number.isFinite(megabytes) && megabytes > 0
            ? { name, memoryBytes: megabytes * MIB }
            : null,
        );
      },
    );
  });
}

/** What this computer can run, read from the operating system. `diskPath` is where models are stored. */
export async function inspectSystem(diskPath: string): Promise<SystemProfile> {
  const processors = cpus();
  const disk = statfsSync(diskPath);
  return {
    chip: processors[0]?.model.trim() || 'Unknown processor',
    cores: processors.length,
    memoryBytes: totalmem(),
    freeDiskBytes: disk.bavail * disk.bsize,
    appleSilicon: platform() === 'darwin' && arch() === 'arm64',
    gpu: await probeNvidia(),
  };
}

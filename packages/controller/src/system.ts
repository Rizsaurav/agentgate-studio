import { statfsSync } from 'node:fs';
import { arch, cpus, platform, totalmem } from 'node:os';

export type SystemProfile = {
  chip: string;
  cores: number;
  memoryBytes: number;
  freeDiskBytes: number;
  /** Apple silicon shares one memory pool between the CPU and GPU, so all of it counts. */
  appleSilicon: boolean;
};

/** What this computer can run, read from the operating system. `diskPath` is where models are stored. */
export function inspectSystem(diskPath: string): SystemProfile {
  const processors = cpus();
  const disk = statfsSync(diskPath);
  return {
    chip: processors[0]?.model.trim() || 'Unknown processor',
    cores: processors.length,
    memoryBytes: totalmem(),
    freeDiskBytes: disk.bavail * disk.bsize,
    appleSilicon: platform() === 'darwin' && arch() === 'arm64',
  };
}

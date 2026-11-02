import { homedir } from 'node:os';
import { inspectSystem, recommendModels } from '@agentgate/controller';
import { QuickInstall } from './quick-install';

/** Reads this computer's hardware and offers the one model that suits it. */
export function ModelSetup() {
  const system = inspectSystem(homedir());
  const best = recommendModels(system.memoryBytes, system.freeDiskBytes).find(
    (model) => model.best,
  );
  const gb = (bytes: number) => Math.round(bytes / 1024 ** 3);
  return (
    <QuickInstall
      best={
        best
          ? { id: best.id, label: best.label, downloadGb: best.downloadGb }
          : null
      }
      summary={`${system.chip}, ${gb(system.memoryBytes)} GB memory, ${gb(system.freeDiskBytes)} GB free`}
    />
  );
}

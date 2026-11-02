import { prepareEvaluation } from './evaluation-resources.mjs';
import { cp, mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const root = resolve(desktop, '..'),
  stage = join(desktop, 'stage');
const build = spawnSync(
  process.execPath,
  [
    join(root, 'node_modules', 'next', 'dist', 'bin', 'next'),
    'build',
    join(root, 'apps', 'web'),
  ],
  {
    cwd: root,
    stdio: 'inherit',
    env: {
      ...process.env,
      AGENTGATE_DESKTOP_BUILD: '1',
      NEXT_TELEMETRY_DISABLED: '1',
    },
  },
);
if (build.status !== 0) process.exit(build.status ?? 1);
await rm(stage, { recursive: true, force: true });
await mkdir(stage, { recursive: true });
await cp(join(root, 'apps', 'web', '.next', 'standalone'), join(stage, 'web'), {
  recursive: true,
});
await cp(
  join(root, 'apps', 'web', '.next', 'static'),
  join(stage, 'web', 'apps', 'web', '.next', 'static'),
  { recursive: true },
);
// Custom server needs the complete Next runtime, not only its generated server entrypoint trace.
await cp(
  join(root, 'node_modules', 'next'),
  join(stage, 'web', 'node_modules', 'next'),
  { recursive: true },
);
await cp(
  join(root, 'apps', 'web', '.next', 'required-server-files.json'),
  join(stage, 'web', 'apps', 'web', '.next', 'required-server-files.json'),
);
await mkdir(join(stage, 'runtime'), { recursive: true });
await cp(
  join(desktop, 'node_modules', 'node', 'bin', 'node'),
  join(stage, 'runtime', 'node'),
);
for (const file of ['server.mjs', 'access.mjs'])
  await cp(join(desktop, 'scripts', file), join(stage, file));
await cp(join(root, 'fixtures', 'rag'), join(stage, 'reference-documents'), {
  recursive: true,
});
await writeFile(
  join(stage, 'BUILD.json'),
  JSON.stringify(
    { node: '24.22.2', electron: '45.2.1', architecture: process.arch },
    null,
    2,
  ),
);
const dependencies = await prepareEvaluation(root, join(stage, 'evaluation'));
console.log(
  `Desktop resources prepared with ${dependencies} evaluation dependency packages.`,
);

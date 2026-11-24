import { packager } from '@electron/packager';
import { cp, mkdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..'),
  app = join(desktop, 'stage', 'shell');
await rm(app, { recursive: true, force: true });
await mkdir(app, { recursive: true });
await cp(join(desktop, 'dist'), join(app, 'dist'), { recursive: true });
await writeFile(
  join(app, 'package.json'),
  JSON.stringify({
    name: 'agentgate-studio',
    productName: 'AGENTGATE Studio',
    version: '0.1.0',
    type: 'module',
    main: 'dist/main.js',
  }),
);
const paths = await packager({
  dir: app,
  name: 'AGENTGATE Studio',
  appBundleId: 'studio.agentgate.desktop',
  appVersion: '0.1.0',
  platform: 'darwin',
  arch: process.arch,
  electronVersion: '45.2.1',
  out: join(desktop, 'release'),
  overwrite: true,
  asar: false,
  prune: false,
  extraResource: [
    'web',
    'runtime',
    'server.mjs',
    'access.mjs',
    'BUILD.json',
  ].map((path) => join(desktop, 'stage', path)),
  extendInfo: {
    NSHumanReadableCopyright: 'AGENTGATE Studio',
    NSLocalNetworkUsageDescription: 'Connect to your local model runtime.',
  },
});
console.log(paths.join('\n'));

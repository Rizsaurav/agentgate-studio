import { existsSync, readFileSync } from 'node:fs';
import { cp, mkdir, symlink, writeFile } from 'node:fs/promises';
import { dirname, join, relative, resolve } from 'node:path';

/** Copy the installed dependency closure, preserving nested resolution and native binaries.
 * This uses the root lockfile's installation rather than resolving another dependency tree.
 */
export async function prepareEvaluation(root, destination) {
  const copied = new Set();
  function locate(name, from) {
    for (let cursor = from; cursor.startsWith(root); cursor = dirname(cursor)) {
      const candidate = join(cursor, 'node_modules', name);
      if (existsSync(join(candidate, 'package.json'))) return candidate;
      if (cursor === root) break;
    }
    return null;
  }
  async function copyDependency(name, from, optional = false) {
    const path = locate(name, from);
    if (!path) {
      if (optional) return;
      throw new Error(`Missing packaged dependency: ${name}`);
    }
    if (copied.has(path)) return;
    copied.add(path);
    const manifest = JSON.parse(
      readFileSync(join(path, 'package.json'), 'utf8'),
    );
    await cp(path, join(destination, relative(root, path)), {
      recursive: true,
      dereference: true,
    });
    for (const dependency of Object.keys(manifest.dependencies ?? {}))
      await copyDependency(
        dependency,
        path,
        Boolean(manifest.optionalDependencies?.[dependency]),
      );
    for (const dependency of Object.keys(manifest.optionalDependencies ?? {}))
      await copyDependency(dependency, path, true);
    for (const dependency of Object.keys(manifest.peerDependencies ?? {}))
      await copyDependency(dependency, path, true);
  }
  await mkdir(destination, { recursive: true });
  for (const folder of [
    'evals',
    'packages/controller',
    'scanner',
    'fixtures',
  ]) {
    await cp(join(root, folder), join(destination, folder), {
      recursive: true,
      filter: (source) =>
        !source.includes('/.venv') &&
        !source.includes('/__pycache__') &&
        !source.includes('/node_modules'),
    });
  }
  const rootManifest = JSON.parse(
    readFileSync(join(root, 'package.json'), 'utf8'),
  );
  await writeFile(
    join(destination, 'package.json'),
    JSON.stringify({
      name: 'agentgate-evaluation-runtime',
      private: true,
      type: 'module',
      scripts: {
        eval: rootManifest.scripts.eval,
        'eval:weak': rootManifest.scripts['eval:weak'],
      },
    }),
  );
  const controller = JSON.parse(
    readFileSync(join(root, 'packages/controller/package.json'), 'utf8'),
  );
  for (const dependency of [
    'promptfoo',
    'tsx',
    ...Object.keys(controller.dependencies),
  ])
    await copyDependency(dependency, root);
  await mkdir(join(destination, 'node_modules', '.bin'), { recursive: true });
  await symlink(
    '../promptfoo/dist/src/entrypoint.js',
    join(destination, 'node_modules', '.bin', 'promptfoo'),
  );
  return copied.size;
}

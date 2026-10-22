// Copies the WebAssembly module of zaml into the package.
//
// The module is built by the build script of the repository:
//   zig build wasm
//
// The package loads it from next to the JavaScript, so the two have to
// end up in the same directory.

import { copyFile, mkdir } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(here, '..');
const repositoryRoot = join(packageRoot, '..', '..');

const sources = [
  join(repositoryRoot, 'zig-out', 'dist', 'wasm', 'zaml.wasm'),
  join(repositoryRoot, 'dist', 'wasm', 'zaml.wasm'),
];

let copied = false;
for (const source of sources) {
  try {
    await copyFile(source, join(packageRoot, 'dist', 'zaml.wasm'));
    copied = true;
    break;
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
}

if (!copied) {
  console.error('zamljs: the WebAssembly module is missing, run "zig build wasm" first');
  process.exit(1);
}

await mkdir(join(packageRoot, 'dist'), { recursive: true });
console.log('zamljs: the WebAssembly module is in place');

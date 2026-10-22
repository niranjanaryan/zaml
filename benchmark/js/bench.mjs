// Compares zamljs (the WebAssembly build of the parser) with the
// parsers of the JavaScript ecosystem on the same fixture.
//
// The fixture is the one the other benchmarks use:
//
//   python3 benchmark/gen_big_yaml.py 100000 benchmark/big.yml
//
// The parser under test is the one the npm package ships, so build it
// first:
//
//   zig build wasm
//   (cd packages/zamljs && npm install && npm run build)
//
// Run it with:
//
//   node bench.mjs [fixture] [runs]

import { readFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';

import { parse as zamlParse, parseCbor } from '../../packages/zamljs/dist/node.js';
import { load as jsYamlLoad } from 'js-yaml';
import { parse as yamlParse } from 'yaml';

const here = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = join(here, '..', '..');

const fixture = process.argv[2] ?? join(repositoryRoot, 'benchmark', 'big.yml');
const runs = Number(process.argv[3] ?? 3);
// The parsers to run, as a comma separated list of their names. Every
// parser runs when the list is empty.
const only = (process.argv[4] ?? '')
  .split(',')
  .map((name) => name.trim())
  .filter((name) => name.length > 0);

const contents = await readFile(fixture, 'utf8');
const size = (await readFile(fixture)).length;

const all = [
  { name: 'zamljs (WASM, libyaml)', run: () => zamlParse(contents) },
  { name: 'zamljs (WASM, raw CBOR)', run: () => parseCbor(contents) },
  { name: 'js-yaml 5 (pure JavaScript)', run: () => jsYamlLoad(contents) },
  { name: 'yaml 2 (pure JavaScript)', run: () => yamlParse(contents) },
];

const parsers = only.length > 0
  ? all.filter((parser) => only.some((name) => parser.name.includes(name)))
  : all;

/** The time of `fn`, in milliseconds. */
function time(fn) {
  const start = performance.now();
  fn();
  return performance.now() - start;
}

// A warm-up run of every parser, so the numbers do not include the
// time the first parse spends on the lazily grown heap.
for (const parser of parsers) parser.run();

const results = [];
for (const parser of parsers) {
  const times = [];
  for (let index = 0; index < runs; index += 1) times.push(time(parser.run));
  const avg = times.reduce((sum, value) => sum + value, 0) / times.length;
  results.push({
    name: parser.name,
    avg,
    min: Math.min(...times),
    max: Math.max(...times),
  });
}

const fastest = Math.min(...results.map((result) => result.avg));

console.log(`Fixture: ${fixture} (${(size / 1024 / 1024).toFixed(1)} MB), ${runs} runs\n`);
console.log('| Parser | Avg (s) | Min (s) | Max (s) | Relative |');
console.log('| --- | ---: | ---: | ---: | ---: |');
for (const result of results) {
  console.log(
    `| ${result.name} | ${(result.avg / 1000).toFixed(2)} | ${(result.min / 1000).toFixed(2)} ` +
      `| ${(result.max / 1000).toFixed(2)} | ${(result.avg / fastest).toFixed(2)}x |`,
  );
}

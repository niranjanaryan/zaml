// The browser entry point of the package.
//
// It loads the WebAssembly module with `fetch` instead of reading it
// from the disk, so the test replaces `fetch` with one that answers
// with the module itself.

import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const wasm = await readFile(new URL('../dist/zaml.wasm', import.meta.url));

const originalFetch = globalThis.fetch;
globalThis.fetch = async (url) => {
  assert.match(String(url), /zaml\.wasm$/);
  return new Response(wasm, { status: 200 });
};

const { parse, parseCbor, parseJson, ZamlError } = await import('../dist/index.js');

globalThis.fetch = originalFetch;

test('the browser entry point loads the module', () => {
  assert.equal(typeof parse, 'function');
});

test('the browser entry point parses a mapping', () => {
  assert.deepEqual(parse('a: 1\nb: hello\n'), { a: 1, b: 'hello' });
});

test('the browser entry point keeps the scalar kinds', () => {
  assert.deepEqual(parse('null'), null);
  assert.deepEqual(parse('true'), true);
  assert.deepEqual(parse('42'), 42);
  assert.deepEqual(parse('1.5'), 1.5);
  assert.deepEqual(parse('text'), 'text');
});

test('the browser entry point keeps large integers exact', () => {
  const value = parse('9007199254740993');
  assert.equal(typeof value, 'bigint');
  assert.equal(value, 9007199254740993n);
});

test('the browser entry point reports the place of an error', () => {
  assert.throws(
    () => parse('a: [1, 2\n'),
    (error) => {
      assert.ok(error instanceof ZamlError);
      assert.equal(error.line, 2);
      assert.equal(error.column, 1);
      return true;
    },
  );
});

test('the browser entry point returns the raw formats', () => {
  assert.deepEqual([...parseCbor('a: 1\n')], [0xa1, 0x61, 0x61, 0x01]);
  assert.equal(new TextDecoder().decode(parseJson('a: 1\n')), '{"a":1}');
});

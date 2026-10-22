import assert from 'node:assert/strict';
import test from 'node:test';

import { parse, parseCbor, parseJson, ZamlError } from '../dist/node.js';

test('parses a mapping', () => {
  assert.deepEqual(parse('a: 1\nb: hello\n'), { a: 1, b: 'hello' });
});

test('parses a sequence', () => {
  assert.deepEqual(parse('- 1\n- two\n- true\n'), [1, 'two', true]);
});

test('parses the scalar kinds', () => {
  assert.deepEqual(parse('null'), null);
  assert.deepEqual(parse('true'), true);
  assert.deepEqual(parse('false'), false);
  assert.deepEqual(parse('42'), 42);
  assert.deepEqual(parse('-42'), -42);
  assert.deepEqual(parse('1.5'), 1.5);
  assert.deepEqual(parse('text'), 'text');
});

test('keeps large integers exact', () => {
  const value = parse('9007199254740993');
  assert.equal(typeof value, 'bigint');
  assert.equal(value, 9007199254740993n);
});

test('keeps small integers as numbers', () => {
  const value = parse('9007199254740991');
  assert.equal(typeof value, 'number');
  assert.equal(value, 9007199254740991);
});

test('keeps binary values binary', () => {
  const value = parse('data: !!binary aGVsbG8=');
  assert.ok(value.data instanceof Uint8Array);
  assert.equal(new TextDecoder().decode(value.data), 'hello');
});

test('resolves anchors and aliases', () => {
  assert.deepEqual(parse('a: &x 1\nb: *x\n'), { a: 1, b: 1 });
});

test('keeps non string keys in a map', () => {
  const value = parse('1: one\n2: two\n');
  assert.ok(value instanceof Map);
  assert.equal(value.get(1), 'one');
});

test('an empty document is null', () => {
  assert.equal(parse(''), null);
});

test('reports the place of an error', () => {
  assert.throws(
    () => parse('a: [1, 2\n'),
    (error) => {
      assert.ok(error instanceof ZamlError);
      assert.equal(error.line, 2);
      assert.equal(error.column, 1);
      assert.match(error.message, /did not find expected/);
      return true;
    },
  );
});

test('the raw CBOR is CBOR', () => {
  const bytes = parseCbor('a: 1\n');
  assert.deepEqual([...bytes], [0xa1, 0x61, 0x61, 0x01]);
});

test('the raw JSON is JSON', () => {
  const bytes = parseJson('a: 1\n');
  assert.equal(new TextDecoder().decode(bytes), '{"a":1}');
});

test('bytes are accepted as input', () => {
  const bytes = new TextEncoder().encode('a: 1\n');
  assert.deepEqual(parse(bytes), { a: 1 });
});

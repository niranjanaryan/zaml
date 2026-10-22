// A type level test of the public API.
//
// It is not run, only type checked: `npm run typecheck` compiles it
// with `tsc --noEmit` and fails when a type of the package is wrong.

import {
  parse,
  parseCbor,
  parseJson,
  ZamlError,
  type ZamlInput,
  type ZamlValue,
} from '../src/index.js';

const value: ZamlValue = parse('a: 1\n');
const cbor: Uint8Array = parseCbor('a: 1\n');
const json: Uint8Array = parseJson('a: 1\n');

const fromBytes: ZamlValue = parse(new Uint8Array([0x61, 0x3a, 0x20]));
const fromBuffer: ZamlValue = parse(new ArrayBuffer(0));
const fromInput: ZamlValue = parse('a: 1\n' as ZamlInput);

const error = new ZamlError('boom', 2, 1);
const line: number = error.line;
const column: number = error.column;
const message: string = error.message;

// @ts-expect-error the input has to be a string, bytes or a buffer
parse(42);

// @ts-expect-error the result of a parse is a value, not a number
const wrong: number = parse('a: 1\n');

// @ts-expect-error the line of an error is a number
const wrongLine: string = error.line;

export {
  value,
  cbor,
  json,
  fromBytes,
  fromBuffer,
  fromInput,
  line,
  column,
  message,
  wrong,
  wrongLine,
};

/**
 * zaml for Node.js, Bun and Deno.
 *
 * The WebAssembly module sits next to this file and is read from the
 * disk when the package is imported.
 */

import { readFile } from 'node:fs/promises';

import { Zaml } from './runtime.js';
import { ZamlError, type ZamlInput, type ZamlValue } from './types.js';

const wasm = new Uint8Array(await readFile(new URL('./zaml.wasm', import.meta.url)));

const zaml = new Zaml(wasm);

/** Parse a YAML document into a JavaScript value. */
export function parse(input: ZamlInput): ZamlValue {
  return zaml.parse(input);
}

/** Parse a YAML document into its raw CBOR. */
export function parseCbor(input: ZamlInput): Uint8Array {
  return zaml.parseCbor(input);
}

/** Parse a YAML document into its raw JSON. */
export function parseJson(input: ZamlInput): Uint8Array {
  return zaml.parseJson(input);
}

export { ZamlError };
export type { ZamlInput, ZamlValue };

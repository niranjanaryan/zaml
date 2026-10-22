/**
 * zaml for browsers.
 *
 * The WebAssembly module sits next to this file and is fetched when the
 * package is imported.
 */

import { Zaml } from './runtime.js';
import { ZamlError, type ZamlInput, type ZamlValue } from './types.js';

const response = await fetch(new URL('./zaml.wasm', import.meta.url));
if (!response.ok) {
  throw new Error(`zaml: cannot load the WebAssembly module (${response.status})`);
}
const wasm = new Uint8Array(await response.arrayBuffer());

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

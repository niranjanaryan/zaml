/**
 * The driver of the zaml WebAssembly module.
 *
 * The module reads the YAML text from the linear memory of the
 * WebAssembly instance and writes the encoded result back into it. The
 * memory grows while it works, so every view into it has to be built
 * after the call that may have grown it.
 */

import { decodeCbor } from './cbor.js';
import { ZamlError, type ZamlInput, type ZamlValue } from './types.js';

const FORMAT_CBOR = 0;
const FORMAT_JSON = 1;

interface ZamlExports {
  memory: WebAssembly.Memory;
  zaml_alloc(length: number): number;
  zaml_free(pointer: number, length: number): void;
  zaml_parse(pointer: number, length: number, format: number): number;
  zaml_result_ptr(): number;
  zaml_result_len(): number;
  zaml_error_ptr(): number;
  zaml_error_len(): number;
}

/** The zaml parser. */
export class Zaml {
  readonly #exports: ZamlExports;

  constructor(wasm: Uint8Array | WebAssembly.Module) {
    let module: WebAssembly.Module;
    if (wasm instanceof WebAssembly.Module) {
      module = wasm;
    } else {
      // The copy keeps the buffer a plain ArrayBuffer, which is what the
      // WebAssembly API takes.
      const copy = new Uint8Array(wasm.byteLength);
      copy.set(wasm);
      module = new WebAssembly.Module(copy);
    }
    const instance = new WebAssembly.Instance(module, {});
    this.#exports = instance.exports as unknown as ZamlExports;
  }

  /** The raw CBOR of a document. */
  parseCbor(input: ZamlInput): Uint8Array {
    return this.#run(input, FORMAT_CBOR);
  }

  /** The raw JSON of a document. */
  parseJson(input: ZamlInput): Uint8Array {
    return this.#run(input, FORMAT_JSON);
  }

  /** The document as a JavaScript value. */
  parse(input: ZamlInput): ZamlValue {
    return decodeCbor(this.parseCbor(input));
  }

  #run(input: ZamlInput, format: number): Uint8Array {
    const bytes = toBytes(input);
    const exports = this.#exports;

    let pointer = 0;
    if (bytes.length > 0) {
      pointer = exports.zaml_alloc(bytes.length);
      if (pointer === 0) throw new Error('zaml: out of memory');
      // The allocation may have grown the memory, so the view is built
      // after it.
      new Uint8Array(exports.memory.buffer, pointer, bytes.length).set(bytes);
    }

    const code = exports.zaml_parse(pointer, bytes.length, format);
    if (code !== 0) {
      const error = this.#error();
      if (pointer !== 0) exports.zaml_free(pointer, bytes.length);
      throw error;
    }

    const resultPointer = exports.zaml_result_ptr();
    const resultLength = exports.zaml_result_len();
    const result = new Uint8Array(exports.memory.buffer, resultPointer, resultLength).slice();
    if (pointer !== 0) exports.zaml_free(pointer, bytes.length);
    return result;
  }

  #error(): ZamlError {
    const exports = this.#exports;
    const pointer = exports.zaml_error_ptr();
    const length = exports.zaml_error_len();
    const message = new TextDecoder().decode(
      new Uint8Array(exports.memory.buffer, pointer, length),
    );
    const match = /^line (\d+), column (\d+):/.exec(message);
    if (match) {
      return new ZamlError(message, Number(match[1]), Number(match[2]));
    }
    return new ZamlError(message);
  }
}

/** The bytes of the input. */
function toBytes(input: ZamlInput): Uint8Array {
  if (typeof input === 'string') return new TextEncoder().encode(input);
  if (input instanceof Uint8Array) return input;
  return new Uint8Array(input);
}

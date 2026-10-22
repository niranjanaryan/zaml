/**
 * A decoder for the CBOR the zaml module produces.
 *
 * The module encodes the document so that nothing is lost on the way to
 * JavaScript: integers that do not fit a `number` become `bigint`, and
 * binary values stay binary.
 */

import type { ZamlValue } from './types.js';

const MAX_SAFE = Number.MAX_SAFE_INTEGER;

class Reader {
  readonly bytes: Uint8Array;
  readonly view: DataView;
  offset = 0;

  constructor(bytes: Uint8Array) {
    this.bytes = bytes;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  byte(): number {
    if (this.offset >= this.bytes.length) throw new Error('unexpected end of CBOR data');
    const value = this.bytes[this.offset]!;
    this.offset += 1;
    return value;
  }

  take(length: number): Uint8Array {
    if (this.offset + length > this.bytes.length) {
      throw new Error('unexpected end of CBOR data');
    }
    const slice = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    return slice;
  }

  /**
   * The argument of a head.
   *
   * A 64 bit argument does not always fit a `number`, so it is returned
   * as a `bigint` when it does not.
   */
  argument(additional: number): number | bigint {
    if (additional < 24) return additional;
    switch (additional) {
      case 24:
        return this.byte();
      case 25: {
        const value = this.view.getUint16(this.offset, false);
        this.offset += 2;
        return value;
      }
      case 26: {
        const value = this.view.getUint32(this.offset, false);
        this.offset += 4;
        return value;
      }
      case 27: {
        const value = this.view.getBigUint64(this.offset, false);
        this.offset += 8;
        return value <= BigInt(MAX_SAFE) ? Number(value) : value;
      }
      default:
        throw new Error(`invalid CBOR head: ${additional}`);
    }
  }

  /** The argument of a head, as a length. */
  length(additional: number): number {
    const value = this.argument(additional);
    if (typeof value === 'bigint') throw new Error('CBOR length is too large');
    return value;
  }
}

/** Decode the CBOR of a zaml document. */
export function decodeCbor(bytes: Uint8Array): ZamlValue {
  return read(new Reader(bytes));
}

function read(reader: Reader): ZamlValue {
  const head = reader.byte();
  const major = head >> 5;
  const additional = head & 0x1f;

  switch (major) {
    case 0:
      // An unsigned integer.
      return reader.argument(additional);
    case 1: {
      // A negative integer: the value is -1 - n.
      const value = reader.argument(additional);
      return typeof value === 'bigint' ? -1n - value : -1 - value;
    }
    case 2:
      return reader.take(reader.length(additional)).slice();
    case 3:
      return new TextDecoder().decode(reader.take(reader.length(additional)));
    case 4: {
      const length = reader.length(additional);
      const items: ZamlValue[] = [];
      for (let index = 0; index < length; index += 1) items.push(read(reader));
      return items;
    }
    case 5: {
      const length = reader.length(additional);
      const keys: unknown[] = [];
      const values: ZamlValue[] = [];
      let onlyStrings = true;
      for (let index = 0; index < length; index += 1) {
        const key = read(reader);
        const value = read(reader);
        if (typeof key !== 'string') onlyStrings = false;
        keys.push(key);
        values.push(value);
      }
      if (onlyStrings) {
        const object: { [key: string]: ZamlValue } = {};
        for (let index = 0; index < length; index += 1) {
          object[keys[index] as string] = values[index]!;
        }
        return object;
      }
      const map = new Map<unknown, ZamlValue>();
      for (let index = 0; index < length; index += 1) map.set(keys[index], values[index]!);
      return map;
    }
    case 6: {
      // A tagged value. zaml only writes bignums.
      const tag = reader.length(additional);
      const value = read(reader);
      if (tag === 2 || tag === 3) {
        const magnitude = value as Uint8Array;
        let result = 0n;
        for (const byte of magnitude) result = (result << 8n) | BigInt(byte);
        return tag === 3 ? -1n - result : result;
      }
      return value;
    }
    case 7: {
      switch (additional) {
        case 20:
          return false;
        case 21:
          return true;
        case 22:
        case 23:
          return null;
        case 25: {
          const value = reader.view.getUint16(reader.offset, false);
          reader.offset += 2;
          return halfToNumber(value);
        }
        case 26: {
          const value = reader.view.getFloat32(reader.offset, false);
          reader.offset += 4;
          return value;
        }
        case 27: {
          const value = reader.view.getFloat64(reader.offset, false);
          reader.offset += 8;
          return value;
        }
        default:
          throw new Error(`unsupported CBOR value: ${additional}`);
      }
    }
    default:
      throw new Error(`invalid CBOR major type: ${major}`);
  }
}

/** Read a half precision float. */
function halfToNumber(bits: number): number {
  const sign = bits & 0x8000 ? -1 : 1;
  const exponent = (bits >> 10) & 0x1f;
  const fraction = bits & 0x3ff;
  if (exponent === 0) return sign * 2 ** -14 * (fraction / 1024);
  if (exponent === 0x1f) return fraction === 0 ? sign * Infinity : NaN;
  return sign * 2 ** (exponent - 15) * (1 + fraction / 1024);
}

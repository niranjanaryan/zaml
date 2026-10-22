/**
 * The types of the zaml package.
 */

/** A value of a YAML document. */
export type ZamlValue =
  | null
  | boolean
  | number
  | bigint
  | string
  | Uint8Array
  | ZamlValue[]
  | { [key: string]: ZamlValue }
  | Map<unknown, ZamlValue>;

/** The input of a parse. */
export type ZamlInput = string | Uint8Array | ArrayBuffer;

/** A YAML document that could not be parsed. */
export class ZamlError extends Error {
  /** The line the error was found on, 1 based. */
  readonly line: number;
  /** The column the error was found on, 1 based. */
  readonly column: number;

  constructor(message: string, line = 0, column = 0) {
    super(message);
    this.name = 'ZamlError';
    this.line = line;
    this.column = column;
  }
}

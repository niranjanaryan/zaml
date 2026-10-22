# zamljs

YAML parsing for JavaScript and TypeScript, powered by
[libyaml](https://pyyaml.org/wiki/LibYAML) compiled to WebAssembly.

`zamljs` is the browser and Node.js face of
[`zaml`](https://github.com/niranjanaryan/zaml), the fast YAML 1.2 parser
that also ships as an Elixir NIF, a CPython extension and a Wasmer command.
The same parser and the same rules are behind all of them.

- No runtime dependencies, no `node-gyp`, no build step for the consumer.
- Nothing is lost on the way to JavaScript: integers that do not fit a
  `number` come back as `bigint`, binary values stay binary.
- Works in browsers, Node.js, Bun and Deno.

## Install

```console
npm install zamljs
```

## Use

```javascript
import { parse } from 'zamljs';

const value = parse('foo: 1\nbar: [a, b, 3.14]\n');
// { foo: 1, bar: [ 'a', 'b', 3.14 ] }
```

The input is a string, a `Uint8Array` or an `ArrayBuffer`:

```javascript
import { parse } from 'zamljs';

const bytes = new TextEncoder().encode('foo: 1\n');
parse(bytes);
```

TypeScript types come with the package:

```typescript
import { parse, type ZamlValue } from 'zamljs';

const value: ZamlValue = parse('foo: 1\n');
```

## Values

| YAML                     | JavaScript                       |
| ------------------------ | -------------------------------- |
| `42`, `-3`, `+1_000`     | number                           |
| `3.14`, `1.0e-3`         | number                           |
| `true`, `yes`, `on`      | boolean `true`                   |
| `false`, `no`, `off`     | boolean `false`                  |
| `null`, `~`, empty       | `null`                           |
| `9007199254740993`       | `bigint` (exact)                 |
| `!!binary aGVsbG8=`      | `Uint8Array`                     |
| `!!str 42`               | string `"42"` (explicit tag respected) |
| everything else          | string                           |

Sequences become arrays, mappings become objects. A mapping whose keys are
not all strings becomes a `Map`.

## Errors

A document that cannot be parsed throws a `ZamlError` with the place of the
problem:

```javascript
import { parse, ZamlError } from 'zamljs';

try {
  parse('a: [1, 2\n');
} catch (error) {
  if (error instanceof ZamlError) {
    console.log(error.line, error.column, error.message);
    // 2 1 line 2, column 1: did not find expected ',' or ']'
  }
}
```

## Raw output

The parser can also hand back the encoded document, which is what the
`zaml` command writes:

```javascript
import { parseCbor, parseJson } from 'zamljs';

parseCbor('a: 1\n'); // Uint8Array [ 0xa1, 0x61, 0x61, 0x01 ]
parseJson('a: 1\n'); // Uint8Array of '{"a":1}'
```

CBOR keeps every integer exactly, which JSON cannot.

## How it works

The package ships a WebAssembly module built from the same libyaml sources
the native builds use. The module is instantiated when the package is
imported; in the browser it is fetched from next to the JavaScript, in Node
it is read from the disk.

The module writes the document while libyaml parses it: the events of the
parse go straight into the encoder, so the document is never held as a tree
of values. A 14 MB document needs about 80 MB of WebAssembly memory that
way, instead of the 550 MB a tree of values costs.

The `browser` and `node` export conditions pick the right loader, so a
bundler picks the browser build and Node picks the file system one.

## License

MIT, see the [license](https://github.com/niranjanaryan/zaml/blob/main/LICENSE).

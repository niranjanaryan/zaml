# The JavaScript benchmark

The last run of the benchmark, on a 14.5 MB fixture with 100 000
top-level keys, each holding a nested map (strings, integers, floats,
booleans, a list and a nested map).

The numbers are from an Apple Silicon laptop with Node 26, and the
WebAssembly module is built with `-Doptimize=ReleaseSmall`, the same
way the release builds it.

| Parser | Avg (s) | Min (s) | Max (s) | Relative |
| --- | ---: | ---: | ---: | ---: |
| `zamljs` (raw CBOR) | 0.67 | 0.66 | 0.68 | 1.00× |
| `zamljs` (value) | 0.91 | 0.89 | 0.92 | 1.36× |
| `js-yaml 5` (pure JavaScript) | 0.49 | 0.47 | 0.49 | 0.73× |
| `yaml 2` (pure JavaScript) | 412.73 | 412.73 | 412.73 | 616× |

`yaml 2` was measured with a single run, because one parse of the
fixture takes minutes.

## Reading the numbers

- The **raw CBOR** row is the parser alone: it reads the YAML and
  writes the encoded document. The **value** row adds the step that
  turns the CBOR into a JavaScript value, which is what `parse()`
  returns.
- `js-yaml` is the fastest of the three, because it builds the
  JavaScript value directly and never encodes anything. The gap is the
  price of the WebAssembly boundary: the document crosses it as CBOR.
- `yaml 2` builds a document model of its own and is two orders of
  magnitude slower on a document of this size.

## Memory

The WebAssembly module writes the document while libyaml parses it, so
the document is never held as a tree of values:

| Build | Memory for the 14.5 MB fixture |
| --- | ---: |
| The tree of values | 555 MB |
| The streaming encoders | 80 MB |

The numbers are the size of the WebAssembly memory after the parse.

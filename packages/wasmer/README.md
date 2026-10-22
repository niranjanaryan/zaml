# zaml

YAML to JSON and CBOR from the command line.

`zaml` is a fast YAML 1.2 parser built on
[libyaml](https://pyyaml.org/wiki/LibYAML) compiled to WebAssembly. It
reads a document on standard input and writes the parsed document to
standard output. The same parser and the same rules are behind the
[`zaml`](https://hex.pm/packages/zaml) Elixir NIF, the
[`zamljs`](https://www.npmjs.com/package/zamljs) JavaScript package and the
[`zamlpy`](https://pypi.org/project/zamlpy) CPython extension.

## Install

```console
wasmer install niranjanaryan/zaml
```

## Use

```console
$ echo 'foo: 1
bar: [a, b, 3.14]' | wasmer run niranjanaryan/zaml
{"foo":1,"bar":["a","b",3.14]}
```

The output is JSON by default. CBOR keeps the exact value of every
integer, which JSON cannot:

```console
$ echo 'big: 123456789012345678901234567890' | wasmer run niranjanaryan/zaml -- --format cbor | xxd
```

A document that cannot be parsed is reported on standard error, and the
command exits with 1:

```console
$ echo 'a: [1, 2' | wasmer run niranjanaryan/zaml
zaml: line 2, column 1: did not find expected ',' or ']'
$ echo $?
1
```

## Examples

```console
# Scalars, nesting and coercions
$ printf 'a: 1\nb: 2.5\nc: true\nd: null\ne: hello\n' | wasmer run niranjanaryan/zaml
{"a":1,"b":2.5,"c":true,"d":null,"e":"hello"}

# Sequences and mappings
$ printf 'foo: 1\nbar: [a, b, 3.14]\n' | wasmer run niranjanaryan/zaml
{"foo":1,"bar":["a","b",3.14]}

# Explicit tags keep strings as strings
$ printf 'x: !!str 123\n' | wasmer run niranjanaryan/zaml
{"x":"123"}

# Anchors and aliases
$ printf 'a: &x 1\nb: *x\n' | wasmer run niranjanaryan/zaml
{"a":1,"b":1}

# Empty document -> null
$ printf '' | wasmer run niranjanaryan/zaml
null
```

## Options

| Option          | Meaning                          |
| --------------- | -------------------------------- |
| `--format json` | Write JSON (the default).        |
| `--format cbor` | Write CBOR.                      |
| `--help`        | Show the usage.                  |

## Performance

The command is a WebAssembly module built from the same libyaml sources
the native builds use. It writes the document while libyaml parses it:
the events of the parse go straight into the encoder, so the document is
never held as a tree of values. A 14 MB document needs about 80 MB of
WebAssembly memory that way, instead of the 550 MB a tree of values
costs, and the parse is about 27% faster as JSON and 18% faster as CBOR
than the value-tree path it replaced.

## Building from a checkout

```bash
zig build wasm-wasi            # writes zig-out/dist/wasm/zaml.wasi.wasm
```

## License

MIT, see the [license](https://github.com/niranjanaryan/zaml/blob/main/LICENSE).

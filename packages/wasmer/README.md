# zaml

YAML to JSON and CBOR from the command line.

`zaml` is a fast YAML 1.2 parser built on
[libyaml](https://pyyaml.org/wiki/LibYAML) compiled to WebAssembly. It
reads a document on standard input and writes the parsed document to
standard output.

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
```

## Options

| Option          | Meaning                          |
| --------------- | -------------------------------- |
| `--format json` | Write JSON (the default).        |
| `--format cbor` | Write CBOR.                      |
| `--help`        | Show the usage.                  |

## License

MIT, see the [license](https://github.com/niranjanaryan/zaml/blob/main/LICENSE).

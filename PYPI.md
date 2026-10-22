# zamlpy

A **fast YAML 1.2 parser for Python**, built in pure Zig by importing
`Python.h` directly — no `clang`, no setuptools C glue, no `cffi`. It wraps
the same [`libyaml`](https://pyyaml.org/wiki/LibYAML) C library that
[PyYAML](https://pyyaml.org/) uses, and turns its event stream into native
Python objects in a single pass.

```python
import zamlpy

zamlpy.load("foo: 1\nbar: [a, b, 3.14]\n")
# {'foo': 1, 'bar': ['a', 'b', 3.14]}
```

The parser is shared with [`zaml`](https://hex.pm/packages/zaml), the
Elixir NIF, [`zamljs`](https://www.npmjs.com/package/zamljs), the
JavaScript package, and the
[`niranjanaryan/zaml`](https://wasmer.io/packages/niranjanaryan/zaml)
Wasmer command. The scalar classification rules are the same everywhere.

## Why?

`PyYAML` is correct and widely used, but its pure-Python loaders are slow
on real workloads. `ruamel.yaml` is slower still. `zamlpy` is a CPython
extension built with Zig, so the libyaml event stream is consumed in C
and turned into Python objects without an interpreter round-trip per
scalar.

On an Apple M3 Pro (Python 3.14), parsing a 15 MB YAML document:

```text
zamlpy              0.51 s    1.0×
PyYAML CSafeLoader  9.16 s   17.8×
PyYAML SafeLoader  33.85 s   65.9×
ruamel.yaml        48.40 s   94.2×
```

## Installation

```console
pip install zamlpy
```

The extension has no Python runtime dependencies. It links libyaml and is
built from source by `pip` through the custom `builder.py` backend, so the
install step compiles the module.

### Prerequisites

- **Python 3.10+** (CPython)
- **Zig 0.16.x** — Zig 0.17 does not build the extension yet, because its
  C importer fails on the headers of the C libraries.
- **libyaml** development headers
  - macOS: `brew install libyaml`
  - Debian/Ubuntu: `apt install libyaml-dev`
  - Alpine: `apk add yaml-dev`
  - Fedora: `dnf install libyaml-devel`

`builder.py` auto-detects libyaml under `/opt/homebrew`, `/usr/local`, and
`/usr`. Override with `YAML_INCLUDE_DIR` / `YAML_LIB_DIR` if it lives
somewhere unusual.

## Usage

```python
import zamlpy

zamlpy.load(yaml: str | bytes) -> object
```

Parses a YAML document and returns native Python objects. Only the first
document in a stream is returned; malformed input raises `ValueError`.

### Examples

```python
import zamlpy

# Scalars / nesting / coercions
zamlpy.load("a: 1\nb: 2.5\nc: true\nd: null\ne: hello\n")
# {'a': 1, 'b': 2.5, 'c': True, 'd': None, 'e': 'hello'}

zamlpy.load("foo: 1\nbar: [a, b, 3.14]\n")
# {'foo': 1, 'bar': ['a', 'b', 3.14]}

zamlpy.load("a:\n  b: [1, 2, 3]\n  c: {d: e}\n")
# {'a': {'b': [1, 2, 3], 'c': {'d': 'e'}}}

# Explicit tags keep strings as strings
zamlpy.load("x: !!str 123")
# {'x': '123'}

# Anchors and aliases
zamlpy.load("a: &x 1\nb: *x\n")
# {'a': 1, 'b': 1}

# Empty document -> None
zamlpy.load("") is None  # True

# Malformed input raises ValueError
zamlpy.load("[unclosed")  # raises ValueError
```

### Scalar resolution

Scalars are resolved with the YAML 1.2 *core* schema:

| YAML scalar              | Python term                       |
| ------------------------ | --------------------------------- |
| `42`, `-3`, `+1_000`     | `int`                             |
| `3.14`, `1.0e-3`         | `float`                           |
| `true`, `yes`, `on`      | `True`                            |
| `false`, `no`, `off`     | `False`                           |
| `null`, `~`, empty       | `None`                            |
| everything else          | `str`                             |
| `!!str 42`               | `"123"` (explicit tag respected)  |
| `!!int "42"`             | `42` (explicit tag respected)     |

### Big integers

Python's `int` is arbitrary precision, so a YAML document with a 200-digit
integer parses correctly:

```python
zamlpy.load("big: 123456789012345678901234567890")
# {'big': 123456789012345678901234567890}
```

PyYAML's `SafeLoader` raises on the same input.

## Building from a checkout

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .          # development checkout
python test.py
```

## Cross-platform notes

- **macOS:** `brew install zig libyaml`.
- **Linux:** tested via Docker (`fedora` base image, `libyaml-devel`
  via the distro package manager).
- **Windows:** the extension does not build yet. The C importer of Zig
  cannot translate the headers of the Windows SDK, so the import of
  `Python.h` fails
  ([translate-c#307](https://codeberg.org/ziglang/translate-c/issues/307)).
  The other hosts (Elixir, JavaScript, Wasmer) are not affected.

## Benchmarks

```bash
cd benchmark
python run_benchmark.py
```

Full report at `benchmark/RESULTS.md` in the repository.

## Project

- Repository: https://github.com/niranjanaryan/zaml
- Elixir package: https://hex.pm/packages/zaml
- JavaScript package: https://www.npmjs.com/package/zamljs
- Wasmer command: https://wasmer.io/packages/niranjanaryan/zaml

The Python distribution is published as `zamlpy`. The PyPI `zaml` project
(owned by a third party) is an unrelated no-op stub.

## License

MIT
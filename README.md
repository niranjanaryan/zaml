# 🚀 zaml

A **fast YAML 1.2 parser for Elixir**, powered by a Zig NIF that wraps
[libyaml](https://pyyaml.org/wiki/LibYAML). Heavily inspired by
[`kubkon/zig-yaml`](https://github.com/kubkon/zig-yaml), with a matching
Python extension that lives in this same repository (see
[Python extension](#python-extension) below). The same parser is also
available for JavaScript (see
[JavaScript package](#javascript-package) below) and as a command that
turns YAML into JSON or CBOR (see
[Command line](#command-line) below).

```elixir
iex> Zaml.load("foo: 1\nbar: [a, b, 3.14]\n")
%{"bar" => ["a", "b", 3.14], "foo" => 1}

iex> Zaml.load("""
...> name: zaml
...> tags: [yaml, elixir, nif, zig]
...> ratio: 3.14
...> flag: true
...> empty: ~
...> """)
%{"name" => "zaml", "tags" => ["yaml", "elixir", "nif", "zig"],
  "ratio" => 3.14, "flag" => true, "empty" => nil}
```

## Why?

The most popular Elixir YAML libraries — [`yaml_elixir`](https://hex.pm/packages/yaml_elixir)
and its underlying [`yamerl`](https://hex.pm/packages/yamerl) — are
pure-Erlang ports. They're correct but slow. The existing native
option on Hex is [`fast_yaml`](https://hex.pm/packages/fast_yaml)
(processone), which is the obvious thing to compare against because it
also wraps `libyaml`.

`Zaml` is `fast_yaml` but with a thinner event-to-term bridge: the
libyaml event stream is consumed in Zig and turned into Erlang terms
in a single pass, building maps directly instead of going through
intermediate proplists. That gives a **~3–3.5× speedup over `fast_yaml`**
across flat and nested mappings, and **36–46× over the pure-Erlang
parsers**. See [benchmarks](#benchmarks) below.

The newer [`glazer`](https://hex.pm/packages/glazer) NIF is the one
library that can beat `Zaml` — it's faster on nested data (~1.3×) and
slower on a single flat 1M-key map (~2.1×). It gets there with a
hand-rolled C++ YAML parser built with profile-guided optimisation,
whereas `Zaml` deliberately stays on top of battle-tested `libyaml`.

The toolchain is also notably lighter: `Zaml` is built with the
single `zig` CLI invocation you see in the `Makefile`, with no
`./configure`, no `rebar3` port-compiler, and no autoconf.

## Benchmarks

Two fixtures, both parsed to native Erlang terms, on an Apple M3 Pro.
Full report at [`benchmark/RESULTS.md`](benchmark/RESULTS.md).

### 1M-line flat mapping (16 MB)

| Parser                              | Avg (s) | Relative |
| ----------------------------------- | -------:| --------:|
| **Zaml (NIF, libyaml + Zig)**       | **0.84**| **1.00×**|
| `glazer 1.1.6` (C++ NIF, PGO)       |  1.73   |   2.06×  |
| `fast_yaml 1.0.40` (rebar3 NIF)     |  2.54   |   3.03×  |
| `yamerl 0.10.0` (pure Erlang)       | 30.27   |  36.1×   |
| `yaml_elixir 2.12.2` (yamerl)       | 30.95   |  36.9×   |

### 100k-key nested mapping (15 MB)

| Parser                              | Avg (s) | Relative |
| ----------------------------------- | -------:| --------:|
| **Zaml (NIF, libyaml + Zig)**       | **0.53**| **1.00×**|
| `glazer 1.1.6` (C++ NIF, PGO)       |  0.41   |   0.77×  |
| `fast_yaml 1.0.40` (rebar3 NIF)     |  1.86   |   3.50×  |
| `yamerl 0.10.0` (pure Erlang)       | 23.88   |  45.0×   |
| `yaml_elixir 2.12.2` (yamerl)       | 24.40   |  45.9×   |

Both `Zaml` and `fast_yaml` wrap the same `libyaml` C parser, so the
~3× gap there is purely the event→term bridge. `glazer` is a
different design (a hand-rolled C++ parser, not libyaml): it wins on
nested data and loses on the wide flat map, so there's no single
"fastest" library across shapes.

## Installation

Add `zaml` to your `mix.exs`:

```elixir
def deps do
  [
    {:zaml, "~> 0.3.0"}
  ]
end
```

### Build prerequisites

The NIF is built at compile time from source. You need:

- **Zig 0.16.x** (`brew install zig`, `apt install zig`, `asdf install zig latest`, …).
  Zig 0.17 does not work yet: its C importer fails on the headers of the
  C libraries.
- **libyaml** development headers
  - macOS: `brew install libyaml`
  - Debian/Ubuntu: `apt install libyaml-dev`
  - Alpine: `apk add yaml-dev`
  - Fedora: `dnf install libyaml-devel`
- An Erlang/OTP installation (any reasonably recent version, 24+)

The compiler auto-detects `libyaml` via `pkg-config` first, then falls
back to well-known locations. Override with `YAML_INCLUDE_DIR` and
`YAML_LIB_DIR` env vars or `make` variables if it lives somewhere
unusual.

```bash
mix deps.get
mix compile   # builds the NIF via elixir_make / Makefile
```

## Usage

```elixir
Zaml.load(yaml_string) :: term
```

Returns the corresponding Elixir term for the **first YAML document** in
the input. Scalar type detection follows the YAML 1.2 *core* schema:

| YAML scalar         | Elixir term       |
| ------------------- | ----------------- |
| `42`, `-3`, `+1_000` | integer (`42`, `-3`, `1000`) |
| `3.14`, `1.0e-3`     | float (`3.14`, `0.001`) |
| `true`, `yes`, `on`  | atom `true` (or `:true` quoted) |
| `false`, `no`, `off` | atom `false` |
| `null`, `~`, empty   | atom `nil` |
| everything else      | binary (string)  |
| `!!str 42`           | binary `"42"` (explicit tag respected) |
| `!!int "42"`         | integer `42` (explicit tag respected) |

Sequences become lists, mappings become maps with binary keys.

Returns `:error` for non-binary input, `:parse_error` for malformed
YAML, and `:nil` for an empty document.

### Examples

```elixir
# Scalars
iex> Zaml.load("42")
42
iex> Zaml.load("-3.14")
-3.14
iex> Zaml.load("yes")
true
iex> Zaml.load("~")
nil
iex> Zaml.load("!!str 123")
"123"

# Nested structures
iex> Zaml.load("""
...> people:
...>   - name: Ada
...>     role: maintainer
...>   - name: Grace
...>     role: contributor
...> """)
%{"people" => [
  %{"name" => "Ada", "role" => "maintainer"},
  %{"name" => "Grace", "role" => "contributor"}
]}

# Explicit tags
iex> Zaml.load("ratio: !!float 3\n")
%{"ratio" => 3.0}
iex> Zaml.load("code: !!int \"42\"\n")
%{"code" => 42}

# Empty and malformed input
iex> Zaml.load("")
nil
iex> Zaml.load("a: [1, 2")
:parse_error
iex> Zaml.load(123)
:error
```

### Anchor / alias example

```elixir
iex> Zaml.load("""
...> defaults: &d {a: 1, b: 2}
...> prod:    *d
...> """)
%{"defaults" => %{"a" => 1, "b" => 2}, "prod" => %{"a" => 1, "b" => 2}}
```

> **Note:** YAML merge keys (`<<: *alias`) are not yet supported.

### Using the alternatives

For reference, here's how the same parse is done with each library the
benchmarks compare against:

```elixir
# zaml — returns the first document as a term
Zaml.load(yaml)

# fast_yaml — returns {:ok, [doc]}; :maps gives maps instead of proplists
:fast_yaml.decode(yaml, [:sane_scalars, :maps])

# glazer — hand-rolled C++ NIF; use_nil maps null -> nil (default is :null)
:glazer_yaml.decode(yaml, [:use_nil])
# ...or the Elixir wrapper:
Glazer.YAML.decode!(yaml)

# yaml_elixir — the most widely used wrapper, over pure-Erlang yamerl
YamlElixir.read_from_string(yaml)   # => {:ok, term}

# yamerl directly (raw records; yaml_elixir adds the Elixir mapper)
:yamerl_constr.string(yaml, detailed_constr: true, str_node_as_binary: true)
```

Two other libraries in the space aren't in the parse benchmarks:
[`ymlr`](https://hex.pm/packages/ymlr) is an **encoder** (`Ymlr.document!/1`),
not a parser, and [`yamleam`](https://hex.pm/packages/yamleam) is a
pure-Gleam parser, so it isn't reachable as a plain Mix dependency.

## Running tests

```bash
mix test
```

The test suite covers basic scalars, nested maps and lists, explicit
tags, anchors, empty input, and parse-error handling.

## Running benchmarks

The repo ships a Mix task that compares the Elixir NIF against
`fast_yaml`, `glazer`, `yaml_elixir`, and `yamerl` on the same fixture
(any parser whose dependency isn't installed is skipped).

```bash
# 1. Build the Elixir NIF + the benchmark deps
#    (glazer needs a C++23 compiler and rebar3; `brew install rebar3`)
mix deps.get
mix compile

# 2. Generate the 100k-key nested fixture
python3 benchmark/gen_big_yaml.py 100000 benchmark/big.yml

# 3. Generate the 1M-line flat fixture
python3 -c "
import yaml
yaml.dump({f'a{i}': f'b{i+1}' for i in range(1_000_000)},
          Dumper=yaml.CSafeDumper, default_flow_style=False,
          open('benchmark/big_1m.yml', 'w'))
"

# 4. Run the head-to-head
mix zaml_nif.bench benchmark/big.yml        # Zaml parse ~0.5 s (all parsers run)
mix zaml_nif.bench benchmark/big_1m.yml     # Zaml parse ~0.8 s (all parsers run)
```

A separate cross-language script (`benchmark/run_benchmark.py`) also
compares against PyYAML and ruamel.yaml if you want the Python
numbers.

## Project layout

```
.
├── lib/
│   ├── zaml.ex                      # public Elixir API
│   └── mix/tasks/
│       ├── zaml_nif.build.ex        # manual NIF build (`mix zaml_nif.build`)
│       └── zaml_nif.bench.ex        # `mix zaml_nif.bench` benchmark task
├── native/
│   └── zaml_nif.zig                 # the NIF (uses libyaml via @cImport)
├── core/                            # the host independent core
│   ├── scalar.zig                   # how a scalar and a tag resolve
│   ├── stream.zig                   # what the streaming encoders share
│   ├── parse.zig, parse_c.zig       # the event stream, native and WASM
│   ├── cbor.zig, json.zig           # the output formats
│   ├── base64.zig, emit.zig, event.zig
│   ├── value.zig                    # the value tree, the reference of the tests
│   └── native.zig                   # what the native hosts share
├── wasm/
│   ├── main.zig                     # the WebAssembly module (browser)
│   ├── wasi_main.zig                # the WASI command
│   ├── alloc.zig, c_abi.zig         # the freestanding heap and the C ABI
│   └── shim/                        # the C bridge to the vendored libyaml
├── packages/
│   ├── zamljs/                      # the npm package
│   └── wasmer/                      # the Wasmer package
├── vendor/libyaml/                  # the libyaml sources the WASM builds use
├── build.zig                        # builds the WebAssembly targets
├── priv/                            # compiled zaml.so lands here
├── test/                            # ExUnit tests
├── benchmark/
│   ├── benchmark.exs                # Elixir side
│   ├── run_benchmark.py             # Python driver
│   ├── gen_big_yaml.py              # fixture generator
│   ├── big.yml                      # generated 100k-key fixture
│   └── RESULTS.md                   # last benchmark run
├── Makefile                         # `make` builds the NIF directly
└── mix.exs
```

## Limitations / status

- YAML merge keys (`<<: *alias`) are not yet expanded.
- Multi-document input returns only the first document.
- Not yet battle-tested on very large or adversarial input. If you find
  a crash, please open an issue with the input.

## Credits

- [`kubkon/zig-yaml`](https://github.com/kubkon/zig-yaml) — the original
  pure-Zig YAML parser that inspired this project.
- [`yaml/libyaml`](https://github.com/yaml/libyaml) — the production
  YAML 1.1 parser that both the Elixir NIF and the Python extension wrap.

---

## Python extension

The original proof-of-concept has grown into a real, `pip install`-able
CPython extension (`zamlpy` 0.3.1, Python 3.10+):
`zamlpy.load(str_or_bytes)` parses a YAML document with libyaml and returns
native Python objects. Like the Elixir NIF, it is built in pure Zig by
importing `Python.h` directly — no `clang` or setuptools C glue. It began
as the subject of a [PyCon DE 2022 talk][talk] on *Speeding Up Python with
Zig*.

[talk]: https://2022.pycon.de/program/DFWSQR/

Scalars are resolved with the YAML 1.2 core schema (`int`, arbitrary-
precision `int`, `float`, `bool`, `null`), `!!str` / `!!int` / `!!float` /
`!!bool` / `!!null` tags are honored, and anchors/aliases are supported.
Only the first document in a stream is returned; malformed input raises
`ValueError`.

### Prerequisites

- **Python 3.10+** (CPython)
- **Zig 0.16.x**
- **libyaml** (`brew install libyaml`, `apt install libyaml-dev`,
  `dnf install libyaml-devel`)

`builder.py` auto-detects libyaml under `/opt/homebrew`, `/usr/local`,
and `/usr`. Override with `YAML_INCLUDE_DIR` / `YAML_LIB_DIR` if needed.

### Building the Python extension

The extension has no Python runtime dependencies; it links libyaml and is
built from source by `pip` (via the custom `builder.py` backend) on
install.

```bash
python -m venv .venv
source .venv/bin/activate
pip install .          # or: pip install -e .   for a development checkout
python test.py
```

> The PyPI `zaml` project (owned by a third party) is an unrelated no-op
> stub. This project's Python distribution is published as `zamlpy`.

### Python benchmark

```bash
cd benchmark
python run_benchmark.py
```

On an Apple M3 Pro (Python 3.14), parsing a 15 MB YAML document:

```text
zamlpy              0.51 s    1.0×
PyYAML CSafeLoader  9.16 s   17.8×
PyYAML SafeLoader  33.85 s   65.9×
ruamel.yaml        48.40 s   94.2×
```

### Python examples

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

`zamlpy.load` accepts a `str` or `bytes` and returns native Python
objects. Integers that do not fit a `number` come back as arbitrary
precision `int` (Python's `int` is unbounded), so a YAML document with a
200-digit integer parses correctly, where PyYAML's `SafeLoader` would
raise.

### Cross-platform notes (Python extension)

- **macOS:** `brew install zig libyaml`.
- **Linux:** tested via Docker (`fedora` base image, `libyaml-devel` via
  the distro package manager).
- **Windows:** the extension does not build yet. The C importer of Zig
  cannot translate the headers of the Windows SDK, so the `Python.h`
  import fails (see
  [translate-c#307](https://codeberg.org/ziglang/translate-c/issues/307)).
  The other hosts (Elixir, JavaScript, Wasmer) are not affected.

---

## JavaScript package

The parser is also available for JavaScript and TypeScript as `zamljs` on
npm. The package ships a WebAssembly module built from the same libyaml
sources as the native builds, so the rules are the same everywhere.

```console
npm install zamljs
```

```javascript
import { parse } from 'zamljs';

parse('foo: 1\nbar: [a, b, 3.14]\n');
// { foo: 1, bar: [ 'a', 'b', 3.14 ] }
```

The package is ESM-only TypeScript with no runtime dependencies and it
ships its own types. It works in browsers, Node.js, Bun and Deno: the
`browser` and `node` export conditions pick the right loader, so a
bundler gets the browser build and Node reads the module from the disk.

Nothing is lost on the way to JavaScript: an integer that does not fit a
`number` comes back as a `bigint`, and a `!!binary` value stays a
`Uint8Array`. A mapping whose keys are not all strings becomes a `Map`.
A document that cannot be parsed throws a `ZamlError` that carries the
line and column of the problem.

`parseCbor` and `parseJson` return the raw encoded document instead of a
value, which is what the command below writes.

### JavaScript examples

```javascript
import { parse, parseCbor, parseJson, ZamlError } from 'zamljs';

// Scalars / nesting / coercions
parse('a: 1\nb: 2.5\nc: true\nd: null\ne: hello\n');
// { a: 1, b: 2.5, c: true, d: null, e: 'hello' }

parse('foo: 1\nbar: [a, b, 3.14]\n');
// { foo: 1, bar: [ 'a', 'b', 3.14 ] }

parse('a:\n  b: [1, 2, 3]\n  c: {d: e}\n');
// { a: { b: [ 1, 2, 3 ], c: { d: 'e' } } }

// Explicit tags keep strings as strings
parse('x: !!str 123');
// { x: '123' }

// Anchors and aliases
parse('a: &x 1\nb: *x\n');
// { a: 1n, b: 1n }

// Empty document -> null
parse('') === null; // true

// Malformed input throws a ZamlError with the position
try {
  parse('a: [1, 2');
} catch (error) {
  if (error instanceof ZamlError) {
    console.log(error.line, error.column, error.message);
  }
}

// Integers that do not fit a number come back as bigint
parse('big: 123456789012345678901234567890');
// { big: 123456789012345678901234567890n }

// !!binary stays a Uint8Array
parse('img: !!binary |\n  RkxPUA==');
// { img: Uint8Array(4) [ 70, 76, 79, 80 ] }

// Raw encodings, the same bytes the command writes
parseCbor('big: 123456789012345678901234567890');
// Uint8Array [ ... ]
parseJson('foo: 1\nbar: [a, b, 3.14]\n');
// Uint8Array [ 123, 34, 102, 111, ... ] == '{"foo":1,"bar":["a","b",3.14]}'
```

Building the package from a checkout:

```bash
zig build wasm                 # builds the WebAssembly module
cd packages/zamljs
npm install
npm run build                  # compiles the TypeScript, copies the module
npm test
```

---

## Command line

The parser is also a command that turns YAML into JSON or CBOR, built for
WASI and published on the [Wasmer registry](https://wasmer.io) as
[`niranjanaryan/zaml`](https://wasmer.io/packages/niranjanaryan/zaml).

```console
wasmer install niranjanaryan/zaml
```

```console
$ echo 'foo: 1
bar: [a, b, 3.14]' | wasmer run niranjanaryan/zaml
{"foo":1,"bar":["a","b",3.14]}
```

The output is JSON by default. CBOR keeps the exact value of every
integer, which JSON cannot:

```console
$ echo 'big: 123456789012345678901234567890' | wasmer run niranjanaryan/zaml -- --format cbor
```

A document that cannot be parsed is reported on standard error, and the
command exits with 1:

```console
$ echo 'a: [1, 2' | wasmer run niranjanaryan/zaml
zaml: line 2, column 1: did not find expected ',' or ']'
```

Building it from a checkout:

```bash
zig build wasm-wasi            # writes zig-out/dist/wasm/zaml.wasi.wasm
```

---

## Building the WebAssembly targets

Both WebAssembly targets are built by the build script of the repository
and need nothing but the Zig toolchain — the libyaml sources they use
are vendored in `vendor/libyaml/`.

```bash
zig build test                 # the tests of the shared core
zig build wasm                 # zig-out/dist/wasm/zaml.wasm
zig build wasm-wasi            # zig-out/dist/wasm/zaml.wasi.wasm
```

The browser module has no imports at all: it grows its own memory and
carries the handful of C functions libyaml needs. The WASI command uses
the C library of the runtime instead.

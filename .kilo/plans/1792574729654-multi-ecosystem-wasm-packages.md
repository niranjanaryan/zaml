# zaml — Multi-ecosystem support: shared Zig core + JS/Wasm (browser, Node/Bun/Deno) + Wasmer

## Goal

Ship one YAML parser (libyaml) to four ecosystems from a single Zig core:

| Host | Artifact | Package |
|---|---|---|
| Elixir | existing NIF (`native/zaml_nif.zig`) | hex `zaml` (unchanged) |
| Python | existing CPython ext (`zamlmodule.zig`) | PyPI `zamlpy` (unchanged) |
| JS/TS | new `wasm32-freestanding` core | npm **`zamljs`** (new) |
| Wasmer | new `wasm32-wasi-musl` CLI | Wasmer **`niranjanaryan/zaml`** (new) |

Preserve existing Elixir/Python behaviour byte-for-byte; the shared core is adopted by
both native hosts *after* the new JS path is green.

## Locked decisions

- Parser backend: **libyaml 0.2.5** (not `benchmark/libs/zig-yaml` — no anchors/aliases, different
  scalar resolution, obsolete Zig APIs).
- Wire format across the WASM↔JS boundary: **both CBOR and JSON**, selectable at runtime.
  - CBOR is the default for `parse()` (exact ints/floats/binary, compact, one buffer copy).
  - JSON is available via `parseToJSON()` and is what the Wasmer CLI prints on stdout.
- JS integers: **Number when `|v| <= Number.MAX_SAFE_INTEGER`, BigInt otherwise** (lossless by
  default, mirrors Python's arbitrary precision).
- npm package: **`zamljs`** (unscoped). Wasmer package: **`niranjanaryan/zaml`**.
- Release: **full CI release automation** (npm publish + `wasmer publish` on GitHub release
  `published`), using `NPM_TOKEN` and `WASMER_REGISTRY_TOKEN` secrets.
- Native Elixir/Python builds keep linking **system libyaml** (`-lyaml`); the WASM builds use a
  **vendored** copy in `vendor/libyaml/`. Both locations are documented; consolidating native onto
  the vendored copy is a follow-up, not this pass.
- Zig pinned to **0.16.0** (CI already pins it; local 0.16.0 and 0.17.0 installed).
- JS package is **ESM-only**, TypeScript source compiled with `tsc` (no bundler, no runtime deps).
- Tests use a **self-contained assertion script** (no test framework) so the identical file runs
  under Node, Bun and Deno.

## Repo layout (new/changed files)

```
core/                       # shared, host-agnostic Zig core
  scalar.zig                # tag/scalar classification (moved out of NIF + py module)
  parse.zig                 # libyaml event loop, comptime-generic over a Sink
  value.zig                 # host-agnostic value tree (used by WASM)
  cbor.zig                  # value tree -> CBOR
  json.zig                  # value tree -> JSON
  base64.zig                # !!binary -> base64 text (JSON output path)
wasm/
  main.zig                  # freestanding exports  -> build/zaml.wasm
  wasi_main.zig             # WASI command         -> build/zaml-wasi.wasm
  shim.c                    # minimal libc for wasm32-freestanding
  shim/include/{assert,stdio,stdlib,string,limits}.h
  config.h                  # YAML_VERSION_* for the vendored libyaml
vendor/libyaml/             # libyaml 0.2.5, parse-only subset, MIT
  LICENSE  README.md  include/yaml.h  src/{yaml_private.h,api.c,loader.c,parser.c,reader.c,scanner.c}
packages/
  zamljs/                   # npm package
    package.json  tsconfig.json  README.md
    src/{index.ts,wasm.ts,cbor.ts,types.ts}
    test/run.ts
  wasmer/
    wasmer.toml  README.md
test/conformance/           # shared YAML fixtures + expected JSON, used by all 4 hosts
Makefile                    # new targets: wasm, wasm-wasi, wasm-test, js-build
```

Changed: `native/zaml_nif.zig`, `zamlmodule.zig`, `Makefile`, `mix.exs` (package `files`),
`MANIFEST.in`, `setup.py` (sources), `.gitignore`, `README.md`, `CHANGELOG.md`,
`.github/workflows/ci.yml`, new `.github/workflows/release.yml`.

## Semantics (must not drift between hosts)

`core/scalar.zig` is the single source of truth for classification; the current duplicated
`is_bool_true/is_bool_false/is_null/is_int_str/is_float_str` blocks in `native/zaml_nif.zig:203-264`
and `zamlmodule.zig:82-143` are deleted in favour of it.

| YAML | Elixir (unchanged) | Python (unchanged) | JS (new) |
|---|---|---|---|
| `1` | `1` | `1` | `1` (Number) |
| `12345678901234567890` | `"12345678901234567890"` (i64 overflow → string) | `12345678901234567890` | `12345678901234567890n` (BigInt) |
| `1.5` | `1.5` | `1.5` | `1.5` |
| `true` / `yes` / `on` | `true` | `True` | `true` |
| `null` / `~` / empty | `nil` | `None` | `null` |
| `!!str "1"` | `"1"` | `"1"` | `"1"` |
| `!!binary` | raw binary | `str` (may raise on non-UTF-8) | `Uint8Array` |
| map with int keys | `%{1 => v}` | `{1: v}` | `Map` (plain object only when **all** keys are strings) |
| empty document | `nil` | `None` | `null` |
| unknown alias | `{:error, :parse_error}` | `ValueError` | `YamlParseError` |

Tag handling keeps the existing `endsWith(tag, ":str" / ":int" / ":float" / ":bool" / ":null")`
logic. Untagged scalars keep the current implicit rules (bool → null → int → float → string).
`!!binary` becomes a distinct value kind in the tree (CBOR byte string); JSON output renders it as
a base64 string. The conformance fixtures contain only JSON-representable values so all four
hosts can share one expectations file.

## WASM ABI (freestanding build, `zaml.wasm`)

Linear memory is exported. All pointers are byte offsets into it.

```
zaml_alloc(len: u32) -> u32            // reserve len bytes for the input; 0 = OOM
zaml_free(ptr: u32, len: u32)          // release a buffer obtained from zaml_alloc
zaml_parse(ptr: u32, len: u32, format: u32) -> u32
                                     // format: 0 = CBOR, 1 = JSON. 0 = ok, nonzero = error code.
                                     // Does NOT take ownership: caller frees the input afterwards.
zaml_result_ptr() -> u32              // encoded result (CBOR or JSON) in linear memory
zaml_result_len() -> u32
zaml_error_ptr() -> u32               // UTF-8 error message ("line 3, column 5: <problem>")
zaml_error_len() -> u32
```

Rules the JS side must honour:

- The result buffer is owned by the module and is freed at the start of the next `zaml_parse`;
  copy it out before parsing again.
- `WebAssembly.Memory.buffer` detaches when memory grows, so the JS side must re-create its
  `Uint8Array` view **after** every `zaml_alloc` / `zaml_parse` call.
- The input is UTF-8 bytes; the JS side encodes with `TextEncoder`.
- Parse errors never trap: `zaml_parse` returns a non-zero code and the message is retrievable.

## Core design

- `core/parse.zig` — `pub fn Parser(comptime Sink: type) type`. `Sink` implements
  `scalar(value, tag)`, `seqStart(anchor?)`, `seqEnd()`, `mapStart(anchor?)`, `mapEnd()`,
  `alias(anchor)`. Comptime generics keep the dispatch static (no per-event indirect call), so
  the NIF hot path is unchanged. The core does **not** resolve anchors: each host keeps its own
  anchor table exactly as today (NIF: name→`ERL_NIF_TERM`; Python: name→`PyObject`; WASM: name→node).
- `core/value.zig` — tree node: `null | bool | int (normalised decimal text + fits-i64 flag) |
  float (f64) | str (bytes) | binary (bytes) | seq | map`. Strings are copied into an arena that
  is released after the result is encoded.
- `core/cbor.zig` — major types: 0/1 = int (u64 / -1-n), tag 2/3 = bignum for values that do not
  fit i64/u64, 2 = binary, 3 = text, 4 = array, 5 = map, 7/20/21/22 = false/true/null,
  7/27 = float64. Map keys keep their own value kind (not stringified).
- `core/json.zig` — null/bool/int (decimal digits verbatim)/float (shortest round-trip; verified by
  a unit test that re-parses to the same bits)/string (escaped, invalid UTF-8 → U+FFFD)/
  binary (base64)/array/object (non-string keys rendered as their JSON text).
- `core/base64.zig` — encoder for the JSON path only.

## Build recipes

Freestanding (browser + Node/Bun/Deno). Known-good shape from the scratch validation; the
libyaml C sources are compiled by `zig cc` and linked with the Zig root:

```sh
zig cc -target wasm32-freestanding -O ReleaseFast -c -DNDEBUG -DHAVE_CONFIG_H \
  -I wasm/shim/include -I vendor/libyaml/include \
  vendor/libyaml/src/{api,loader,parser,reader,scanner}.c
zig build-exe -O ReleaseFast -target wasm32-freestanding -fno-entry \
  -I wasm/shim/include -I vendor/libyaml/include \
  -femit-bin=build/zaml.wasm wasm/main.zig wasm/shim.c <objects>
```

Notes:
- `wasm/shim.c` provides `malloc/free/realloc/calloc/strlen/strcmp/strncmp/memcmp/memcpy/
  memset/memmove/strdup`; `malloc/free/realloc` delegate to `std.heap.wasm_allocator` exported
  from `wasm/main.zig` (the scratch `host.zig` already does this and links).
- `memcpy`/`memset` must not recurse into the compiler intrinsic; implement them as explicit
  loops over `u8` (the scratch `zaml_memcpy`/`zaml_memset` approach) or rely on LLVM lowering
  them to `memory.copy`/`memory.fill` — verify with `wasm-objdump` that the module has **no
  imports** and that the entry point is not garbage-collected.
- `wasm/shim/include/*.h` covers what `yaml.h` and `yaml_private.h` include: `stdio.h`,
  `stdlib.h`, `string.h`, `assert.h`, `limits.h` (`stddef.h`/`stdint.h` come from the compiler).
- `assert.h` is a no-op **and** `-DNDEBUG` is passed, so `__assert_fail` is never referenced.
- `HAVE_CONFIG_H` + `wasm/config.h` supply `YAML_VERSION_STRING`/`MAJOR`/`MINOR`/`PATCH` and
  `YAML_DECLARE_STATIC` (libyaml 0.2.5's `yaml.h` does not define them; only the generated
  `config.h` does, and `api.c` needs `YAML_VERSION_STRING`).

WASI (Wasmer / CLI). `zig cc` is required for the C sources (plain `zig build-exe` does not supply
the WASI include paths), then link with `-lc`:

```sh
zig cc -target wasm32-wasi-musl -O ReleaseFast -c -DNDEBUG -DHAVE_CONFIG_H \
  -I vendor/libyaml/include vendor/libyaml/src/{api,loader,parser,reader,scanner}.c
zig build-exe -O ReleaseFast -target wasm32-wasi-musl -lc \
  -I vendor/libyaml/include -femit-bin=build/zaml-wasi.wasm wasm/wasi_main.zig <objects>
```

If `zig build-exe` refuses pre-built `.o` inputs, fall back to compiling the Zig root with
`zig build-obj -target wasm32-wasi-musl` and linking via `zig cc -target wasm32-wasi-musl`.

## npm package `zamljs`

```ts
import { Zaml, parse, YamlParseError } from 'zamljs';

const zaml = await Zaml.create();          // or: Zaml.create({ wasmUrl })
zaml.parse('a: 1\nb: [x, y]\n');            // => { a: 1, b: ['x', 'y'] }   (sync)
zaml.parseToJSON('a: 1\n');                 // => '{"a":1}'                (string)
zaml.parseToCBOR('a: 1\n');                 // => Uint8Array
await parse('a: 1\n');                      // convenience: lazily creates a shared instance
```

- Loader split by export condition so bundlers never pull `node:fs` into a browser build:
  ```json
  "exports": { ".": { "browser": "./dist/browser.js", "node": "./dist/node.js",
                       "default": "./dist/browser.js" } }
  ```
  `dist/node.js` reads the wasm with `node:fs/promises` (Node, Bun and Deno all support it);
  `dist/browser.js` uses `fetch` + `WebAssembly.instantiateStreaming` with a
  `WebAssembly.instantiate(await res.arrayBuffer())` fallback for servers that do not send
  `application/wasm`.
- Default wasm URL: `new URL('./zaml.wasm', import.meta.url)` (the build copies
  `build/zaml.wasm` → `packages/zamljs/dist/zaml.wasm`); overridable via
  `Zaml.create({ wasmUrl })` or `Zaml.create({ wasmBytes })`.
- CBOR decoder is hand-written in `src/cbor.ts` (no runtime dependencies). Major-type → JS mapping:
  uint/nint → Number if safe else BigInt; bignum tags 2/3 → BigInt; float64 → Number;
  text → `TextDecoder('utf-8')` (invalid bytes → U+FFFD); bytes → `Uint8Array`;
  map → plain `object` when every key is a text string, otherwise a `Map`; array → `Array`.
- `YamlParseError` carries `line`/`column` (1-based) parsed from the WASM error message.
- `package.json`: `"type": "module"`, `"engines": { "node": ">=18" }`, no `dependencies`,
  `devDependencies: { "typescript": "^5" }`, `files: ["dist", "README.md", "LICENSE"]`.

## Wasmer package `niranjanaryan/zaml`

- `packages/wasmer/wasmer.toml` with `[package] name/version/license/description` and a
  `[[command]] name = "zaml" module = "zaml.wasm"`. Validate the exact schema with
  `wasmer publish --dry-run` in CI (the manifest format changed across Wasmer 4/5).
- CLI: reads YAML on **stdin**, writes **JSON** on stdout by default; `--format cbor` writes raw
  CBOR. Parse errors go to stderr with exit code 1. `wasmer run niranjanaryan/zaml -- < file.yaml`.
- `packages/wasmer/README.md` documents usage and the stdin/stdout contract.

## Ordered task list

**Phase 0 — groundwork**
1. `core/scalar.zig`: classification + `classify(value, tag)`; unit tests (`zig test core/scalar.zig`).
2. Vendor libyaml 0.2.5 parse-only subset into `vendor/libyaml/` with `LICENSE` and a `README.md`
   recording the upstream URL and tarball SHA-256; add `wasm/config.h`.

**Phase 1 — WASM core (de-risk first)**
3. `core/parse.zig` (generic sink), `core/value.zig`, `core/cbor.zig`, `core/json.zig`,
   `core/base64.zig` + `zig test` unit tests (CBOR golden bytes, JSON golden text, float
   round-trip, int normalisation).
4. `wasm/main.zig` + `wasm/shim.c` + shim headers; **first milestone**: build `build/zaml.wasm`
   and run it in Node with a hand-written CBOR dump. Verify zero imports and that libyaml is
   actually linked in (not GC'd) — this is the known open risk from the scratch work.
5. `Makefile` targets `wasm`, `wasm-wasi`, `clean-wasm`; `wasm/wasi_main.zig` (WASI CLI) and the
   `wasm32-wasi-musl` build; run the CLI under `wasmer run` locally.

**Phase 2 — npm package**
6. `packages/zamljs` scaffolding: `package.json`, `tsconfig.json` (`module: nodenext`,
   `target: es2022`, `declaration: true`, `outDir: dist`), `src/types.ts`, `src/wasm.ts`,
   `src/cbor.ts`, `src/index.ts`.
7. `packages/zamljs/test/run.ts`: self-contained assertions (no framework) covering scalars,
   nesting, anchors/aliases, multi-doc, errors, big integers (Number vs BigInt), `!!binary`,
   int-keyed maps, empty document; run under `node`, `bun` and `deno`.
8. Build wiring: `Makefile` target `js-build` (tsc + copy wasm) and `js-test`.

**Phase 3 — Wasmer package**
9. `packages/wasmer/wasmer.toml` + README; local `wasmer run` smoke test against a fixture.

**Phase 4 — adopt the shared core in the native hosts**
10. Refactor `native/zaml_nif.zig` onto `core/parse.zig` + `core/scalar.zig`, keeping the
    zero-copy sub-binary optimisation and the `enif_make_map_from_arrays` fast path.
11. Refactor `zamlmodule.zig` the same way, keeping `PyLong_FromString` (arbitrary precision) and
    `PyDict_SetItem` semantics.
12. Regression gate: `mix test`, `python test.py`, and `benchmark/benchmark.py` before/after —
    the NIF must not regress against `benchmark/RESULTS.md`.

**Phase 5 — conformance, CI, release, docs**
13. `test/conformance/*.yml` + `expected.json`; runners for Elixir, Python, JS and the Wasmer CLI.
    One fixture set, four consumers.
14. CI: `build-wasm` (Zig 0.16.0, upload both artefacts), `test-js` (Node 22), `test-bun`,
    `test-deno`, `test-wasmer` (setup-wasmer), `test-conformance`; keep the existing Python/Windows/
    macOS jobs untouched.
15. `.github/workflows/release.yml`: on `release: published` → build wasm → `npm publish`
    (`NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }}`) → `wasmer publish`
    (`WASMER_REGISTRY_TOKEN: ${{ secrets.WASMER_REGISTRY_TOKEN }}`). Document the required
    secrets and the one-time npm/Wasmer account setup in `RELEASE_NOTES/`.
16. Docs: `README.md` (new "JavaScript / TypeScript" and "Wasmer" sections + a shared-core
    architecture note), `CHANGELOG.md` (0.2.0 entry), `packages/zamljs/README.md`,
    `packages/wasmer/README.md`.
17. Packaging: add `core/` to `mix.exs` `files`, `MANIFEST.in` (`include core/*.zig`,
    `include vendor/libyaml/...` not needed for hex), `setup.py` (add the core sources to the
    extension sources so the sdist/wheel build works), `.gitignore` (`packages/zamljs/dist/`,
    `packages/zamljs/node_modules/`, `build/wasm/`).

## Validation

| Check | Command |
|---|---|
| Zig unit tests | `zig test core/scalar.zig core/cbor.zig core/json.zig` |
| WASM builds | `make wasm wasm-wasi` |
| Zero imports / entry present | `wasm-objdump -x build/zaml.wasm` (or `wasm2wat`) |
| JS behaviour | `make js-test` → Node, Bun, Deno |
| Wasmer CLI | `wasmer run packages/wasmer/zaml.wasm -- --format json < test/conformance/basic.yml` |
| Elixir | `mix test` |
| Python | `python test.py` |
| Cross-host conformance | `make conformance` (all four hosts vs `expected.json`) |
| NIF perf | `python benchmark/benchmark.py` — compare with `benchmark/RESULTS.md` |

## Risks

1. **Freestanding link may leave libyaml GC'd or an unresolved libc symbol.** Mitigated by making
   "build + run `zaml.wasm` in Node" milestone 4, before any package work. The scratch build
   already linked with no imports; the real build must re-verify with a live entry point.
2. **`zig build-exe` + pre-built `.o` inputs** may not be supported in 0.16.0 → documented
   fallback (`zig build-obj` + `zig cc` link).
3. **NIF perf regression** from the core refactor → comptime-generic sink, benchmark gate in
   phase 4, and the refactor is isolated in its own commits so it can be reverted independently.
4. **Two libyaml copies** (system for native, vendored for WASM) can drift → both pinned to
   0.2.5, documented in `vendor/libyaml/README.md`; consolidation is a follow-up.
5. **Wasmer manifest schema** differs between Wasmer 4 and 5 → `wasmer publish --dry-run` in CI
   fails fast if the manifest is wrong.
6. **npm/Wasmer publish cannot be verified without real credentials** → the release workflow is
   written to publish on the first real release; the dry-run/packaging steps
   (`npm pack`, `wasmer publish --dry-run`) run in normal CI.

## Out of scope

- Switching the Elixir/Python builds to the vendored libyaml.
- A YAML **emitter** (this pass is parse-only, as today).
- Multi-document output in the JS API (the first document is returned, matching the native hosts).
- Publishing the npm package under a scoped name, or renaming `zamlpy`.

# Changelog

All notable changes to `zaml` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-10-09

### Python extension

- The in-repo Python extension is now a real, `pip install`-able CPython
  extension built with Zig 0.16 + libyaml, compatible with CPython
  3.10–3.14 (Python 3.12's packed `PyObject` refcount is handled
  adaptively). The Python package version tracks the Elixir release at
  `0.2.0`.
- The Python distribution is published on PyPI as **`zamlpy`** (the `zaml`
  project on PyPI is an unrelated third-party stub and cannot be reused):
  `pip install zamlpy` and `import zamlpy`.
- The Python distribution is published on PyPI as **`zamlpy`** (the `zaml`
  project on PyPI is an unrelated third-party stub and cannot be reused):
  `pip install zamlpy` and `import zamlpy`.
- `zamlpy.load(str_or_bytes)` returns native Python objects: maps, lists,
  strings, arbitrary-precision `int`, `float`, `bool`, and `None`, resolved
  with the YAML 1.2 core schema. Explicit `!!str` / `!!int` / `!!float` /
  `!!bool` / `!!null` tags are honored, and anchors/aliases resolve to the
  aliased object. Only the first document in a stream is returned;
  malformed input raises `ValueError`.
- Packaging modernized (PEP 517/621): `pyproject.toml` now carries
  `[build-system]` and full `[project]` metadata (single-sourced
  `version`, `requires-python`, classifiers, URLs, SPDX license) and
  `setup.py` is reduced to the Zig `Extension` + custom `build_ext`.

### Changed

- **Performance.** Maps are now built with a single
  [`enif_make_map_from_arrays`](https://www.erlang.org/doc/man/erl_nif.html)
  call per map instead of a per-pair `enif_make_map_put`, eliminating the
  O(n^2) rehashing on wide maps. String scalars are now returned as
  sub-binaries of the input (`enif_make_sub_binary`) rather than copied
  into freshly allocated binaries, so the parse no longer re-copies every
  string value. Together these take the 100k-key nested benchmark from
  ~0.65 s to ~0.53 s and shave the 1M-key flat benchmark to ~0.84 s,
  keeping the lead over `fast_yaml` at ~3.0–3.5×.

  The sub-binary path is guarded: we only sub-binary when the scalar
  pointer provably lies inside the input buffer, falling back to a copy
  otherwise, so the change stays correct across libyaml versions that may
  write quoted/block/folded scalars into their own buffer.

### Fixed

- **Anchors and aliases.** `&name` is now registered for scalars and for
  mapping/sequence starts, and `*name` resolves to the aliased term. Anchor
  names are copied into a parse-scoped arena because libyaml frees the event
  buffer after each event. Previously any document using an anchor returned
  `:parse_error`.

## [0.1.0] - 2026-09-05

### Added

- **Elixir NIF**: a Zig NIF wrapping [libyaml](https://pyyaml.org/wiki/LibYaml) for
  fast YAML 1.2 parsing in Elixir.
  - `Zaml.load/1` parses a YAML binary and returns the corresponding Elixir term
    (maps, lists, integers, floats, booleans, `:nil`).
  - YAML 1.2 *core* schema scalar resolution for ints, floats, bools, and null.
  - Respects explicit `!!str` / `!!int` / `!!float` / `!!bool` / `!!null` tags.
  - Anchors and aliases (`&name` / `*name`).
  - Returns `:error` for non-binary input, `:parse_error` for malformed YAML,
    and `:nil` for an empty document.
- NIF is compiled at `mix compile` via [`elixir_make`](https://hex.pm/packages/elixir_make)
  and the project `Makefile` (also invokable as Mix task `ZamlNif.Build`).
- `mix zaml_nif.bench PATH` Mix task for head-to-head benchmarking against
  `fast_yaml`.
- `Makefile` driving the `zig build-lib` invocation directly, with
  `pkg-config`/Homebrew/`/usr` libyaml auto-detection.
- `mix.exs` auto-detects `libyaml` on common paths and exports
  `CFLAGS`/`CPPFLAGS`/`LDFLAGS` so rebar3-compiled deps (e.g. `fast_yaml` in
  the bench task) find it.
- ExUnit test suite covering basic scalars, nested maps and lists, explicit
  tags, anchors, empty input, and parse-error handling.
- Cross-language benchmark suite (`benchmark/`) comparing the NIF against
  `fast_yaml`, PyYAML, and `ruamel.yaml`.
- `benchmark/RESULTS.md` with the measured numbers on a 1M-line flat mapping
  and a 100k-key nested mapping.

### Notes

- Merge keys (`<<: *alias`) are not yet expanded.
- Multi-document input returns only the first document.

[0.2.0]: https://github.com/niranjanaryan/zaml-elixir/releases/tag/v0.2.0
[0.1.0]: https://github.com/niranjanaryan/zaml-elixir/releases/tag/v0.1.0

# zaml 0.3.0 — multi-ecosystem release plan

The Elixir/Hex package is published. The remaining work is publishing the
npm and Wasmer packages (both blocked on registry-side trusted publishing
configuration) and refreshing the docs of the two packages that ship with
the release.

## Status

| Item | State |
| --- | --- |
| Elixir `zaml` on Hex | published (0.3.0) |
| Python `zamlpy` on PyPI | published (0.3.1, 9 files) |
| Wasmer `niranjanaryan/zaml` | published (0.3.0) |
| GitHub `v0.3.0` release | published |
| npm `zamljs` | not published — needs trusted publishing enabled on npmjs.com |
| Hex `zaml` 0.3.0 via CI | not published — needs a workload identity on hex.pm |

## Python 0.3.1

The published 0.3.0 carried the Elixir-centric `README.md` as its PyPI
description, and PyPI does not replace the description of an existing
version. The fix was a dedicated `PYPI.md` published as 0.3.1, which
carries install, usage, examples, the scalar table, big integers,
cross-platform notes, the benchmark table and the project links.

The CI workflow now accepts a `version` input, so the wheels and the
sdist can be built for a version that has no tag. The 0.3.1 artifacts
were built with `gh workflow run ci.yml --ref main -f version=0.3.1`
and uploaded with `twine`.

## npm — trusted publishing

The `NPM_TOKEN` secret is empty and the local token in `~/.npmrc` is
expired (401). The `release.yml` `npm` job already uses trusted publishing
(OIDC), so no token is needed. A maintainer enables it on the `zamljs`
package page at npmjs.com for `niranjanaryan/zaml`, the `release.yml`
workflow and the `release` environment. After that, dispatch
`release.yml` again.

## Hex — workload identity

The `HEX_API_KEY` secret is present but the account has 2FA enabled, so the
key alone cannot publish. The `release.yml` `hex` job already exchanges an
OIDC token for a Hex workload identity token. A package owner with 2FA
enabled adds a workload identity on the hex.pm `zaml` package page for
`niranjanaryan/zaml`, the `release.yml` workflow and the `release`
environment. After that, dispatch `release.yml` again.

## Docs to refresh

- `packages/zamljs/README.md` — add usage examples, benchmarks, and a
  "when to use" section.
- `packages/wasmer/README.md` — add usage examples, error handling, and
  performance notes.

## Verification

```bash
cd packages/zamljs && npm run build && npm test
wasmer run niranjanaryan/zaml < good.yml
wasmer run niranjanaryan/zaml < bad.yml; echo "exit: $?"
```
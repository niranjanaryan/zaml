# The JavaScript benchmark

It compares the npm package with the parsers of the JavaScript
ecosystem on the same fixture.

## Running it

The fixture is the one the other benchmarks use:

```bash
python3 benchmark/gen_big_yaml.py 100000 benchmark/big.yml
```

The parser under test is the one the package ships, so build it first:

```bash
zig build wasm -Doptimize=ReleaseSmall
(cd packages/zamljs && npm install && npm run build)
```

Then run the benchmark:

```bash
cd benchmark/js
npm install
npm run bench
```

The script takes the fixture, the number of runs and the parsers to
run, so a single parser can be measured on its own:

```bash
node bench.mjs ../../benchmark/big.yml 3 zamljs
```

## What it measures

Every parser reads the same YAML text and builds the same value, so
the times are comparable. The `yaml` package is slow enough on the
100k-key fixture that a run of it takes minutes.

The numbers of the last run are in [RESULTS.md](RESULTS.md).

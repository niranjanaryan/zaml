"""Benchmark zaml (Zig + libyaml) against PyYAML / ruamel, Codon-compatible.

Codon requires third-party modules to be imported via `from python import`.
Usage:
    export CODON_PYTHON=/path/to/libpython3.14.dylib
    export PYTHON_PATH=/path/to/site-packages
    codon run benchmark/benchmark_codon.py [n_runs] [fixture]
"""
import os
import time
from pathlib import Path

REPO = Path(
    os.environ.get("ZAML_REPO", "/Users/niranjan/quant-research/elixcoder/zaml-elixir")
)
BIG = REPO / "benchmark" / "big.yml"


def time_it(label, fn, n_runs=3):
    times = []
    result = None
    for _ in range(n_runs):
        t0 = time.perf_counter()
        result = fn()
        times.append((time.perf_counter() - t0) * 1000.0)
    avg = sum(times) / n_runs
    print(
        f"  {label:<38s} avg {avg:8.2f} ms  (min {min(times):.2f}, max {max(times):.2f})"
    )
    return avg, result


def main():
    n_runs = int(os.environ.get("ZAML_RUNS", "3"))
    fixture = Path(os.environ.get("ZAML_FIXTURE", str(BIG)))
    contents = fixture.read_bytes()
    print(f"\nBenchmarking on {len(contents):,} byte YAML file ({fixture.name})\n")

    # Codon's `from python import` uses the interpreter's sys.path, which does
    # not include the repo root. Append it explicitly before importing zaml.
    from python import sys
    from python import builtins

    sys.path.append(str(REPO))

    from python import yaml as pyyaml
    from python import zaml

    pyyaml_c_avg, pyyaml_c_results = time_it(
        "PyYAML CSafeLoader", lambda: pyyaml.load(contents, Loader=pyyaml.CSafeLoader)
    )
    pyyaml_avg, pyyaml_results = time_it(
        "PyYAML SafeLoader", lambda: pyyaml.load(contents, Loader=pyyaml.SafeLoader)
    )

    ruamel_avg = None
    try:
        from python import ruamel

        yaml = ruamel.yaml.YAML(typ="safe", pure=True)
        ruamel_avg, _ = time_it(
            "ruamel.yaml (safe, pure Python)", lambda: yaml.load(contents)
        )
    except builtins.Exception:
        print("  (ruamel.yaml not installed; skipping)")

    zaml_avg, zaml_results = time_it(
        "zaml (Zig + libyaml)", lambda: zaml.load(contents)
    )

    print()
    print("Summary (avg ms over %d runs):" % n_runs)
    print(f"  PyYAML CSafeLoader        {pyyaml_c_avg:8.2f}")
    print(f"  PyYAML SafeLoader         {pyyaml_avg:8.2f}")
    if ruamel_avg is not None:
        print(f"  ruamel.yaml (safe)        {ruamel_avg:8.2f}")
    print(f"  zaml (Zig + libyaml)      {zaml_avg:8.2f}")
    print()
    print(f"  zaml vs PyYAML C:  {pyyaml_c_avg / zaml_avg:5.2f}x")
    print(f"  zaml vs PyYAML Py: {pyyaml_avg / zaml_avg:5.2f}x")
    if ruamel_avg:
        print(f"  zaml vs ruamel:    {ruamel_avg / zaml_avg:5.2f}x")

    print()
    print("Correctness check:")
    expected_size = len(pyyaml_c_results)
    expected_first_key = min(pyyaml_c_results)
    expected_first_val = pyyaml_c_results[expected_first_key]
    print(
        f"  PyYAML : size={expected_size}, first_key={expected_first_key!r}, first_value={expected_first_val!r}"
    )
    print(
        f"  zaml   : size={len(zaml_results)}, first_key={min(zaml_results)!r}, first_value={zaml_results[min(zaml_results)]!r}"
    )

    if (
        len(zaml_results) == expected_size
        and min(zaml_results) == expected_first_key
        and zaml_results[expected_first_key] == expected_first_val
    ):
        print("  ✓ size, first key, and first value match")
    else:
        print("  ✗ MISMATCH")
        raise SystemExit(1)


if __name__ == "__main__":
    main()

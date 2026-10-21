"""Benchmark zaml (Zig + libyaml) against PyYAML / ruamel.

Usage:
    python3 benchmark/benchmark.py [n_runs] [fixture]
    codon run benchmark/benchmark.py 3 benchmark/big.yml
"""
import os
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIG = REPO / "benchmark" / "big.yml"

# The compiled extension lives in the repo root; make sure it is importable
# regardless of the current working directory. Codon's sys module does not
# expose `path`, so we rely on PYTHONPATH instead.
_repo = os.environ.get("ZAML_REPO")
if _repo:
    REPO = Path(_repo)
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
    n_runs = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    fixture = Path(sys.argv[2]) if len(sys.argv) > 2 else BIG
    contents = fixture.read_bytes()
    print(f"\nBenchmarking on {len(contents):,} byte YAML file ({fixture.name})\n")

    import yaml as pyyaml
    import zamlpy

    pyyaml_c_avg, pyyaml_c_results = time_it(
        "PyYAML CSafeLoader", lambda: pyyaml.load(contents, Loader=pyyaml.CSafeLoader)
    )
    pyyaml_avg, pyyaml_results = time_it(
        "PyYAML SafeLoader", lambda: pyyaml.load(contents, Loader=pyyaml.SafeLoader)
    )

    ruamel_avg = None
    try:
        from ruamel.yaml import YAML

        yaml = YAML(typ="safe", pure=True)
        ruamel_avg, _ = time_it(
            "ruamel.yaml (safe, pure Python)", lambda: yaml.load(contents)
        )
    except ImportError:
        print("  (ruamel.yaml not installed; skipping)")

    zaml_avg, zaml_results = time_it(
        "zamlpy (Zig + libyaml)", lambda: zamlpy.load(contents)
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

    # Correctness: compare map size + first key.
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
        sys.exit(1)


if __name__ == "__main__":
    main()

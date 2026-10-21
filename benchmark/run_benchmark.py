#!/usr/bin/env python3
"""Compares Elixir Zaml (Zig NIF + libyaml) against PyYAML and ruamel.yaml.

Requires the Elixir NIF to have been compiled (run `mix compile` once).
PyYAML and ruamel.yaml are pip-installable.
"""
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BIG = REPO / "benchmark" / "big.yml"


def ensure_yaml() -> bytes:
    if not BIG.exists():
        print(f"Generating {BIG} ...")
        subprocess.check_call(
            [sys.executable, str(REPO / "benchmark" / "gen_big_yaml.py")]
        )
    return BIG.read_bytes()


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


def run_elixir(contents: bytes):
    script = REPO / "benchmark" / "benchmark.exs"
    proc = subprocess.run(
        ["mix", "run", "--no-start", str(script), str(BIG)],
        cwd=str(REPO),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        print(proc.stdout)
        print(proc.stderr, file=sys.stderr)
        raise SystemExit("Elixir benchmark failed")

    # Forward the user-facing line(s) but skip our RESULT_ marker lines.
    out_lines = []
    summary = {}
    for line in proc.stdout.splitlines():
        if line.startswith("RESULT_"):
            key, _, val = line.partition("=")
            summary[key] = val
        else:
            out_lines.append(line)
    print("\n".join(out_lines))

    m = re.search(r"avg ([0-9.]+) ms", proc.stdout)
    avg = float(m.group(1)) if m else None
    return avg, summary


def main():
    contents = ensure_yaml()
    print(f"\nBenchmarking on {len(contents):,} byte YAML file\n")

    try:
        import yaml as pyyaml
    except ImportError:
        print("pip install pyyaml ruamel.yaml")
        sys.exit(1)

    print("Python:")
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

    print("\nElixir:")
    elixir_avg, elixir_summary = run_elixir(contents)
    print()

    print("Summary (avg ms over 3 runs):")
    print(f"  PyYAML CSafeLoader        {pyyaml_c_avg:8.2f}")
    print(f"  PyYAML SafeLoader         {pyyaml_avg:8.2f}")
    if ruamel_avg is not None:
        print(f"  ruamel.yaml (safe)        {ruamel_avg:8.2f}")
    print(f"  Elixir Zaml (NIF)         {elixir_avg:8.2f}")
    if elixir_avg and pyyaml_c_avg:
        print()
        print(f"  Elixir vs PyYAML C:  {pyyaml_c_avg / elixir_avg:5.2f}x")
        print(f"  Elixir vs PyYAML Py: {pyyaml_avg / elixir_avg:5.2f}x")
        if ruamel_avg:
            print(f"  Elixir vs ruamel:    {ruamel_avg / elixir_avg:5.2f}x")

    # Correctness: compare map size + first key.
    print()
    print("Correctness check:")
    expected_size = len(pyyaml_c_results)
    expected_first_key = min(pyyaml_c_results)
    expected_first_val = pyyaml_c_results[expected_first_key]
    print(
        f"  PyYAML  : size={expected_size}, first_key={expected_first_key!r}, first_value={expected_first_val!r}"
    )
    print(
        f"  Elixir  : size={elixir_summary.get('RESULT_SIZE')}, first_key={elixir_summary.get('RESULT_FIRST_KEY')!r}, first_value={elixir_summary.get('RESULT_FIRST_VALUE')!r}"
    )

    if (
        elixir_summary.get("RESULT_SIZE") == str(expected_size)
        and elixir_summary.get("RESULT_FIRST_KEY") == expected_first_key
    ):
        print("  ✓ size and first key match")
    else:
        print("  ✗ MISMATCH")
        sys.exit(1)


if __name__ == "__main__":
    main()

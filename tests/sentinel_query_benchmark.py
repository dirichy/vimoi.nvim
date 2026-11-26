"""Compare sentinel queries with an archived baseline in independent processes."""

from pathlib import Path
import argparse
import io
import json
import os
import platform
import statistics
import subprocess
import tarfile
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline", default="5237e8152c37834daff49d2a4f653b217abd615f")
parser.add_argument("--baseline-dir", type=Path, help="compare an existing source checkout instead of a commit")
parser.add_argument("--output-prefix", default="sentinel-query")
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--nvim", default="nvim")
args = parser.parse_args()
if args.runs < 1:
    parser.error("--runs must be positive")
if args.baseline_dir and not args.baseline_dir.is_dir():
    parser.error("--baseline-dir must be an existing checkout")
workspace = Path(__file__).resolve().parent.parent
script = workspace / "tests/sentinel_query_benchmark.lua"
baseline_commit = str(args.baseline_dir.resolve()) if args.baseline_dir else subprocess.check_output(
    ["git", "rev-parse", args.baseline], cwd=workspace, text=True
).strip()
environment = {"platform": platform.platform(), "chezmoi": subprocess.check_output(["chezmoi", "--version"], text=True).strip()}
records = {"baseline": [], "sentinel": []}
with tempfile.TemporaryDirectory(prefix="vimoi-sentinel-benchmark-") as directory:
    root = Path(directory)
    baseline = args.baseline_dir.resolve() if args.baseline_dir else root / "baseline"
    if not args.baseline_dir:
        baseline.mkdir()
        archive = subprocess.check_output(["git", "archive", baseline_commit], cwd=workspace)
        with tarfile.open(fileobj=io.BytesIO(archive)) as content:
            content.extractall(baseline, filter="data")
    for trial in range(1, args.runs + 1):
        for variant, cwd in [("baseline", baseline), ("sentinel", workspace)]:
            output = root / f"{variant}-{trial}.json"
            env = dict(os.environ, NVIM_LOG_FILE=str(root / f"{variant}-{trial}.log"),
                       VIMOI_BENCH_VARIANT=variant, VIMOI_BENCH_RESULT=str(output))
            result = subprocess.run(
                [args.nvim, "--headless", "-n", "-i", "NONE", "-u", "tests/minimal_init.lua", "-l", str(script)],
                cwd=cwd, env=env, capture_output=True, text=True,
            )
            if result.returncode:
                raise SystemExit(result.stdout + result.stderr)
            records[variant].append(json.loads(output.read_text()))
            print(f"{variant} run {trial}/{args.runs} complete", flush=True)

# Validate equivalence before publishing any benchmark record.
for name in records["baseline"][0]["cases"]:
    for key in ["source_checksum", "output_checksum"]:
        values = {run["cases"][name][key] for group in records.values() for run in group}
        assert len(values) == 1, (name, key, values)

aggregates = {}
destination = workspace / "docs/benchmarks"
destination.mkdir(exist_ok=True)
for variant, filename in [("baseline", args.output_prefix + "-before.json"), ("sentinel", args.output_prefix + "-after.json")]:
    cases = {}
    for name in records[variant][0]["cases"]:
        runs = [item["cases"][name] for item in records[variant]]
        cases[name] = {key: statistics.median(row[key] for row in runs) for key in runs[0]}
    aggregates[variant] = cases
    document = dict(baseline_commit=None if args.baseline_dir else baseline_commit,
                    baseline_directory=baseline_commit if args.baseline_dir else None, variant=variant,
                    process_runs=args.runs, queries_per_sample=512, environment=environment, cases=cases, runs=records[variant])
    (destination / filename).write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")

for name, before in aggregates["baseline"].items():
    after = aggregates["sentinel"][name]
    print(name)
    for key in ["source_query_cpu_ms", "output_query_cpu_ms", "build_cpu_ms", "render_wall_ms", "map_kib"]:
        first, last = before[key], after[key]
        print(f"  {key}: {first:.4f} -> {last:.4f} ({first / last:.2f}x)")

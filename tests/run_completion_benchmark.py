"""Compare cached-data completion CPU in independent, alternating Neovim processes."""
import argparse
import io
import json
import os
from pathlib import Path
import statistics
import subprocess
import tarfile
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', default='c3729e4')
parser.add_argument('--runs', type=int, default=3)
args = parser.parse_args()
if args.runs < 1:
    parser.error('--runs must be positive')
workspace = Path(__file__).resolve().parent.parent
script = workspace / 'tests/completion_benchmark.lua'
commit = subprocess.check_output(['git', 'rev-parse', args.baseline], cwd=workspace, text=True).strip()
records = {'before': [], 'after': []}
with tempfile.TemporaryDirectory(prefix='vimoi-completion-') as temporary:
    root = Path(temporary)
    baseline = root / 'baseline'
    baseline.mkdir()
    archive = subprocess.check_output(['git', 'archive', commit], cwd=workspace)
    with tarfile.open(fileobj=io.BytesIO(archive)) as content:
        content.extractall(baseline, filter='data')
    for trial in range(args.runs):
        variants = [('before', baseline), ('after', workspace)]
        if trial % 2:
            variants.reverse()
        for variant, cwd in variants:
            output = root / f'{variant}-{trial}.json'
            env = dict(os.environ, NVIM_LOG_FILE=str(root / 'nvim.log'), VIMOI_COMPLETION_RESULT=str(output))
            process = subprocess.run(['nvim', '--headless', '-n', '-i', 'NONE', '-u', 'tests/minimal_init.lua', '-l', str(script)],
                                     cwd=cwd, env=env, capture_output=True, text=True)
            if process.returncode:
                raise SystemExit(process.stdout + process.stderr)
            records[variant].append(json.loads(output.read_text()))
            print(f'{variant} {trial+1}/{args.runs} complete', flush=True)
for case in records['before'][0]['cases']:
    assert len({run['cases'][case]['checksum'] for group in records.values() for run in group}) == 1
for variant, runs in records.items():
    cases = {case: {key: statistics.median(run['cases'][case][key] for run in runs)
                    for key in runs[0]['cases'][case]} for case in runs[0]['cases']}
    destination = workspace / 'docs/benchmarks' / f'completion-{variant}.json'
    destination.write_text(json.dumps(dict(baseline_commit=commit, process_runs=args.runs, cases=cases, runs=runs), indent=2) + '\n')
    print(variant, json.dumps(cases), flush=True)

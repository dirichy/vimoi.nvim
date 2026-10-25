"""Compare serial and parallel construction in isolated headless Neovim runs."""

import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline-ref', required=True, help='commit containing serial session.lua')
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
workspace = Path(__file__).resolve().parent.parent
cases = {
    'small': 'value={{ "hello" }}\n',
    'large': ''.join('key%d={{ "hello" }}\n' % i for i in range(1000)),
    'helper100ms': 'value={{ output "sh" "-c" "sleep 0.1; printf hello" }}\n',
}
results = {name: {'serial': [], 'parallel': []} for name in cases}
with tempfile.TemporaryDirectory(prefix='vimoi-cat-bench-') as temp:
    root = Path(temp)
    baseline = root / 'serial.lua'
    # Historical serial commits predate the module/config rename; adapt names only.
    serial = subprocess.check_output(
        ['git', 'show', args.baseline_ref + ':lua/vimoi/gotmpl/session.lua'],
        cwd=workspace, text=True)
    serial = (serial.replace('vimoi.gotmpl.buffer_edits', 'vimoi.core.buffer_edits')
              .replace('vimoi.gotmpl.source_map', 'vimoi.render.source_map')
              .replace('vimoi.gotmpl.view', 'vimoi.compare')
              .replace('vimoi.util', 'vimoi.core.util')
              .replace('vimoi.cli', 'vimoi.core.cli')
              .replace('vimoi.filetype', 'vimoi.core.source')
              .replace('vimoi.diagnostic', 'vimoi.editor.diagnostic')
              .replace('vimoi.host_highlight', 'vimoi.editor.host_highlight')
              .replace('config.diff.validate', 'config.render.validate'))
    baseline.write_text(serial)
    for name, text in cases.items():
        case = root / name
        (case / 'source').mkdir(parents=True)
        (case / 'target').mkdir()
        (case / 'source/dot_benchmark.tmpl').write_text(text)
        (case / 'config.toml').write_text(
            'sourceDir = ' + json.dumps(str(case / 'source')) + '\n'
            'destDir = ' + json.dumps(str(case / 'target')) + '\n')
    for repetition in range(3):
        for name, variants in results.items():
            order = ['serial', 'parallel'] if repetition % 2 == 0 else ['parallel', 'serial']
            for variant in order:
                case = root / name
                output = case / 'result.json'
                env = dict(os.environ)
                env.update({
                    'XDG_STATE_HOME': str(root / 'state'), 'NVIM_LOG_FILE': str(root / 'nvim.log'),
                    'VIMOI_BENCH_CONFIG': str(case / 'config.toml'), 'VIMOI_BENCH_RESULT': str(output),
                    'VIMOI_BENCH_SESSION': str(baseline) if variant == 'serial' else '',
                })
                command = [
                    'nvim', '--headless', '-n', '-i', 'NONE', '-u', 'NONE', '-c',
                    "lua local ok, err = pcall(dofile, 'tests/session_validation_benchmark.lua'); "
                    "if not ok then print(err); vim.cmd('cquit') end", '-c', 'qa!',
                ]
                run = subprocess.run(command, cwd=workspace, env=env, capture_output=True,
                                     text=True, timeout=120)
                if run.returncode:
                    raise RuntimeError(run.stdout + run.stderr)
                variants[variant].extend(json.loads(output.read_text()))
            print(f'PASS round {repetition + 1}: {name}', flush=True)
summary = {}
for name, variants in results.items():
    values = {variant: {'median_ms': statistics.median(samples), 'samples_ms': samples}
              for variant, samples in variants.items()}
    serial, parallel = values['serial']['median_ms'], values['parallel']['median_ms']
    values.update(saved_ms=serial - parallel, saved_percent=(serial - parallel) / serial * 100)
    summary[name] = values
report = {
    'baseline': args.baseline_ref, 'samples_per_variant': 45, 'warmup_per_process': 3,
    'rounds': 3, 'platform': platform.platform(),
    'nvim': subprocess.check_output(['nvim', '--version'], text=True).splitlines()[0],
    'chezmoi': subprocess.check_output(['chezmoi', '--version'], text=True).strip(),
    'cases': summary,
}
args.output.write_text(json.dumps(report, indent=2) + '\n')
for name, values in summary.items():
    print(f"{name}: {values['serial']['median_ms']:.2f} -> "
          f"{values['parallel']['median_ms']:.2f} ms ({values['saved_percent']:.1f}% faster)")

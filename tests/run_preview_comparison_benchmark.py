"""Compare real preview updates in isolated, sequential headless Neovim runs."""

import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--checkout", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--repeats", type=int, default=3)
parser.add_argument("--match-debounce", action="store_true", help="set upstream debounce to vimoi's 120ms")
args = parser.parse_args()
checkout = args.checkout.resolve()
workspace = Path(__file__).resolve().parent.parent
chezmoi = shutil.which("chezmoi")
assert chezmoi, "chezmoi is required"
results = []

for size, helper in [(200, False), (2000, False), (10000, False), (2000, True)]:
    for repetition in range(args.repeats):
        # Alternate order to reduce systematic warm-cache/CPU-order bias.
        plugins = ["vimoi", "chezmoi-template"]
        if repetition % 2:
            plugins.reverse()
        for plugin in plugins:
            with tempfile.TemporaryDirectory(prefix="vimoi-preview-bench-") as temp:
                root = Path(temp)
                (root / "source").mkdir()
                (root / "bin").mkdir()
                (root / "config.toml").write_text("")
                lines = [
                    "bench_static: static_0",
                    'bench_dynamic: {{ printf "dynamic_0" }}',
                    '{{ output "/usr/bin/sleep" "0.2" }}' if helper else "# no helper",
                ]
                for block in range(size // 20):
                    lines.append("{{ if true }}")
                    lines.extend(f"key_{block}_{row}: value_{block}_{row}" for row in range(18))
                    lines.append("{{ end }}")
                template = "\n".join(lines) + "\n"
                (root / "source/dot_benchmark.yaml.tmpl").write_text(template)
                wrapper = root / "bin/chezmoi"
                command = [
                    chezmoi, "--config", str(root / "config.toml"),
                    "--source", str(root / "source"), "--destination", str(root / "target"),
                ]
                wrapper.write_text("#!/bin/sh\nexec " + shlex.join(command) + ' "$@"\n')
                wrapper.chmod(0o755)
                # Establish the authoritative full-render output outside measurement.
                expected = subprocess.check_output(
                    [str(wrapper), "execute-template"], input=template.encode(), timeout=30
                )
                (root / "expected").write_bytes(expected)
                env = dict(os.environ)
                env.update({
                    "PATH": str(root / "bin") + os.pathsep + env["PATH"],
                    "XDG_STATE_HOME": str(root / "state"),
                    "VIMOI_BENCH_PLUGIN": plugin,
                    "VIMOI_BENCH_ROOT": str(root),
                    "VIMOI_BENCH_CHECKOUT": str(checkout),
                    "VIMOI_BENCH_RESULT": str(root / "result.json"),
                    "VIMOI_BENCH_MATCH_DEBOUNCE": "1" if args.match_debounce else "0",
                })
                run = subprocess.run(
                    ["nvim", "--headless", "-n", "-i", "NONE", "-u", "tests/minimal_init.lua",
                     "-c", "lua local ok, err = pcall(dofile, 'tests/preview_comparison_benchmark.lua'); "
                     "if not ok then print(err); vim.cmd('cquit') end", "-c", "qa!"],
                    cwd=workspace, env=env, capture_output=True, text=True, timeout=120,
                )
                if run.returncode:
                    raise RuntimeError(f"{plugin}, {size}, helper={helper}: {run.stdout}{run.stderr}")
                result = json.loads((root / "result.json").read_text())
                result.update({"lines": len(lines), "bytes": len(template.encode()),
                               "helper_ms": 200 if helper else 0, "repetition": repetition})
                results.append(result)
                print(f"PASS {plugin}: {len(lines)} lines, helper={helper}, run={repetition + 1}", flush=True)

output = {
    "date": "2026-10-22",
    "match_debounce": args.match_debounce,
    "platform": platform.platform(),
    "nvim": subprocess.check_output(["nvim", "--version"], text=True).splitlines()[0],
    "chezmoi": subprocess.check_output([chezmoi, "--version"], text=True).strip(),
    "upstream_commit": subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip(),
    "results": results,
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")
print(f"Saved {len(results)} runs to {args.output}")

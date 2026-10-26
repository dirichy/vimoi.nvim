"""Run isolated Lua tests, then build verified demo recordings and local READMEs."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile


def run_test(test):
    with tempfile.TemporaryDirectory(prefix="vimoi-test-") as directory:
        root = Path(directory)
        destination = root / "target"
        destination.mkdir()
        (root / "bin").mkdir()
        command = [
            chezmoi, "--config", str(fixture / "empty.toml"),
            "--source", str(fixture / "source"), "--destination", str(destination),
            "--persistent-state", str(root / "state.boltdb"),
        ]
        wrapper = root / "bin/chezmoi"
        # An explicit config must keep its own sourceDir/destDir. Only calls
        # without --config receive our default fixture identity.
        wrapper.write_text(
            "#!/bin/sh\nfor argument do\n"
            '  case "$argument" in\n'
            "    --config|--config=*|-c) exec "
            + shlex.join([chezmoi, "--persistent-state", str(root / "state.boltdb")])
            + ' "$@" ;;\n'
            "  esac\ndone\nexec " + shlex.join(command) + ' "$@"\n'
        )
        wrapper.chmod(0o755)
        # Render only the three baselines consumed by integration tests. No apply.
        for name in [".diff_target", ".complex_diff", ".plain"]:
            output = subprocess.check_output(command + ["cat", str(destination / name)], timeout=30)
            (destination / name).write_bytes(output)
        env = dict(os.environ)
        env.update({
            "PATH": str(root / "bin") + os.pathsep + env["PATH"],
            "XDG_STATE_HOME": str(root / "nvim-state"),
            "NVIM_LOG_FILE": str(root / "nvim.log"),
            "VIMOI_TEST_DESTINATION": str(destination),
        })
        # Pass the test path through the environment, without interpolating Lua code.
        env["VIMOI_TEST_SCRIPT"] = str(test)
        try:
            result = subprocess.run(
                [nvim, "--headless", "-n", "-i", "NONE", "-u", "tests/minimal_init.lua",
                 "-c", "lua local ok, err = xpcall(function() dofile(vim.env.VIMOI_TEST_SCRIPT) end, "
                 "debug.traceback); if not ok then print(err); vim.cmd('cquit') end", "-c", "qa!"],
                cwd=workspace, env=env, capture_output=True, text=True, timeout=120,
            )
            return test, result.returncode == 0, result.stdout + result.stderr
        except subprocess.TimeoutExpired as error:
            return test, False, "test exceeded 120s: " + str(error)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("tests", nargs="*", help="optional Lua test basenames")
parser.add_argument("--jobs", type=int, default=4)
parser.add_argument("--skip-demos", action="store_true", help="run Lua tests without building the demo recordings")
args = parser.parse_args()
if args.jobs < 1:
    parser.error("--jobs must be positive")
workspace = Path(__file__).resolve().parent.parent
fixture = workspace / "tests/fixtures/environment"
chezmoi, nvim = shutil.which("chezmoi"), shutil.which("nvim")
if not chezmoi or not nvim:
    parser.error("chezmoi and Neovim 0.12+ must be on PATH")
tests = [workspace / "tests" / name for name in args.tests] if args.tests else sorted(
    path for path in (workspace / "tests").glob("*.lua")
    if "benchmark" not in path.name and path.name != "minimal_init.lua"
)
if any(not test.is_file() for test in tests):
    parser.error("a requested test file does not exist")
if not args.tests:
    with tempfile.TemporaryDirectory(prefix="vimoi-test-preflight-") as directory:
        env = dict(os.environ, XDG_STATE_HOME=directory, NVIM_LOG_FILE=str(Path(directory) / "nvim.log"))
        subprocess.run(
            [nvim, "--headless", "-n", "-i", "NONE", "-u", "tests/minimal_init.lua",
             "-l", "tests/helpers/check_parsers.lua"],
            cwd=workspace, env=env, check=True,
        )
failures = 0
with ThreadPoolExecutor(max_workers=args.jobs) as pool:
    for test, passed, output in pool.map(run_test, tests):
        print(f"{'PASS' if passed else 'FAIL'} {test.name}", flush=True)
        if not passed:
            failures += 1
            print(output, flush=True)
print(f"{len(tests) - failures}/{len(tests)} tests passed", flush=True)
if not failures and not args.tests and not args.skip_demos:
    print("Building all demo recordings and local READMEs ...", flush=True)
    subprocess.run([sys.executable, "docs/demos/build.py"], cwd=workspace, check=True)
raise SystemExit(1 if failures else 0)

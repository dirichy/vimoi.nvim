#!/usr/bin/env python3
"""Build verified GIF/MP4 demos, a gallery, and local README previews."""
import argparse
import html
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demos", nargs="*", help="tape basenames; default: all")
mode = parser.add_mutually_exclusive_group()
mode.add_argument("--check", action="store_true", help="check dependencies and isolated startup without recording")
mode.add_argument("--readme-only", action="store_true", help="reuse existing media and only rebuild the gallery and READMEs")
args = parser.parse_args()
tapes = {path.stem: path for path in sorted((root / "docs/demos").glob("*.tape"))}
if args.readme_only and args.demos:
    parser.error("--readme-only does not accept scene names")
selected = [] if args.readme_only else args.demos or list(tapes)
unknown = set(selected) - tapes.keys()
if unknown:
    parser.error("unknown demos: " + ", ".join(sorted(unknown)))
if not args.readme_only:
    for tool in ["vhs", "ttyd", "ffmpeg", "ffprobe", "nvim", "chezmoi", "fc-match"]:
        if not shutil.which(tool):
            parser.error(f"install missing recording tool: {tool}")
    if not any(shutil.which(browser) for browser in ["chromium", "chromium-browser", "google-chrome", "google-chrome-stable"]):
        parser.error("install Chromium or Google Chrome for VHS")
    if "diagnostics" in selected and not shutil.which("luac"):
        parser.error("install luac for real host diagnostics")
    family = subprocess.check_output(["fc-match", "-f", "%{family}", "JetBrainsMono Nerd Font Mono"], text=True)
    if family.split(",")[0] != "JetBrainsMono Nerd Font Mono":
        parser.error(f"install JetBrainsMono Nerd Font Mono; fontconfig currently selects {family}")
    for pattern in ["docs/demos/*.tape", "docs/demos/common/*.tape"]:
        subprocess.run(["vhs", "validate", pattern], cwd=root, check=True)
output = root / "docs/demos/output"
output.mkdir(exist_ok=True)
for name in selected:
    result = output / f"{name}.json"
    if not args.check:
        result.unlink(missing_ok=True)
    env = dict(os.environ, VIMOI_DEMO=name, VIMOI_DEMO_RESULT=str(result))
    print(f"{'Checking' if args.check else 'Recording'} {name} ...", flush=True)
    with tempfile.TemporaryDirectory(prefix="vimoi-record-") as state:
        # Preserve installed parsers/plugins in XDG_DATA_HOME, isolate writable editor state.
        for kind in ["CONFIG", "STATE", "CACHE"]:
            env[f"XDG_{kind}_HOME"] = str(Path(state) / kind.lower())
        env["NVIM_LOG_FILE"] = str(Path(state) / "nvim.log")
        # Fail before opening Chromium if the isolated editor setup has an error.
        startup_check = (
            "lua vim.defer_fn(function() "
            "if vim.v.errmsg ~= '' then print(vim.v.errmsg); vim.cmd('cquit') end; "
            "vim.cmd('qa!') end, 1000)"
        )
        subprocess.run(
            ["nvim", "--headless", "-n", "-i", "NONE", "-u", "docs/demos/init.lua", "-c", startup_check],
            cwd=root, env=env, check=True,
        )
        if args.check:
            print(f"Checked {name}: dependencies and isolated startup", flush=True)
            continue
        subprocess.run(["vhs", "--quiet", str(tapes[name].relative_to(root))], cwd=root, env=env, check=True)
    evidence = json.loads(result.read_text()) if result.exists() else {}
    if not evidence.get("verified"):
        raise SystemExit(
            f"{name}: playback verification failed: {evidence.get('error', 'verification did not run')}; "
            f"inspect the video and /tmp/vimoi-demo-{name}.log"
        )
    for extension in ["png", "mp4"]:
        media = output / f"{name}.{extension}"
        if not media.is_file() or media.stat().st_size == 0:
            raise SystemExit(f"{name}: missing {extension} output")
    # A separate palette pass keeps memory bounded and prioritizes changing code over the static backdrop.
    with tempfile.TemporaryDirectory(prefix="vimoi-palette-") as palette_dir:
        palette = Path(palette_dir) / "palette.png"
        gif_filter = "fps=20,scale=1920:-1:flags=lanczos"
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(output / f"{name}.mp4"),
            "-vf", gif_filter + ",palettegen=stats_mode=diff", "-frames:v", "1", str(palette),
        ], check=True)
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(output / f"{name}.mp4"),
            "-i", str(palette), "-filter_complex",
            gif_filter + "[video];[video][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
            "-loop", "0", str(output / f"{name}.gif"),
        ], check=True)
    video = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=codec_name,width,height,r_frame_rate", "-of", "json", str(output / f"{name}.mp4"),
    ], text=True))["streams"][0]
    settings = dict(re.findall(r"^Set (Width|Height) (\d+)$", (root / "docs/demos/common/settings.tape").read_text(), re.M))
    if (video["width"], video["height"]) != (int(settings["Width"]), int(settings["Height"])):
        raise SystemExit(f"{name}: encoded video dimensions do not match recording settings")
    evidence["video"] = video
    result.write_text(json.dumps(evidence, ensure_ascii=False) + "\n")
    print(f"Verified {name}: GIF + PNG + MP4 + playback evidence ({video['width']}×{video['height']})", flush=True)

if not args.check:
    release = "https://github.com/dirichy/vimoi.nvim/releases/download/demos/"
    media_pattern = re.compile(re.escape(release) + r"([\w-]+\.(?:gif|png|mp4))")
    readmes = {name: (root / name).read_text() for name in ["README.md", "README.zh-CN.md"]}
    missing = sorted({
        name
        for text in readmes.values()
        for name in media_pattern.findall(text)
        if not (root / "docs/demos/output" / name).is_file()
    })
    if missing:
        raise SystemExit(
            "Missing local media: " + ", ".join(missing)
            + ". Run python3 docs/demos/build.py to build all required recordings first."
        )

    # Keep the gallery's featured order in sync with the primary README.
    featured_names = [
        Path(name).stem for name in media_pattern.findall(readmes["README.md"]) if name.endswith(".gif")
    ]
    featured = {name: index for index, name in enumerate(featured_names)}
    cards = []
    results = sorted((output / f"{name}.json" for name in tapes if (output / f"{name}.json").exists()),
                     key=lambda path: (featured.get(path.stem, len(featured)), path.stem))
    for result in results:
        if (json.loads(result.read_text()).get("verified")
                and result.with_suffix(".mp4").exists() and result.with_suffix(".png").exists()):
            name = html.escape(result.stem)
            cards.append(
                f'<section><h2>{name}</h2><video controls preload="none" poster="{name}.png" src="{name}.mp4"></video>'
                f'<p><a href="{name}.gif">GIF</a> · <a href="{name}.mp4">MP4</a> · <a href="{name}.json">Playback evidence</a></p></section>'
            )
    (output / "index.html").write_text(
        '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
        '<title>vimoi.nvim feature recordings</title><style>'
        'body{background:#1a1b26;color:#c0caf5;font:16px system-ui;margin:32px}'
        'main{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,600px),1fr));gap:24px}'
        'video{width:100%}a{color:#7aa2f7}h2{font-size:20px}'
        '</style><h1>vimoi.nvim feature recordings</h1><p>Verified playback · isolated chezmoi fixtures</p><main>'
        + "".join(cards) + '</main></html>\n'
    )
    print(f"Gallery: {output / 'index.html'}", flush=True)

    for name, text in readmes.items():
        text = media_pattern.sub(r"docs/demos/output/\1", text)
        for original in readmes:
            text = text.replace(f"]({original})", f"]({original.removesuffix('.md')}.local.md)")
        if name == "README.zh-CN.md":
            note = "> 自动生成的本地预览；请编辑 README.zh-CN.md 后重新生成。[本地实录合集](docs/demos/output/index.html)。"
        else:
            note = "> Generated local preview; edit README.md and regenerate. [Local recordings](docs/demos/output/index.html)."
        title, body = text.split("\n", 1)
        destination = root / (name.removesuffix(".md") + ".local.md")
        destination.write_text(title + "\n\n" + note + "\n" + body)
        print(f"Local README: {destination}")

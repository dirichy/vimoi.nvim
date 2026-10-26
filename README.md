# vimoi.nvim

Edit [chezmoi](https://www.chezmoi.io/) templates in Neovim, preview their output, and bring changes from deployed files back into source.

[简体中文](README.zh-CN.md) · [English help](doc/vimoi.txt) · [中文帮助](doc/vimoi.cnx)

> This project is in alpha. APIs and behavior may change.

Open a chezmoi source or target with your usual editing workflow. vimoi connects the template,
its rendered output, and the actual file: see results as you type, compare them with familiar
diff controls, and bring identifiable static target changes back into the template while preserving expressions.

## Demos

GIFs play directly here. Use the MP4 links for full-resolution video; local builds use relative GIF paths.

**Template-aware diff.** Compare rendered output with the actual file, transfer hunks in both directions, and choose insertion positions. [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diff.mp4)

![Template diff: synchronized scrolling, hunk transfer, and insertion choices](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diff.gif)

**Static write-back.** Bring target changes into the template in bulk while preserving expressions. [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/readd.mp4)

![Write static changes back to source while preserving template expressions](https://github.com/dirichy/vimoi.nvim/releases/download/demos/readd.gif)

**Live preview.** Edit unsaved templates with synchronized scrolling, branch changes, undo, and error recovery. [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/preview.mp4)

![Live template preview: static edits, branch changes, and undo](https://github.com/dirichy/vimoi.nvim/releases/download/demos/preview.gif)

[All feature recording scripts and coverage](docs/demos/README.md)

Build local demos with `python3 docs/demos/build.py`, then open `README.local.md` in your Markdown previewer.
Use `--readme-only` to reuse existing videos. Generated READMEs and media are ignored by Git.

## Features

- **Live preview.** Render unsaved templates as you edit. Failed renders retain the previous output and mark it stale.
- **Template-aware diff.** Keep source editable while comparing rendered output with the actual target, with synchronized scrolling, change navigation, folds, and bidirectional `do` / `dp`.
- **Write back without losing expressions.** `:VimoiReAdd` merges identifiable static changes in bulk. Dynamic output needs manual edits; ambiguous insertions prompt for a location.
- **Template and host highlighting.** See both template and zsh syntax in `dot_zshrc.tmpl`. By default, colors are mapped from complete rendered output; Tree-sitter injection is also available. Plain sources get their target's filetype.
- **Diagnostics as you edit.** Check template syntax and execution, reuse your LSP / nvim-lint configuration to check rendered output, and map host diagnostics back to source.
- **Completion and navigation.** blink.cmp offers functions, data fields, local variables, paths, and block snippets. `gf` / `gF` understand includes, shared templates, globs, and symlink paths; optional vim-matchup provides `%` matching for template blocks.
- **Source / target navigation.** `:VimoiToggle` opens the other side and preserves unsaved changes in both buffers. Slow background tasks show progress and can be canceled.

Write-back operations modify buffers. Review and save with `:write`, then run `chezmoi apply` when ready to deploy.

## Contents

- [Demos](#demos)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Preview, compare, and write back](#preview-compare-and-write-back)
- [Highlighting and diagnostics](#highlighting-and-diagnostics)
- [Completion](#completion)
- [Path navigation](#path-navigation)
- [Keymaps](#keymaps)
- [Cancel tasks and refresh manually](#cancel-tasks-and-refresh-manually)
- [Lua API](#lua-api)
- [Compared with chezmoi-template.nvim](#compared-with-chezmoi-templatenvim)
- [Scope and limitations](#scope-and-limitations)
- [Health and documentation](#health-and-documentation)
- [Development and roadmap](#development-and-roadmap)
- [License](#license)

## Requirements

- Neovim 0.12+.
- chezmoi 2.x, available on `PATH` or specified in the configuration.
- The `gotmpl` Tree-sitter parser for template features. Target language parsers are optional;
  highlighting falls back to Vim syntax when unavailable.

Optional integrations:

| Feature | Needs |
| --- | --- |
| Template completion | [blink.cmp](https://github.com/Saghen/blink.cmp), with the source registered |
| Host diagnostics | An enabled Neovim LSP or configured [nvim-lint](https://github.com/mfussenegger/nvim-lint) stdin linter |
| `%` block matching | [vim-matchup](https://github.com/andymass/vim-matchup), with Tree-sitter matching enabled |

Tested on Linux with Neovim 0.12.6 and chezmoi 2.73.3. Other platforms have not been verified.

## Installation

With lazy.nvim:

```lua
{
  "dirichy/vimoi.nvim",
  lazy = false,
  opts = {},
}
```

With another plugin manager, install `dirichy/vimoi.nvim` and call:

```lua
require("vimoi").setup()
```

After installing the gotmpl parser and configuring the plugin, run `:checkhealth vimoi`.
Set `vim.g.mapleader` before setup to use the default mappings below.

You can also lazy-load with `ft = "gotmpl"`, but opening a plain source file will not
trigger loading. Use the startup configuration above for plain source filetype detection
and global commands.

## Configuration

The defaults work without extra options. Set only what you want to change:

```lua
require("vimoi").setup({
  split = "horizontal", -- Stacked windows
  keymaps = { readd = false }, -- Disable the default ReAdd mapping
})
```

<details>
<summary>All options with defaults</summary>

```lua
require("vimoi").setup({
  chezmoi_executable = "chezmoi", -- Can also be an executable wrapper
  chezmoi_config_path = nil, -- Optional chezmoi configuration file path
  split = "vertical", -- Or "horizontal"
  watch = { buffer_write_fallback = "auto" },
  render = { validate = true },
  completion = { enabled = true },
  diagnostics = { enabled = true, host = true },
  highlight = {
    mode = "rendered",
    template_bg = "NormalFloat",
  },
  keymaps = {
    diff = "<leader>cd",
    preview = "<leader>cp",
    toggle = "<leader>ct",
    invalidate_cache = "<leader>cr",
    readd = "<leader>ca",
    cancel_command = "<leader>cx",
    goto_file = "gf",
    goto_file_line = "gF",
    diff_get = "do",
    diff_put = "dp",
    fold_open = "zo",
    fold_close = "zc",
    fold_toggle = "za",
    fold_open_recursive = "zO",
    fold_close_recursive = "zC",
    fold_toggle_recursive = "zA",
    fold_open_all = "zR",
    fold_close_all = "zM",
  },
})
```

</details>

`render.validate` controls construction checks shared by preview, highlighting, diagnostics, and diff.
Move old `diff = { validate = ... }` or `session = { validate = ... }` settings
to `render = { validate = ... }`; old options report a migration error.

`chezmoi_config_path` selects another chezmoi configuration file. It supports `~` and relative paths,
resolved against the working directory at setup; read environment variables explicitly with `vim.env`.
`setup()` initializes the plugin once. Put all options in that call; subsequent calls
report an error. Restart Neovim after changing configuration. See `:help vimoi-setup`.

## Preview, compare, and write back

Open a chezmoi-managed source or target file:

| Command | Purpose |
| --- | --- |
| `:VimoiToggle [path]` | Open the other side of a source/target pair |
| `:VimoiPreview [source]` | Preview a template's read-only rendered output |
| `:VimoiDiff` | Compare the current file's source and target |
| `:VimoiDiff {source} {target}` | Compare an explicit file pair |
| `:VimoiReAdd [path]` | Write target changes back to the source buffer |
| `:VimoiCancel` | Cancel a running command |

### Edit and preview a template

1. Run `:VimoiToggle` to switch to the source template.
2. Run `:VimoiPreview` and keep editing in the source window.
3. The read-only preview updates on the right without saving the source first.

You can also run `:VimoiPreview /path/to/source.tmpl`. Unnamed buffers and template
fragments without a standalone target are supported. Preview does not modify the actual
target. If rendering fails, the previous output is retained and marked as stale.

Repeated diff/preview commands reuse the current window pair. Closing either window or
replacing its buffer ends the view. Set `split = "horizontal"` for a horizontal split;
existing windows are not rearranged.

Both views synchronize corresponding lines and logical viewport offsets. Repeated
output uses its first execution; exact screen-row alignment is not guaranteed.

### Compare and transfer a hunk

Run `:VimoiDiff`, use `[c` / `]c` to navigate changes, and use native fold keys to show
or hide context. In a template diff, the transfer directions are:

| Current window | `do`: get into the current window | `dp`: put into the other side |
| --- | --- | --- |
| Source template | Write the current target hunk back to the template | Write the current hunk's rendered output to the target |
| Target | Get the template's rendered output for the current hunk | Write the current hunk back to the template |

Alternatively, run `:VimoiDiffPut` to send the current hunk to the other window,
or `:VimoiDiffGet` to take the other window's hunk into the current window.
Changes on both sides support undo/redo and are not saved automatically.
Changes to dynamic output cannot be inverted into template expressions; edit the source
manually. Ambiguous static insertion positions prompt you to choose a location.

These template operations require the plugin mappings or commands. Native `:diffget` /
`:diffput` or `normal!` copy template source text. Plain files use native two-file diff,
where `do` / `dp` keep their native meaning.

### Write target changes back to the source

Run `:VimoiReAdd`, or specify a source or target path:

```vim
:VimoiReAdd /path/to/file
```

- **Plain text files:** read both current buffers without saving and copy all target
  content into the source. Existing unsaved source content is replaced; one undo restores
  it. Identical content does not trigger another change.
- **Templates:** write back identifiable static changes in bulk while preserving expressions.
  Dynamic or uncertain changes remain for manual editing. Choose a location when an insertion
  is ambiguous; canceling the choice skips that insertion.

A diff opens when needed. You can wait for template rendering or cancel it. An existing
diff is reused; a read-only preview switches to a diff with the actual target.
For plain files, the target must exist or already be open in a buffer.
Encrypted files, symlinks, and script sources are not supported by plain text ReAdd.

Review the result and run `:write` in the source window. ReAdd does not invoke the chezmoi
CLI's re-add, update file attributes, save automatically, or apply changes.
Likewise, Diff Put/Get only modify a buffer hunk; they do not run chezmoi apply.

You can also configure vimoi as a `chezmoi merge` editor; see `:help vimoi-chezmoi-merge`.
The external `chezmoi diff` interface does not directly provide source, so the merge recipe cannot be reused as-is.

## Highlighting and diagnostics

The host language is detected from the actual target name and shebang. By default, vimoi parses
complete rendered output and maps colors back to literal template text. Unexecuted branches use
`Comment`; existing colors remain during edits or temporary template errors.

![Rendered host colors, inactive branches, and template action backgrounds](https://github.com/dirichy/vimoi.nvim/releases/download/demos/highlighting.gif)

[Full-resolution highlighting demo (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/highlighting.mp4)

| `highlight.mode` | Behavior |
| --- | --- |
| `"rendered"` (default) | Map host colors from rendered output; covers branches executed with current data |
| `"injection"` | Parse host fragments directly in the template; incomplete syntax may highlight inaccurately |
| `"disabled"` | Disable host highlighting, preserving gotmpl action highlighting |

Enabled host modes fall back to Vim syntax when the host parser is missing.
`highlight.template_bg` borrows `NormalFloat` by default; use another highlight group, a color,
or `{ dark = "#123456", light = "#E4E9F4" }` to customize it.

Template diagnostics run as you edit without opening diff or preview. Rendering errors
without a source location appear on the first line, with the original message and a location-unavailable label. Host diagnostics reuse
existing configuration: enable the server with `vim.lsp.enable()` or configure
`require("lint").linters_by_ft`, without listing checkers again in vimoi.
The plugin checks rendered output and maps errors back to source. Static text gets precise locations;
dynamic output points to its producing template region, and ambiguous output locations are skipped.
Messages use `[gotmpl]` or host labels such as `[host:lua]` and `[host:yaml]`.

![Template errors and host diagnostics projected back to source, followed by repair](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diagnostics.gif)

[Full-resolution diagnostics demo (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diagnostics.mp4)

```lua
require("vimoi").setup({
  diagnostics = { enabled = true, host = false }, -- Keep template diagnostics only
})
```

`diagnostics.enabled = false` disables diagnostics; customize their display with `vim.diagnostic.config()`.
Host checks use an unsaved output buffer, and nvim-lint integration supports stdin linters only.
Rules tied to exact filenames, such as some YAML schema associations, may need adjustment.
Loop text uses its first execution's colors; `define` / `block` bodies have no host-color projection,
so use injection to highlight them. See `:help vimoi-highlighting` and `:help vimoi-setup` for details.

## Completion

Completion integrates with blink.cmp only. Register the source in its configuration:

```lua
require("blink.cmp").setup({
  completion = {
    accept = {
      auto_brackets = {
        blocked_filetypes = { "gotmpl" },
      },
    },
  },
  sources = {
    default = { "lsp", "path", "snippets", "buffer", "vimoi" },
    providers = {
      vimoi = {
        name = "Vimoi",
        module = "vimoi.blink",
        score_offset = 100,
      },
    },
  },
})
```

Completes template functions, data fields, current buffer variables, and include/template/glob
paths without displaying data values. Outside template actions, it offers `if`, `ifelse`,
`range`, `with`, `define`, `block`, and `comment` snippets.
`blocked_filetypes` prevents inappropriate parentheses from being added when accepting
template function completions.

![Real completion menus for data, functions, variables, paths, and block snippets](https://github.com/dirichy/vimoi.nvim/releases/download/demos/completion.gif)

[Full-resolution completion demo (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/completion.mp4)

## Path navigation

Use `gf` in templates or symlink sources. `gF` also supports `path:line` / `path:line:column`.

| Context | Path base |
| --- | --- |
| `include "path"` | chezmoi source directory |
| `template "name"` / `includeTemplate "name"` | `.chezmoitemplates` |
| `glob "pattern"`, `.chezmoiignore` / `.chezmoiremove` | Destination directory |
| `symlink_*` content | Directory containing the generated symlink |
| Absolute paths, `~` paths, and `file://` URLs | File system |

Path lookup is synchronous and does not load template data.
Multiple matches open a picker; unresolved paths fall back to native navigation.
Managed destination paths open their source preferentially. With optional vim-matchup
and its Tree-sitter matching enabled, `%` jumps between template control blocks.

## Keymaps

Set `vim.g.mapleader` before setup. These global mappings are enabled by default:

| Key | Action |
| --- | --- |
| `<leader>cd` | Open diff |
| `<leader>cp` | Open preview |
| `<leader>ct` | Toggle source / target |
| `<leader>ca` | ReAdd |
| `<leader>cr` | Refresh caches |
| `<leader>cx` | Cancel a task |

`gf` / `gF` are enabled only in templates and symlink sources. Template diff `do` / `dp`
and fold mappings are active only while the corresponding window is focused.
`[c` / `]c` use native change navigation. Plain files retain native two-file diff behavior.

Use `keymaps = { diff = "<leader>hd", readd = false }` to change or disable individual mappings,
or `keymaps = false` to disable all mappings.

## Cancel tasks and refresh manually

Background tasks show progress in the upper right. Run `:VimoiCancel` or `<leader>cx`;
a single task is canceled directly, while multiple tasks open a picker.
In a focused waiting float, press `q`, `Esc`, or `Ctrl-C` to cancel. Closing or leaving
the float also cancels. Canceling the initial render ends the view and preserves both
buffers; canceling a wait prevents the pending write-back from continuing.

Changes to data, configuration, and discovered shared templates trigger automatic refresh.
If results are stale, press `<leader>cr` or run:

```lua
require("vimoi.api").invalidate_cache()
```

New directories, environment variable changes, or failed file watchers may require manual
refresh. For file systems that silently lose watcher events, set
`watch.buffer_write_fallback = true` to refresh when saving in the current Neovim instance.
`false` disables this fallback; the default `"auto"` enables it as needed.
Restart Neovim after changing the source root directory.

![Existing previews refresh after shared template and configuration data changes](https://github.com/dirichy/vimoi.nvim/releases/download/demos/dependencies.gif)

[Full-resolution dependency refresh demo (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/dependencies.mp4)

## Lua API

```lua
local api = require("vimoi.api")
api.toggle()                -- Switch between source and target
api.preview()               -- Preview the current template
api.diff()                  -- Open a diff for the current file
api.diff_buffers(source_buf, target_buf, { filetype = "yaml" })
api.readd()                 -- Write target changes back to the source buffer
api.cancel_command()        -- Cancel a running command
```

These are interactive entry points. Diff/preview operations, including `diff_buffers`,
return `nil`. Write-back operations also
return `nil` while rendering or waiting for a choice, so this does not indicate final success.
See `:help vimoi-api` for arguments, immediate results, and other operations.

`diff_buffers()` accepts two different loaded buffers, including unnamed and scratch buffers;
`0` means the current buffer. Optional `filetype` sets the host language. It compares current
contents and supports the same hunk operations and ReAdd. For file pairs, use
`api.diff_files(source, target)`. See `:help vimoi-api` for complete arguments.

## Compared with chezmoi-template.nvim

Both support direct source editing, live preview, template and host highlighting, blink completion,
and template navigation. Their focus differs. This comparison uses
[chezmoi-template.nvim source](https://github.com/dpezto/chezmoi-template.nvim/tree/670ba83095ba6571f3125a5e5fd4118505a2c3c6), checked on 2026-10-25.

| Feature | vimoi.nvim | chezmoi-template.nvim |
| --- | --- | --- |
| Compare and write back | Template-aware native diff, bidirectional hunks, static ReAdd | Preview annotations against the deployed file |
| Host highlighting | Rendered output projection by default, optional injection | Tree-sitter injection |
| Diagnostics | Template checks as you edit, plus LSP / nvim-lint host checks | Template execution checks on save |
| Completion | Functions, data fields, locals, paths, block snippets; no data values | Functions, data fields with value docs, sensitive-field masking, block snippets |
| Template formatting, target icons, transparent encryption | Not provided | Conform, mini.icons, optional decrypt/encrypt |
| File selection and deployment | Source / target toggle; deploy with the CLI | Multiple file pickers, apply commands, apply on save by default |
| Default mappings | Global shortcuts, can be disabled | Opt-in source-buffer mappings |
| Neovim requirement | 0.12+ | 0.10+ |

Consider it for formatting, encryption, and deployment integrations. vimoi focuses on comparing rendered
output and bringing static changes from actual files back into templates.
See the [implementation comparison and historical research](docs/plugin-comparison.md) (Chinese).

## Scope and limitations

- Changes to dynamic or repeated output usually need manual source edits. General reverse merging and automatic ReAdd are outside the scope.
- `define` / `block` bodies have no internal source mapping, so even static text in them needs manual edits.
- Custom template delimiters and templates producing different results under `chezmoi cat` and `apply` are unsupported.
- `render.validate = true` checks the on-disk baseline against `chezmoi cat` when first constructing a file's source session. Reopen the file after failure. Unnamed, unmanaged, source-only, and init templates skip this check.
- Data and shared-template changes usually refresh automatically. Environment changes, time-sensitive functions, and undiscovered directories may need a manual refresh.
- Formatting, icons, transparent encryption, managed-file browsing, and apply commands are not provided. Use the chezmoi CLI for file attributes and deployment.

Diagnostics, previews, and rendered highlighting execute template functions and may invoke password helpers.
Slow background tasks can be canceled and have no default timeout.
See `:help vimoi-limitations` for rendering context, cache behavior, and reserved-marker constraints.

## Health and documentation

```vim
:checkhealth vimoi
:help vimoi.nvim
:set helplang=cn
:help vimoi.nvim@en
:help vimoi.nvim@cn
```

## Development and roadmap

- [FEATURES](FEATURES.md): implemented features and future candidates.
- [Preview performance comparison](docs/preview-benchmark.md) and [buffer write measurements](docs/buffer-edits.md).
- [Re-record the README demos](docs/demos/README.md).

Run the complete suite with `python3 tests/run.py`: Lua tests followed by real demo
recordings, media conversion, and local README generation. It also requires the
[recording dependencies](docs/demos/README.md#依赖). Use `--skip-demos` for
Lua tests only, or pass individual Lua test filenames. Tests use isolated configuration
and temporary files; recording can take several minutes. The full Lua suite first
checks the parsers and highlight queries listed in [tests/parsers.txt](tests/parsers.txt),
including injected languages. Help tests generate their own temporary tags.
Check formatting with `stylua --check lua ftdetect tests docs/demos/init.lua`.
LuaLS should use the real Neovim runtime library and retain all diagnostic levels.

## License

[MIT](LICENSE), Copyright (c) 2026 dirichy.

# vimoi.nvim

Edit [chezmoi](https://www.chezmoi.io/) templates in Neovim, preview their output, and bring static target changes back into source while preserving expressions.

[简体中文](README.zh-CN.md) · [Help](doc/vimoi.txt)

> This project is in alpha. APIs and behavior may change.

## Demos

**Template-aware diff.** Compare rendered output with the actual file, transfer hunks in both directions, and choose insertion positions. [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diff.mp4)

![Template diff: synchronized scrolling, hunk transfer, and insertion choices](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diff.gif)

**Static write-back.** Bring target changes into the template in bulk while preserving expressions. [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/readd.mp4)

![Write static changes back to source while preserving template expressions](https://github.com/dirichy/vimoi.nvim/releases/download/demos/readd.gif)

**Live preview.** Edit unsaved templates with synchronized scrolling, branch changes, undo, and error recovery. [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/preview.mp4)

![Live template preview: static edits, branch changes, and undo](https://github.com/dirichy/vimoi.nvim/releases/download/demos/preview.gif)

## Installation and configuration

Requires Neovim 0.12+, chezmoi 2.x, and the `gotmpl` Tree-sitter parser.
Host-language parsers are optional; highlighting falls back to Vim syntax. Tested on Linux.

With lazy.nvim:

```lua
{
  "dirichy/vimoi.nvim",
  lazy = false,
  opts = {},
}
```

With another plugin manager, install the plugin and call `require("vimoi").setup()`.
Set `vim.g.mapleader` first, then run `:checkhealth vimoi` after installation.

The defaults work without extra options. For example, customize lazy.nvim's `opts`:

```lua
opts = {
  split = "horizontal", -- Stacked windows
  keymaps = { readd = false }, -- Disable the default ReAdd mapping
}
```

See `:help vimoi-setup` for all options. Configure the plugin once at startup;
restart Neovim after changing options.

## Usage

Open a chezmoi-managed source or target, then use these commands and default mappings:

| Command | Key | Purpose |
| --- | --- | --- |
| `:VimoiToggle` | `<leader>ct` | Switch source / target, preserving unsaved edits |
| `:VimoiPreview` | `<leader>cp` | Preview the current template as you type, without saving |
| `:VimoiDiff` | `<leader>cd` | Compare rendered output with the actual target |
| `:VimoiReAdd` | `<leader>ca` | Bring target changes back into source in bulk |
| `:VimoiCancel` | `<leader>cx` | Cancel slow tasks |

Path arguments are also available; see `:help vimoi-commands`.
Preview supports unnamed buffers and template fragments. Failed renders retain the previous
output and mark it stale. Close either window to end a diff/preview.

### Compare and write back

Use `[c` / `]c` to navigate changes and `zo` / `zc` to show or hide context.
In a template diff:

| Current window | `do`: get into this window | `dp`: put into the other window |
| --- | --- | --- |
| Source template | Write target changes back to the template | Put rendered output into the target |
| Target | Get rendered template output | Write target changes back to the template |

Use the plugin's `do` / `dp` mappings or `:VimoiDiffGet` / `:VimoiDiffPut`;
native `:diffget` / `:diffput` copy template source text. Plain files retain native `do` / `dp` behavior.

`:VimoiReAdd` merges identifiable static changes in bulk while preserving expressions;
ambiguous positions prompt for a choice. Dynamic output needs manual source edits.
For plain text files, it replaces source content with the entire current target buffer,
including unsaved edits. Use `u` to undo.

**Write-back changes buffers without saving or applying.** Review and save with `:write`,
then run `chezmoi apply` to deploy.

![Plain source filetype detection, native diff, and write-back of unsaved target text](https://github.com/dirichy/vimoi.nvim/releases/download/demos/plain.gif)

[Plain file recording (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/plain.mp4)

## Highlighting and diagnostics

Template and host-language highlighting are enabled by default; inactive branches use comment colors.
Set `highlight.mode = "injection"` to highlight host fragments directly, or `"disabled"`
to keep only template highlighting. Customize action backgrounds with `highlight.template_bg`.

![Rendered host colors, inactive branches, and template action backgrounds](https://github.com/dirichy/vimoi.nvim/releases/download/demos/highlighting.gif)

[Full-resolution highlighting demo (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/highlighting.mp4)

[Injection highlighting (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/injection.mp4) · [Host highlighting disabled (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/disabled.mp4)

Template errors are checked as you edit. Host diagnostics reuse your enabled Neovim LSP
or nvim-lint configuration, checking rendered output and mapping errors back to source.
nvim-lint supports stdin linters only. Set `diagnostics.host = false` for template diagnostics only.
See `:help vimoi-highlighting` and `:help vimoi-diagnostics`.

![Template errors and host diagnostics projected back to source, followed by repair](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diagnostics.gif)

[Full-resolution diagnostics demo (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diagnostics.mp4)

## Completion

Register the source in your blink.cmp configuration:

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

Completes functions, data fields, local variables, paths, and block snippets.
`blocked_filetypes` prevents automatic parentheses on template function completions.

Control value masking in vimoi's setup options:

```lua
require("vimoi").setup({
  completion = {
    mask = function(key)
      return key:lower():match("password") ~= nil or key:lower():match("token") ~= nil
    end,
  },
})
```

`completion.mask` defaults to `true`, masking all values; `false` shows all
values. A function receives the full field path without a leading dot (for
example `account.token`) and returns `true` to mask it. Masked values show
`[ masked]` in value documentation, including inside object previews. Masking a
parent also masks all its descendants. Lists use one-based paths such as
`accounts.1.token`. Previews are bounded and truncated; field-name masking only
covers paths matched by your function.

![Real completion menus for data, functions, variables, paths, and block snippets](https://github.com/dirichy/vimoi.nvim/releases/download/demos/completion.gif)

[Full-resolution completion demo (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/completion.mp4)

## Path navigation

In templates and symlink sources, `gf` follows includes, shared templates, globs, and symlink paths;
`gF` also supports `path:line[:column]`. Multiple matches open a picker; managed targets open their source preferentially.
Optional [vim-matchup](https://github.com/andymass/vim-matchup), with Tree-sitter matching enabled,
provides `%` for template blocks. See `:help vimoi-navigation` for path rules.

![Source/target switching preserves unsaved edits; gf/gF navigation and vim-matchup block matching](https://github.com/dirichy/vimoi.nvim/releases/download/demos/navigation.gif)

[Navigation and switching recording (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/navigation.mp4)

## Cancel tasks and refresh

Slow tasks show progress and can be canceled with `:VimoiCancel` or `<leader>cx`.
In a focused waiting float, use `q`, `Esc`, or `Ctrl-C`. Canceled pending write-back does not continue.

![Cancel a real slow render, continue editing, and open a working preview](https://github.com/dirichy/vimoi.nvim/releases/download/demos/cancel.gif)

[Task cancellation recording (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/cancel.mp4)

Data, configuration, and discovered shared-template changes refresh automatically.
Press `<leader>cr` if results remain stale. Template execution may invoke password helpers;
waits can be canceled and have no default timeout.

![Existing previews refresh after shared template and configuration data changes](https://github.com/dirichy/vimoi.nvim/releases/download/demos/dependencies.gif)

[Full-resolution dependency refresh demo (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/dependencies.mp4)

## Lua API

`require("vimoi.api").diff_buffers(source_buf, target_buf, { filetype = "yaml" })`
compares two loaded buffers, including unnamed and scratch buffers, with the same hunk operations and ReAdd.
See `:help vimoi-api` for the full API.

![Horizontal diff of unnamed scratch buffers, hunk write-back, undo, and ReAdd](https://github.com/dirichy/vimoi.nvim/releases/download/demos/buffers.gif)

[Buffer API and horizontal splits recording (MP4)](https://github.com/dirichy/vimoi.nvim/releases/download/demos/buffers.mp4)

## Compared with chezmoi-template.nvim

Both support direct source editing, live preview, template and host highlighting, blink completion,
and template navigation. Their focus differs. This comparison uses
[chezmoi-template.nvim source](https://github.com/dpezto/chezmoi-template.nvim/tree/670ba83095ba6571f3125a5e5fd4118505a2c3c6), checked on 2026-10-25.

| Feature | vimoi.nvim | chezmoi-template.nvim |
| --- | --- | --- |
| Compare and write back | Template-aware native diff, bidirectional hunks, static ReAdd | Preview annotations against the deployed file |
| Host highlighting | Rendered output projection by default, optional injection | Tree-sitter injection |
| Diagnostics | Template checks as you edit, plus LSP / nvim-lint host checks | Template execution checks on save |
| Completion | Functions, data fields, locals, paths, block snippets; optional filtered data value docs | Functions, data fields with value docs, sensitive-field masking, block snippets |
| Template formatting, target icons, transparent encryption | Not provided | Conform, mini.icons, optional decrypt/encrypt |
| File selection and deployment | Source / target toggle; deploy with the CLI | Multiple file pickers, apply commands, apply on save by default |
| Default mappings | Global shortcuts, can be disabled | Opt-in source-buffer mappings |
| Neovim requirement | 0.12+ | 0.10+ |

Consider it for formatting, encryption, and deployment integrations. vimoi focuses on comparing rendered
output and bringing static changes from actual files back into templates.
See the [implementation comparison and historical research](docs/plugin-comparison.md) (Chinese).

## Scope and limitations

- Changes to dynamic or repeated output and `define` / `block` bodies usually need manual source edits.
- Custom template delimiters and templates producing different results under `chezmoi cat` and `apply` are unsupported.
- Encrypted files, symlinks, and script sources are unsupported by plain text ReAdd.
- Formatting, icons, file browsing, and apply commands are not provided; deploy with the chezmoi CLI.
- Transparent editing of chezmoi-encrypted source is not provided. For repository encryption, we recommend [git-crypt](https://github.com/AGWA/git-crypt): unlocked templates are directly editable, and the local working tree is plaintext. See [chezmoi transparent encryption](https://www.chezmoi.io/user-guide/encryption/transparent/).

See `:help vimoi-limitations` for further constraints.

## Help

Run `:checkhealth vimoi` to check your setup, or `:help vimoi.nvim` for the full manual.
[Recording demos](docs/demos/README.md) · [Development notes](docs/module-responsibilities.md) · [Roadmap](FEATURES.md)

## License

[MIT](LICENSE), Copyright (c) 2026 dirichy.

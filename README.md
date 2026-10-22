# vimoi.nvim

在 Neovim 中安全、顺手地编辑由 [chezmoi](https://www.chezmoi.io/) 管理的文件。

[English documentation](doc/vimoi.txt) · [中文帮助](doc/vimoi.cnx)

> 项目处于 alpha 阶段，API 和行为仍可能调整。

## 演示

编辑未保存的模板，右侧只读预览同步更新；修改条件分支和 undo 同样生效：

![实时模板预览：静态文本编辑、条件分支切换和撤销](docs/demos/preview.gif)

模板 diff 与手动 re-add：把 target 的静态修改写回 source，保留模板表达式；动态修改留待手动处理：

![模板 diff 与 re-add：静态修改写回，动态表达式保留](docs/demos/readd.gif)

[预览 MP4](docs/demos/preview.mp4) · [re-add MP4](docs/demos/readd.mp4) · [重录说明](docs/demos/README.md)

## 功能

- 在 chezmoi source 和真实 target 之间切换，保留各自未保存的修改。
- 编辑模板时预览只读结果，或比较模板与 target，并按 hunk 双向操作。
- 手动 ReAdd：普通文件将 target 内容写回 source；模板保留表达式，写回可确定的静态修改。
- 模板诊断、宿主语言高亮、blink.cmp 补全和路径跳转。

所有写回都由用户主动触发，只修改 buffer，不自动保存，也不自动执行 chezmoi apply。

## 要求

- Neovim 0.12+。
- chezmoi 2.x，位于 `PATH` 中或通过配置指定。
- 模板功能需要 `gotmpl` Tree-sitter parser。目标语言 parser 可选，缺少时回退到 Vim syntax 高亮。

已在 Linux、Neovim 0.12.6 和 chezmoi 2.73.3 上测试；其他平台尚未验证。

## 安装

lazy.nvim：

```lua
{
  "dirichy/vimoi.nvim",
  opts = {},
}
```

其他插件管理器安装 `dirichy/vimoi.nvim` 后调用：

```lua
require("vimoi").setup()
```

安装 gotmpl parser 并完成配置后，执行 `:checkhealth vimoi` 检查环境。
如需使用下文的默认快捷键，请先设置 `vim.g.mapleader`。

也可通过 `ft = "gotmpl"` 懒加载，但直接打开普通 source 文件不会触发加载。
需要普通 source 的文件类型识别或全局命令时，使用上面的提前加载配置。

## 快速开始

打开一个受 chezmoi 管理的 source 或 target 文件：

| 命令 | 用途 |
| --- | --- |
| `:VimoiToggle [path]` | 打开 source/target 的另一侧 |
| `:VimoiPreview [source]` | 预览模板的只读渲染结果 |
| `:VimoiDiff` | 比较当前文件的 source 与 target |
| `:VimoiDiff {source} {target}` | 比较指定的两个文件 |
| `:VimoiReAdd [path]` | 将 target 修改写回 source buffer |
| `:VimoiCancel` | 取消耗时命令 |

### 编辑模板并预览

1. 执行 `:VimoiToggle` 切到 source 模板。
2. 执行 `:VimoiPreview`，继续在 source 窗口编辑。
3. 右侧只读结果随编辑更新，无须先保存。

也可以执行 `:VimoiPreview /path/to/source.tmpl`。支持未命名 buffer 和没有独立
target 的模板片段。预览不会修改真实 target；渲染失败时保留旧结果并标明过期。

重复执行 diff/preview 会复用当前窗口对。关闭或替换任一侧即可结束该视图。
`split = "horizontal"` 可改成上下分屏；已有窗口不会重新排列。

### 比较与修改一个 hunk

执行 `:VimoiDiff` 后，使用 `[c` / `]c` 跳转差异，使用原生折叠键展开或收起上下文。
模板 diff 中的按键方向如下：

| 当前窗口 | `do`：取入当前窗口 | `dp`：送到另一侧 |
| --- | --- | --- |
| source 模板 | 将 target 的当前 hunk 写回模板 | 将当前 hunk 的渲染结果写入 target |
| target | 取入模板当前 hunk 的渲染结果 | 将当前 hunk 写回模板 |

也可执行 `:VimoiDiffPut` 将当前 target hunk 写入模板，或执行 `:VimoiDiffApply`
将当前 hunk 的渲染结果写入 target。两侧修改都支持 undo/redo，不自动保存。
模板动态输出的修改不能反向还原表达式，需要手动编辑 source；静态插入位置有歧义时会提示选择。

这些模板操作依赖插件映射或命令。直接使用原生 `:diffget` / `:diffput` 或 `normal!`
会复制模板源码。普通文件使用原生双文件 diff，`do` / `dp` 保持原生含义。

### 将 target 的修改写回 source

执行 `:VimoiReAdd`，或者指定 source/target 路径：

```vim
:VimoiReAdd /path/to/file
```

- **普通文本文件**：读取两侧当前 buffer，无须先保存；将 target 的全部内容写入 source。
  source 原有未保存内容会被替换，可用一次 undo 恢复；相同内容不会重复修改。
- **模板**：批量写回可确定的静态修改，保留表达式；动态或无法确定的修改留待手动处理。
  位置有歧义时选择合适的插入位置；取消选择会跳过该处。

需要时自动打开 diff；模板渲染尚未完成时可以等待或取消。已有 diff 直接复用，
只读预览会切换到真实 target diff。普通文件的 target 必须存在，或已在 buffer 中打开。
加密文件、symlink 和脚本 source 暂不支持普通文本 ReAdd。

检查结果后，在 source 窗口用 `:write` 保存。ReAdd 不执行 chezmoi CLI 的 re-add，
不更新文件属性，也不自动保存或 apply。`VimoiDiffApply` 同样只修改当前 target hunk，
不等同于 chezmoi apply。

## 配置和默认键位

以下为完整默认配置，可只填写需要修改的部分：

```lua
require("vimoi").setup({
  chezmoi_executable = "chezmoi", -- 也可指定可执行的 wrapper
  chezmoi_config_path = nil, -- 可选的 chezmoi 配置文件路径
  split = "vertical", -- 或 "horizontal"
  watch = { buffer_write_fallback = "auto" },
  diff = { validate = false },
  completion = { enabled = true },
  diagnostics = { enabled = true },
  highlight = {
    template_bg = { dark = "#343B52", light = "#E4E9F4" },
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

全局入口默认是 `<leader>cd` diff、`<leader>cp` preview、`<leader>ct` 切换、
`<leader>ca` ReAdd、`<leader>cr` 刷新缓存、`<leader>cx` 取消命令。
`gf` / `gF` 仅在模板及 symlink source 中启用；模板 diff 的 hunk 和折叠映射仅在相应窗口聚焦时启用。

任一映射设为字符串可换键，设为 `false` 或空字符串可关闭；`keymaps = false` 关闭全部映射：

```lua
require("vimoi").setup({ keymaps = { diff = "<leader>hd", readd = false } })
```

`chezmoi_config_path` 支持 `~` 和相对路径，相对路径以 setup 时的工作目录为准。
`$` 按字面保留；需要环境变量时显式传入，例如
`chezmoi_config_path = vim.env.MY_CHEZMOI_CONFIG`（需先设置该变量）。

进程/config 路径、watch 和 keymaps 在首次成功 setup 后固定，修改后需重启 Neovim。
其余选项可再次 setup 更新；省略的可更新选项恢复默认值。
`highlight.template_bg` 也可直接设为一个颜色字符串。

## 模板诊断与高亮

模板诊断默认启用，无须打开 diff 或 preview。编辑后会检查语法和执行错误，
使用原生 Neovim diagnostics，与其他 LSP 诊断共存。可通过
`diagnostics = { enabled = false }` 关闭，显示样式用 `vim.diagnostic.config()` 调整。

诊断和预览会实际执行模板函数，可能调用密码助手；耗时任务可取消，没有默认超时。
模板宿主语言会按 target 名称和 shebang 识别，例如 `dot_zshrc.tmpl` 使用 zsh 高亮。
模板拼接不完整语句时，宿主语言高亮可能不准确。

## blink.cmp 补全

只集成 blink.cmp，需要在 blink 配置中注册 source：

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


补全模板函数、data 字段、当前 buffer 的变量和 include/template/glob 路径，不展示 data 值。
模板 action 外提供 `if`、`ifelse`、`range`、`with`、`define`、`block`、`comment` snippet。
`blocked_filetypes` 防止接受模板函数候选时自动添加不适用的圆括号。

## 路径跳转

在模板或 symlink source 中使用 `gf`；`gF` 还支持 `path:line` / `path:line:column`。

| 位置 | 路径基准 |
| --- | --- |
| `include "path"` | chezmoi source directory |
| `template "name"` / `includeTemplate "name"` | `.chezmoitemplates` |
| `glob "pattern"`、`.chezmoiignore` / `.chezmoiremove` | destination directory |
| `symlink_*` 内容 | 生成的 symlink 所在目录 |
| 绝对路径、`~` 路径和 `file://` URL | 文件系统 |

多个匹配通过 picker 选择；无法解析时回退到原生跳转。对于受管理的 destination 路径，
优先打开 source。安装可选的 vim-matchup 并启用其 Tree-sitter 匹配后，可用 `%` 跳转模板控制块。

## 取消任务和手动刷新

后台任务在右上角显示进度；执行 `:VimoiCancel` 或 `<leader>cx`，只有一个任务时直接取消，
多个时选择要取消的任务。在聚焦的等待浮窗中按 `q`、`Esc`、`Ctrl-C`，关闭或离开浮窗也会取消。
取消初次渲染会结束该视图，保留两侧 buffer；取消等待不会继续写回。

data、配置和已发现的共享模板变化后会自动刷新。若结果未更新，执行 `<leader>cr` 或：

```lua
require("vimoi.api").invalidate_cache()
```

新增目录、环境变量变化或文件系统监听失效时，可能需要手动刷新。
某些文件系统静默丢失监听事件时，可设置 `watch.buffer_write_fallback = true`，
让当前 Neovim 的保存触发刷新；`false` 关闭保存兜底，默认 `"auto"` 按需使用。
更换 source 根目录后应重启 Neovim。

## 已知限制

- 模板动态或重复输出的修改通常需要手动编辑 source，不做通用反向合并。
- 不支持自定义模板分隔符，以及依赖纯空白/注释的空 define/block 覆盖语义。
- 不支持结果依赖 `.chezmoi.sourceFile`、`.chezmoi.targetFile`、`.chezmoi.command`、
  `.chezmoi.args` 的模板，也包括间接读取这些字段的 includeTemplate。
- `diff.validate = true` 可额外检查模板渲染与 chezmoi cat 是否一致，不一致时拒绝打开 diff；
  默认关闭，不适用于未保存内容的 preview，也不代表上述不支持的模板已获支持。
- 源码不能包含本次运行使用的保留哨兵前缀，动态输出不能产生完整保留标记。
  随机标记只降低意外碰撞概率；详细约束见 `:help vimoi-limitations`。
- 不提供自动 re-add、自动 apply，也不替代 chezmoi CLI 的文件属性和加密操作。

## Lua API 与帮助

```lua
local api = require("vimoi.api")
api.toggle()                -- source / target 切换
api.preview()               -- 预览当前模板
api.diff()                  -- 打开当前文件的 diff
api.readd()                 -- target 修改写回 source buffer
api.cancel_command()        -- 取消耗时命令
```

这些是交互入口。diff/preview 返回 `nil`；写回操作等待渲染或选择时也返回 `nil`，
不能用它判断最终是否成功。参数、即时结果和其他操作见 `:help vimoi-api`。

```vim
:help vimoi.nvim
:set helplang=cn
:help vimoi.nvim@en
:help vimoi.nvim@cn
```

## 开发与规划

- [FEATURES](FEATURES.md)：已完成与后续候选。
- [预览性能对比](docs/preview-benchmark.md)、[局部写入实测](docs/buffer-edits.md)。
- [重录 README 演示](docs/demos/README.md)。

测试：`python3 tests/run.py`，也可追加测试文件名。需要 Python 3、Unix shell 和上述依赖，
测试使用独立配置和临时文件。格式检查：`stylua --check lua ftdetect tests docs/demos/init.lua`。
LuaLS 应使用真实 Neovim runtime library，并保留全部诊断等级。

## License

[MIT](LICENSE)，Copyright (c) 2026 dirichy。

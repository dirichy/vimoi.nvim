# vimoi.nvim

在 Neovim 中编辑 [chezmoi](https://www.chezmoi.io/) 模板，预览生成结果，把实际配置的修改带回源码。

[English](README.md) · [English help](doc/vimoi.txt) · [中文帮助](doc/vimoi.cnx)

> 项目处于 alpha 阶段，API 和行为仍可能调整。

直接打开 chezmoi 的 source 或 target，沿用平常的编辑方式。vimoi 把模板、渲染结果和实际文件联系起来：
你可以边改边看结果，用熟悉的 diff 操作比较差异，也可以把 target 中可确定的静态修改写回模板，保留表达式。

## 演示

GIF 可直接播放；查看原始清晰度可使用 MP4 链接。本地构建会使用相对 GIF 路径。

**模板感知的 diff。** 比较渲染结果与实际文件，双向传递 hunk，选择插入位置。 [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diff.mp4)

![模板 diff：同步滚动、hunk 传递和插入位置选择](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diff.gif)

**保留表达式的静态写回。** 批量把 target 修改带回模板，保留动态表达式。 [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/readd.mp4)

![静态修改写回 source，保留模板表达式](https://github.com/dirichy/vimoi.nvim/releases/download/demos/readd.gif)

**实时预览。** 编辑未保存的模板，同步滚动并查看分支变化、撤销和错误恢复。 [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/preview.mp4)

![实时模板预览：静态文本编辑、条件分支切换和撤销](https://github.com/dirichy/vimoi.nvim/releases/download/demos/preview.gif)

[全部功能实录脚本与覆盖范围](docs/demos/README.md)

本地构建实录：运行 `python3 docs/demos/build.py`，再用 Markdown 预览器打开 `README.zh-CN.local.md`。
加 `--readme-only` 可复用已有视频；生成的 README 和媒体均被 Git 忽略。

## 功能

- **实时预览。** 未保存的模板也能预览；编辑后自动更新，渲染失败时保留上次结果并标明过期。
- **模板感知的 diff。** 保持 source 可编辑，比较渲染结果与实际 target，支持同步滚动、差异跳转、折叠和双向 `do` / `dp`。
- **保留表达式的写回。** `:VimoiReAdd` 批量写回可确定的静态修改；动态输出需要手动处理，插入位置有歧义时提示选择。
- **模板与宿主语言高亮。** `dot_zshrc.tmpl` 同时显示模板和 zsh 语法；默认从完整渲染结果映射颜色，也可选择 Tree-sitter injection。普通 source 按 target 识别 filetype。
- **编辑时诊断。** 检查模板语法和执行错误，并复用已有 LSP / nvim-lint 配置检查渲染结果，把宿主语言诊断映射回模板。
- **补全与导航。** blink.cmp 提供函数、data 字段、局部变量、路径和块 snippet；`gf` / `gF` 理解 include、共享模板、glob 和 symlink 路径，可选 vim-matchup 支持 `%` 匹配模板块。
- **source / target 切换。** `:VimoiToggle` 打开另一侧，保留两侧未保存的修改。耗时后台任务有进度显示，可主动取消。

写回操作只修改 buffer。检查结果后用 `:write` 保存，需要部署时再执行 `chezmoi apply`。

## 目录

- [演示](#演示)
- [功能](#功能)
- [要求](#要求)
- [安装](#安装)
- [配置](#配置)
- [预览、比较与写回](#预览比较与写回)
- [高亮与诊断](#高亮与诊断)
- [补全](#补全)
- [路径跳转](#路径跳转)
- [键位](#键位)
- [取消任务和手动刷新](#取消任务和手动刷新)
- [Lua API](#lua-api)
- [与 chezmoi-template.nvim 对比](#与-chezmoi-templatenvim-对比)
- [范围与限制](#范围与限制)
- [健康检查与帮助](#健康检查与帮助)
- [开发与规划](#开发与规划)
- [License](#license)

## 要求

- Neovim 0.12+。
- chezmoi 2.x，位于 `PATH` 中或通过配置指定。
- 模板功能需要 `gotmpl` Tree-sitter parser。目标语言 parser 可选，缺少时回退到 Vim syntax 高亮。

可选集成按需安装：

| 功能 | 依赖 |
| --- | --- |
| 模板补全 | [blink.cmp](https://github.com/Saghen/blink.cmp)，需注册 source |
| 宿主语言诊断 | 已启用的 Neovim LSP 或已配置的 [nvim-lint](https://github.com/mfussenegger/nvim-lint) stdin 检查器 |
| `%` 模板块匹配 | [vim-matchup](https://github.com/andymass/vim-matchup)，启用其 Tree-sitter 匹配 |

已在 Linux、Neovim 0.12.6 和 chezmoi 2.73.3 上测试；其他平台尚未验证。

## 安装

lazy.nvim：

```lua
{
  "dirichy/vimoi.nvim",
  lazy = false,
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

## 配置

默认配置即可使用。只需填写想修改的选项，例如：

```lua
require("vimoi").setup({
  split = "horizontal", -- 上下分屏
  keymaps = { readd = false }, -- 关闭默认 ReAdd 映射
})
```

<details>
<summary>完整默认配置</summary>

```lua
require("vimoi").setup({
  chezmoi_executable = "chezmoi", -- 也可指定可执行的 wrapper
  chezmoi_config_path = nil, -- 可选的 chezmoi 配置文件路径
  split = "vertical", -- 或 "horizontal"
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

`render.validate` 控制 preview、高亮、诊断和 diff 共用的 session 构造校验。
旧配置 `diff = { validate = ... }` 或 `session = { validate = ... }`
需改为 `render = { validate = ... }`；使用旧字段会提示迁移错误。

`chezmoi_config_path` 可指定其他 chezmoi 配置文件，支持 `~` 和相对路径；相对路径以 setup 时的工作目录为准，环境变量需通过 `vim.env` 显式读取。
`setup()` 只初始化一次，请在这次调用中传入全部配置；后续调用会报错。
修改配置后重启 Neovim。详见 `:help vimoi-setup`。

## 预览、比较与写回

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

两侧按对应行和逻辑行偏移同步；重复输出固定选择第一次执行，不保证屏幕行精确对齐。

### 比较与修改一个 hunk

执行 `:VimoiDiff` 后，使用 `[c` / `]c` 跳转差异，使用原生折叠键展开或收起上下文。
模板 diff 中的按键方向如下：

| 当前窗口 | `do`：取入当前窗口 | `dp`：送到另一侧 |
| --- | --- | --- |
| source 模板 | 将 target 的当前 hunk 写回模板 | 将当前 hunk 的渲染结果写入 target |
| target | 取入模板当前 hunk 的渲染结果 | 将当前 hunk 写回模板 |

也可执行 `:VimoiDiffPut` 将当前 hunk 送到另一侧，或执行 `:VimoiDiffGet`
将另一侧的 hunk 取入当前窗口。两侧修改都支持 undo/redo，不自动保存。
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
不更新文件属性，也不自动保存或 apply。Diff Put/Get 同样只修改 buffer 中的 hunk，
不等同于 chezmoi apply。

也可以把 vimoi 配置为 `chezmoi merge` 的编辑界面，见 `:help vimoi-chezmoi-merge`。
`chezmoi diff` 的外部接口不直接提供 source，不能照搬 merge 配置。

## 高亮与诊断

默认按真实 target 的名称和 shebang 识别宿主语言，解析完整渲染结果，再把颜色映射回模板静态文本。
未执行的分支使用 `Comment`。编辑或临时模板错误期间保留已有颜色。

| `highlight.mode` | 行为 |
| --- | --- |
| `"rendered"`（默认） | 从渲染结果映射宿主颜色；只覆盖当前数据执行的分支 |
| `"injection"` | 直接解析模板中的宿主片段；不完整语句可能高亮不准确 |
| `"disabled"` | 关闭宿主高亮，保留 gotmpl action 高亮 |

缺少宿主 parser 时，启用宿主高亮的模式回退到 Vim syntax。
`highlight.template_bg` 默认借用 `NormalFloat` 背景，可改为其他高亮组名、颜色或 `{ dark = "#123456", light = "#E4E9F4" }`。

模板诊断默认随编辑检查，无须打开 diff 或 preview。无法定位到源码的渲染错误显示在第一行，
保留原始错误文本，并注明没有对应源码位置。宿主诊断复用已有配置：
照常用 `vim.lsp.enable()` 启用语言服务器，或配置 `require("lint").linters_by_ft`，无须在 vimoi 中再列一份检查器。
插件检查渲染结果，把错误映射回 source；静态文本精确定位，动态输出指向产生它的模板区域，无法明确定位的输出跳过。
消息以 `[gotmpl]` 或 `[host:lua]`、`[host:yaml]` 等区分。

```lua
require("vimoi").setup({
  diagnostics = { enabled = true, host = false }, -- 只保留模板诊断
})
```

`diagnostics.enabled = false` 关闭诊断，显示样式通过 `vim.diagnostic.config()` 调整。
宿主检查使用未保存的渲染 buffer，nvim-lint 仅支持 stdin 检查器。
依赖精确文件名的规则（例如部分 YAML schema 关联）可能需要调整。
循环文本采用第一次执行的颜色，`define` / `block` 正文没有宿主颜色投射，可改用 injection。
完整行为与限制见 `:help vimoi-highlighting` 和 `:help vimoi-setup`。

## 补全

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

路径同步解析，不读取模板 data。多个匹配通过 picker 选择；无法解析时回退到原生跳转。对于受管理的 destination 路径，
优先打开 source。安装可选的 vim-matchup 并启用其 Tree-sitter 匹配后，可用 `%` 跳转模板控制块。

## 键位

先设置 `vim.g.mapleader`，再调用 setup。默认全局键位如下：

| 键位 | 操作 |
| --- | --- |
| `<leader>cd` | 打开 diff |
| `<leader>cp` | 打开 preview |
| `<leader>ct` | 切换 source / target |
| `<leader>ca` | ReAdd |
| `<leader>cr` | 刷新缓存 |
| `<leader>cx` | 取消任务 |

`gf` / `gF` 仅在模板及 symlink source 中启用；模板 diff 的 `do` / `dp` 和折叠映射仅在相应窗口聚焦时启用。
`[c` / `]c` 使用原生差异跳转。普通文件保留原生双文件 diff 行为。

用 `keymaps = { diff = "<leader>hd", readd = false }` 修改或关闭单个映射，`keymaps = false` 关闭全部映射。

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

## Lua API

```lua
local api = require("vimoi.api")
api.toggle()                -- source / target 切换
api.preview()               -- 预览当前模板
api.diff()                  -- 打开当前文件的 diff
api.diff_buffers(source_buf, target_buf, { filetype = "yaml" })
api.readd()                 -- target 修改写回 source buffer
api.cancel_command()        -- 取消耗时命令
```

这些是交互入口。diff/preview（包括 `diff_buffers`）返回 `nil`；写回操作等待渲染或选择时也返回 `nil`，
不能用它判断最终是否成功。参数、即时结果和其他操作见 `:help vimoi-api`。

`diff_buffers()` 支持两个不同的已加载 buffer，包括未命名和 scratch buffer；`0` 表示当前 buffer。
可选 `filetype` 指定宿主语言，比较使用当前内容，支持相同的 hunk 操作和 ReAdd。
文件对可使用 `api.diff_files(source, target)`。完整参数见 `:help vimoi-api`。

## 与 chezmoi-template.nvim 对比

两者都支持直接编辑 source、实时预览、模板与宿主高亮、blink 补全和模板跳转，但侧重点不同。
以下对比基于 [chezmoi-template.nvim 源码](https://github.com/dpezto/chezmoi-template.nvim/tree/670ba83095ba6571f3125a5e5fd4118505a2c3c6)（2026-10-25 核对）。

| 功能 | vimoi.nvim | chezmoi-template.nvim |
| --- | --- | --- |
| 比较与写回 | 模板感知的原生 diff、双向 hunk、静态 ReAdd | 预览中标出相对已部署文件的差异 |
| 宿主高亮 | 默认映射渲染结果，也可 injection | Tree-sitter injection |
| 诊断 | 编辑时模板检查，以及 LSP / nvim-lint 宿主检查 | 保存时模板执行检查 |
| 补全 | 函数、data 字段、局部变量、路径和块片段；不显示 data 值 | 函数、data 字段与值说明、敏感字段遮盖、块片段 |
| 模板格式化、目标图标、透明加密 | 未提供 | Conform、mini.icons、可选加解密 |
| 文件选择与部署 | source / target 切换，部署使用 CLI | 多种文件 picker、apply 命令，默认保存后 apply |
| 默认键位 | 全局快捷键，可关闭 | 可选的 source buffer 局部键位 |
| Neovim 要求 | 0.12+ | 0.10+ |

需要格式化、加密和部署配套时，可以考虑它；需要比较渲染结果并将实际文件的静态修改带回模板时，vimoi 更侧重这一流程。
详细实现对比与历史调研见 [插件对比](docs/plugin-comparison.md)。

## 范围与限制

- 动态或重复输出的修改通常需手动编辑 source；不提供通用反向合并或自动 ReAdd。
- `define` / `block` 正文不建立内部映射，其中的静态文本也需手动修改。
- 不支持自定义模板分隔符，或在 `chezmoi cat` 与 `apply` 下生成不同结果的模板。
- 默认 `render.validate = true` 在文件 source session 首次构造时对照 `chezmoi cat` 校验磁盘基线；失败后需重新打开文件。无名、未受管理、source-only 和 init 模板跳过该校验。
- data、共享模板等依赖变化通常自动刷新；环境、时间相关函数和未发现的目录可能需要手动刷新。
- 未提供格式化、图标、透明加密、受管理文件浏览或 apply 命令。文件属性与部署继续使用 chezmoi CLI。

诊断、预览和渲染高亮会实际执行模板函数，可能调用密码助手。耗时后台任务可取消，没有默认超时。
渲染上下文、缓存与保留标记的完整约束见 `:help vimoi-limitations`。

## 健康检查与帮助

```vim
:checkhealth vimoi
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

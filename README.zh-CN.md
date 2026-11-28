# vimoi.nvim

在 Neovim 中编辑 [chezmoi](https://www.chezmoi.io/) 模板，实时预览结果，并将 target 的静态修改写回 source，保留模板表达式。

[English](README.md) · [中文帮助](doc/vimoi.cnx)

> 项目处于 alpha 阶段，API 和行为可能变化。

## 演示

**模板感知的 diff。** 比较渲染结果与实际文件，双向传递 hunk，选择插入位置。 [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diff.mp4)

![模板 diff：同步滚动、hunk 传递和插入位置选择](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diff.gif)

**保留表达式的静态写回。** 批量把 target 修改带回模板，保留动态表达式。 [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/readd.mp4)

![静态修改写回 source，保留模板表达式](https://github.com/dirichy/vimoi.nvim/releases/download/demos/readd.gif)

**实时预览。** 编辑未保存的模板，同步滚动并查看分支变化、撤销和错误恢复。 [MP4](https://github.com/dirichy/vimoi.nvim/releases/download/demos/preview.mp4)

![实时模板预览：静态文本编辑、条件分支切换和撤销](https://github.com/dirichy/vimoi.nvim/releases/download/demos/preview.gif)

## 安装与配置

需要 Neovim 0.11+ 和 chezmoi 2.x。建议安装 `gotmpl` Tree-sitter parser，以获得完整模板高亮、更准确的语法感知补全、
模板引用跳转和模板块匹配。未安装时，实验性回退仍支持预览、diff、静态写回和基础补全：action 判断使用当前行正则，
变量补全会扫描整个 buffer，因此可能包含其他作用域的候选；模板表达式仍由 chezmoi 校验。
宿主语言 parser 可选，缺少时 rendered 高亮使用 Vim syntax。blink.cmp 只在需要 Vimoi 补全 source 时才是依赖。已在 Linux 上测试。

lazy.nvim：

```lua
{
  "dirichy/vimoi.nvim",
  lazy = false,
  opts = {},
}
```

其他插件管理器安装后调用 `require("vimoi").setup()`。
先设置 `vim.g.mapleader`；安装完成后执行 `:checkhealth vimoi`。

默认配置即可使用，按需修改选项，例如在 lazy.nvim 的 `opts` 中设置：

```lua
opts = {
  chezmoi_source_dir = "~/dotfiles", -- 使用自定义 source 目录时填写
  split = "horizontal", -- 上下分屏
  keymaps = { readd = false }, -- 关闭默认 ReAdd 映射
}
```

空白启动只保留配置、文件检测与命令入口；打开模板或执行相关操作时再加载高亮、渲染等功能。
文件检测沿用 Neovim 原生 `ftdetect`，单纯匹配文件名不初始化高亮。`setup()` 本身不运行
chezmoi，也不为建立监听而扫描 source；首次执行 chezmoi 命令
或查找共享模板时才启动监听，手动清缓存仍会重新扫描监听目录。source/target 映射在首次
缓存未命中时查询（包括打开 source 文件时），此后复用，直到缓存失效。source 目录默认取 `$XDG_DATA_HOME/chezmoi`，
配置文件默认取 `$XDG_CONFIG_HOME/chezmoi/chezmoi.toml`；对应的 XDG 变量未设置或为空时，
分别使用 `~/.local/share/chezmoi` 和 `~/.config/chezmoi/chezmoi.toml`。
自定义路径或使用 YAML/JSON 配置时，请显式填写 `chezmoi_source_dir` 和
`chezmoi_config_path`。每次调用都传入 `--source` 和 `--config`，插件不向 chezmoi 查询，
也不从配置或 wrapper 推断路径。有 `.chezmoiroot` 时，填写 `chezmoi source-path`
报告的实际 source-state 目录。

全部选项见 `:help vimoi-setup`。配置在启动时一次传入，修改后重启 Neovim。
可选插件的配置统一见[插件整合](#插件整合)。

## 使用

打开受 chezmoi 管理的 source 或 target，使用以下命令和默认快捷键：

| 命令 | 快捷键 | 用途 |
| --- | --- | --- |
| `:VimoiFiles` | `<leader>cf` | 选择受管理文件并打开 source |
| `:VimoiToggle` | `<leader>ct` | 切换 source / target，保留未保存修改 |
| `:VimoiPreview` | `<leader>cp` | 实时预览当前模板，无须保存 |
| `:VimoiDiff` | `<leader>cd` | 比较模板渲染结果与真实 target |
| `:VimoiReAdd` | `<leader>ca` | 将 target 修改批量写回 source |
| `:VimoiCancel` | `<leader>cx` | 取消耗时任务 |

`:VimoiFiles` 通过 `vim.ui.select` 列出受管理的文件和 symlink，复用你已有的 picker UI。
默认按 target 路径搜索，例如 `.config/nvim/init.lua`，选择后编辑对应 source，
再用 `:VimoiToggle` 切换 target。若习惯按 source 名搜索，可在 `setup()` 中设置
`files = { path = "source" }`（默认 `"target"`）。每次重新查询列表，遵循 chezmoi 的
ignore 规则；查询耗时较长时可用 `:VimoiCancel` 取消。

其他命令也支持指定路径，详见 `:help vimoi-commands`。
预览支持无名 buffer 和模板片段；渲染失败时保留旧结果并标记过期。
关闭任一侧窗口即可结束 diff/preview。

### 比较与写回

在 diff 中用 `[c` / `]c` 跳转差异，`zo` / `zc` 展开或收起上下文。
模板 diff 的 hunk 操作如下：

| 当前窗口 | `do`：取入当前窗口 | `dp`：送到另一侧 |
| --- | --- | --- |
| source 模板 | 将 target 修改写回模板 | 将模板渲染结果写入 target |
| target | 取入模板渲染结果 | 将 target 修改写回模板 |

使用插件的 `do` / `dp` 映射或 `:VimoiDiffGet` / `:VimoiDiffPut`；
直接使用原生 `:diffget` / `:diffput` 会复制模板源码。普通文件的 `do` / `dp` 保持原生行为。

`:VimoiReAdd` 批量写回可确定的静态修改，保留表达式；有歧义时提示选择位置。
动态输出需手动编辑 source。普通文本文件则复制 target 的全部当前内容，
包括未保存修改，替换 source 内容；可用 `u` 撤销。

**写回只修改 buffer，不自动保存或 apply。** 检查结果后用 `:write` 保存，
再用 `chezmoi apply` 部署。

![普通文件的类型识别、原生 diff 与未保存内容写回](https://github.com/dirichy/vimoi.nvim/releases/download/demos/plain.gif)

[普通文件实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/plain.mp4)

## 高亮与诊断

默认同时显示模板语法和宿主语言高亮；未执行分支显示为注释颜色。
Rendered 模式从完整渲染结果读取 Tree-sitter 或 Vim syntax 颜色，再映射到模板。
非空 `block` 正文像普通文本一样参与高亮、滚动、diff 和合并。
可通过 `highlight.mode` 改用 `"injection"`，或设为 `"disabled"` 只保留模板高亮。
`highlight.template_bg` 可调整模板 action 的背景。
Injection 模式缺少宿主 parser 时，直接在模板上使用 Vim syntax，属于尽力而为的回退。

![渲染结果高亮、未执行分支与模板 action 背景](https://github.com/dirichy/vimoi.nvim/releases/download/demos/highlighting.gif)

[完整清晰度的高亮实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/highlighting.mp4)

[Injection 高亮（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/injection.mp4) · [关闭宿主高亮（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/disabled.mp4)

模板错误随编辑检查。宿主诊断复用已启用的 Neovim LSP 或 nvim-lint 配置，
检查渲染结果并将错误映射回 source；nvim-lint 仅支持 stdin 检查器。
设置 `diagnostics.host = false` 可只保留模板诊断。
可通过 `render.debounce` 修改结构或渲染上下文变化时默认 500ms 的等待；静态文本修改会立即复用缓存骨架。
详见 `:help vimoi-highlighting` 和 `:help vimoi-diagnostics`。

![模板错误和映射回 source 的宿主诊断，以及修复过程](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diagnostics.gif)

[完整清晰度的诊断实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diagnostics.mp4)

## 补全

补全配置见[插件整合 → blink.cmp](#blinkcmp)。

补全函数、data 字段、局部变量、路径和模板块 snippet。没有 `gotmpl` parser 时，action 判断退回当前行正则，变量名从整个
buffer 搜索，因此菜单可能出现额外候选。

在 vimoi 的 setup 选项中控制值的遮盖：

```lua
require("vimoi").setup({
  completion = {
    mask = function(key)
      return key:lower():match("password") ~= nil or key:lower():match("token") ~= nil
    end,
  },
})
```

`completion.mask` 默认 `"hint"`：遮盖所有值，并附简短的 `See :help vimoi-completion-mask`。
设为 `true` 时只遮盖、不附帮助提示；`false` 展示所有值。函数收到不带前导点的完整字段路径
（如 `account.token`），返回 `true` 时遮盖该值，也不附帮助提示。
被遮盖值统一使用 `[ masked]`，对象预览中也一样。遮盖父字段也会遮盖其全部后代。
字段补全和类型仍保留。列表路径使用从 1 开始的索引，如 `accounts.1.token`。
预览会限制大小并截断；按字段名遮盖只覆盖函数匹配到的路径。
缓存的数据视图会先替换运行时字段，再提供给各个消费者。补全会基于当前受管理 buffer 复制一份数据，
填入能够确定的 source/target 上下文；值说明来自这份经过处理的 `chezmoi data`；
`.chezmoi.command`、`.chezmoi.args`、`.chezmoi.sourceFile` 和 `.chezmoi.targetFile` 等字段会显示为
`[runtime value]`，不直接展示可能过时的快照值。

![真实补全菜单：data、函数、局部变量、路径与块 snippet](https://github.com/dirichy/vimoi.nvim/releases/download/demos/completion.gif)

[完整清晰度的补全实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/completion.mp4)

## 路径跳转

模板及 symlink source 中的 `gf` 支持 include、共享模板、glob 和 symlink 路径；
`gF` 还支持 `path:line[:column]`。多个匹配通过 picker 选择，有本地 source 的 target 优先打开 source。
source/target 跳转按文件名解析，不下载 externals，也不执行 ignore 规则。
修改配置或文件属性后，如果已有映射过时，可按 `<leader>cr` 手动刷新。
模板控制块的 `%` 匹配可通过 [vim-matchup 整合](#vim-matchup) 启用。
路径规则见 `:help vimoi-navigation`。

![切换 source/target 保留未保存修改，gf/gF 跳转及 vim-matchup 块匹配](https://github.com/dirichy/vimoi.nvim/releases/download/demos/navigation.gif)

[路径跳转与切换实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/navigation.mp4)

## 取消任务与刷新

后台任务持续 1000ms 后显示进度。静态文本修改会立即复用缓存的骨架恢复；模板结构或渲染上下文变化时使用 500ms 防抖。
进度显示前也可用 `:VimoiCancel` 或 `<leader>cx` 取消任务。
聚焦的等待浮窗中也可按 `q`、`Esc` 或 `Ctrl-C`。取消待处理的写回后不会继续修改文件。

![取消真实的耗时渲染后继续编辑并重新预览](https://github.com/dirichy/vimoi.nvim/releases/download/demos/cancel.gif)

[任务取消实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/cancel.mp4)

data、配置和已发现的共享模板变化后自动刷新。若结果未更新，按 `<leader>cr` 手动刷新。
模板执行可能调用密码助手，等待期间可以取消，没有默认超时。

![修改共享模板和配置数据后刷新已有预览](https://github.com/dirichy/vimoi.nvim/releases/download/demos/dependencies.gif)

[完整清晰度的依赖刷新实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/dependencies.mp4)

## 模板格式化

执行 `:VimoiFormat`，或调用 `require("vimoi.api").format()`，按控制块层级整理行首
的单行标签，包括赋值、变量输出、函数和 `template` 调用，以及控制标签。
标签后可以有文本，只调整每行第一个标签：

```gotmpl
{{- if .enabled }}
  {{- $items := .items }}
  {{- range $items }}
{{     .name }}: enabled
  {{- end }}
{{- end }}
```

需要 `gotmpl` Tree-sitter parser。带左 trim 的 `{{- … }}` 使用标签外部缩进，
内部表达式前保留一个空格；其他标签保留原有外部空白，仅在内部补足目标层级
尚缺的缩进。总缩进按“外部显示宽度 + 内部额外空格”计算，不计表达式前必需的
一个分隔空格。外部缩进已超过目标时，内部只留分隔空格，不删外部空白。
tab 宽度遵循该 buffer 的 `tabstop` / `vartabstop`。仅带右 trim 的
`{{ … -}}` 不使用外部缩进。宽度遵循当前 buffer 的 `shiftwidth`（为 0 时取
`tabstop`），始终使用空格。不改换行、输出文本、trim 标记、表达式和注释。
行首有宿主文本时、同一行后续的标签及多行标签均跳过。注释内容和内部间距保持原样；
单行注释仅在带左 trim 时调整外部缩进。Tree-sitter 检出语法错误时拒绝修改。
不执行模板、不格式化宿主语言、不自动保存；一次撤销可恢复。
此命令不设默认快捷键，也不接管 `=` 或 `gq`。

Conform 配置见[插件整合 → conform.nvim](#conformnvim)。

![控制标签格式化、撤销和重做，预览输出保持不变](https://github.com/dirichy/vimoi.nvim/releases/download/demos/format.gif)

[格式化演示（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/format.mp4)

## 插件整合

以下插件均为可选依赖，按需安装，并将配置合并到各插件的现有配置中。

### blink.cmp

使用 [blink.cmp](https://github.com/Saghen/blink.cmp) 时，注册 Vimoi 补全 source：

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

`blocked_filetypes` 防止补全模板函数时自动添加圆括号。
补全能力和值遮盖选项见[补全](#补全)。

### vim-matchup

安装 [vim-matchup](https://github.com/andymass/vim-matchup)，并在其加载前启用
Tree-sitter 匹配：

```lua
vim.g.matchup_treesitter_enabled = true
```

需要 `gotmpl` Tree-sitter parser。Vimoi 提供模板块匹配查询，`%` 可在
`if` / `else` / `end`、`range`、`with`、`define` 和 `block` 之间跳转。

### conform.nvim

接入 [conform.nvim](https://github.com/stevearc/conform.nvim)，将以下配置合并到现有
Conform 配置中：

```lua
require("conform").setup({
  formatters_by_ft = {
    gotmpl = { "vimoi" },
  },
  formatters = {
    vimoi = require("vimoi.conform"),
  },
})
```

之后继续使用 `require("conform").format()` 或已有格式化快捷键；保存时格式化遵循
Conform 的 `format_on_save` 配置。无需额外可执行文件。
与 `:VimoiFormat` 使用相同的模板标签缩进规则，不格式化宿主语言。
具体行为和演示见[模板格式化](#模板格式化)。

## Lua API

`require("vimoi.api").diff_buffers(source_buf, target_buf, { filetype = "yaml" })`
可比较两个已加载的 buffer，包括无名和 scratch buffer，支持相同的 hunk 操作和 ReAdd。
全部 API 见 `:help vimoi-api`。

![两个未命名 scratch buffer 的上下分屏、hunk 写回、撤销和 ReAdd](https://github.com/dirichy/vimoi.nvim/releases/download/demos/buffers.gif)

[Buffer API 与上下分屏实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/buffers.mp4)

## 与 chezmoi-template.nvim 对比

两者都支持直接编辑 source、实时预览、模板与宿主高亮、blink 补全和模板跳转，但侧重点不同。
以下对比基于 [chezmoi-template.nvim 源码](https://github.com/dpezto/chezmoi-template.nvim/tree/670ba83095ba6571f3125a5e5fd4118505a2c3c6)（2026-10-25 核对）。

| 功能 | vimoi.nvim | chezmoi-template.nvim |
| --- | --- | --- |
| 比较与写回 | 模板感知的原生 diff、双向 hunk、静态 ReAdd | 预览中标出相对已部署文件的差异 |
| 宿主高亮 | 默认映射渲染结果，也可 injection | Tree-sitter injection |
| 诊断 | 编辑时模板检查，以及 LSP / nvim-lint 宿主检查 | 保存时模板执行检查 |
| 补全 | 函数、data 字段、局部变量、路径和块片段；可选 data 值说明与过滤 | 函数、data 字段与值说明、敏感字段遮盖、块片段 |
| 模板格式化 | 行首标签缩进，保留输出文本 | Conform 宿主格式化及指令缩进 |
| 目标图标、透明加密 | 未提供 | mini.icons、可选加解密 |
| 文件选择与部署 | 受管理文件选择、source / target 切换，部署使用 CLI | 多种文件 picker、apply 命令，默认保存后 apply |
| 默认键位 | 全局快捷键，可关闭 | 可选的 source buffer 局部键位 |
| Neovim 要求 | 0.11+ | 0.10+ |

需要格式化、加密和部署配套时，可以考虑它；需要比较渲染结果并将实际文件的静态修改带回模板时，vimoi 更侧重这一流程。
详细实现对比与历史调研见 [插件对比](docs/plugin-comparison.md)。

## 范围与限制

- 动态、重复输出及 `define` 正文中的修改通常需要手动编辑 source。
- 不支持自定义模板分隔符，或在 `chezmoi cat` 与 `apply` 下产生不同结果的模板。
- source 模板和渲染结果须为合法 UTF-8 文本。
- 加密文件、symlink 和脚本 source 不支持普通文本 ReAdd。
- 不提供宿主语言格式化、图标、文件浏览或 apply 命令，部署继续使用 chezmoi CLI。
- 不提供 chezmoi 加密 source 的透明编辑。若只需保护仓库内容，更推荐 [git-crypt](https://github.com/AGWA/git-crypt)：解锁后的模板可直接编辑，本地工作区以明文落盘。参见 [chezmoi 透明加密说明](https://www.chezmoi.io/user-guide/encryption/transparent/)。

更多限制见 `:help vimoi-limitations`。

## 帮助

执行 `:checkhealth vimoi` 检查环境，`:help vimoi.nvim@cn` 查看完整中文帮助。
[录制演示](docs/demos/README.md) · [开发文档](docs/module-responsibilities.md) · [功能规划](FEATURES.md)

## License

[MIT](LICENSE)，Copyright (c) 2026 dirichy。

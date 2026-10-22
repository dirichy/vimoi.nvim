# vimoi.nvim

在 Neovim 中安全、顺手地编辑由 [chezmoi](https://www.chezmoi.io/) 管理的文件。

[English documentation](doc/vimoi.txt) · [中文帮助](doc/vimoi.cnx)

> 项目处于 alpha 阶段，API 和行为仍可能调整。

## 目标

- 用户仍然编辑原本的目标文件，保留正常的 LSP、formatter 和项目上下文。
- 保持 chezmoi 的 source 与 target 分离；写回由用户手动触发，不做保存后自动 re-add。
- 模板等无法安全反向同步的文件采用显式、安全的 source 编辑流程。
- 尽可能复用 chezmoi CLI，不重复实现其模板和加密逻辑。
- 耗时操作可取消；写回结果、失败和需要用户决定的位置会明确提示。
- 默认保持轻量，模板功能需要 gotmpl parser，不强制依赖其他 Neovim 插件。

## 要求

- Neovim 0.12+
- chezmoi 2.x（可执行文件需位于 `PATH` 中，或通过配置指定）
- 模板功能需要安装 `gotmpl` Tree-sitter parser；目标语言 parser 可选，缺少时使用 Vim syntax 高亮。

已在 Linux、Neovim 0.12.6 和 chezmoi 2.73.3 上测试；其他平台尚未验证。

## 安装

使用你偏好的插件管理器安装，然后调用 `setup()` 完成所有命令、文件类型和事件注册：

lazy.nvim：

```lua
{
  "dirichy/vimoi.nvim",
  opts = {},
}
```

其他插件管理器安装 `dirichy/vimoi.nvim` 后手动配置：

```lua
require("vimoi.api").setup()
```

进程/config 路径、watch 和 keymaps 在首次成功 setup 后固定；后续调用省略它们时
保留原值，修改时会报错。split、completion、diagnostics、diff.validate 和 highlight 可以更新，省略时恢复默认值。

使用 lazy.nvim 时，`opts = {}` 会自动调用 `setup()`。也可以设置 `ft = "gotmpl"`：
lazy.nvim 会提前读取本插件的 `ftdetect/`；遇到候选模板路径时才加载 Lua 模块并
执行 `setup()`，因此自定义的 `chezmoi_executable` 也会在路径确认前生效。
只用 `ft = "gotmpl"` 时，普通 source 不会触发首次加载；希望直接打开普通 source 即按
target 识别文件类型，应提前 setup，而非只依赖该 filetype 触发。

## 快速开始

安装 gotmpl parser 并完成 setup 后，先运行 `:checkhealth vimoi` 检查环境。

| 命令 | 用途 |
| --- | --- |
| `:VimoiToggle` | 在受管理文件的 source 和 target 间切换 |
| `:VimoiPreview` | 使用未保存的模板内容预览只读结果 |
| `:VimoiDiff` | 比较 source 与 target；模板使用渲染结果投影差异 |
| `:VimoiReAdd` | 将 target 中可映射的静态修改写回模板 buffer |
| `:VimoiCancel` | 取消正在执行的耗时命令 |

在模板 diff 中，target 窗口的 `dp` 把当前 hunk 写回模板；source 窗口的 `dp`
把当前 hunk 的渲染结果写入 target。两者都不自动保存，也不执行 chezmoi apply。
普通文件使用原生双文件 diff；`VimoiReAdd` 只支持模板。

模板诊断默认启用，会实际执行模板函数，可能调用密码助手。可通过
`diagnostics = { enabled = false }` 关闭。渲染限制请先阅读下文的「模板渲染限制」。

## 配置与 API

用户日常调用的 Lua 接口位于 `require("vimoi.api")`：配置、预览、打开 diff、合并 hunk、
同步折叠和路径跳转。补全由 `vimoi.blink` 提供，目前只集成 blink.cmp；
只有 `setup`、帮助文档列出的 `vimoi.api` 操作和 `vimoi.blink` 集成属于公开接口；
其余模块、session 表和调试数据均为内部实现。

`diff`、`diff_files`、`preview` 始终返回 `nil`，模板渲染异步完成，不返回 session。
`toggle` 成功返回打开的路径。`put_hunk` / `apply_hunk` / `readd` 只有立即完成时才返回结果；
等待渲染或选择时也返回 `nil`，因此不能用它判断最终是否成功。这些是交互入口，
目前不提供供脚本等待完成的回调或 promise；详细参数和返回值见 `:help vimoi-api`。

内部任务调度与模块职责见中英文帮助；这些内部接口不属于用户 API。

## 缓存和耗时命令

chezmoi 路径查询、data 和模板结构渲染会缓存，静态文本在本地恢复。配置文件和已发现的 data 文件变化
会自动清空缓存，包括编辑器外的修改；需要手动刷新时，可调用
`require("vimoi.api").invalidate_cache()`，同时重新扫描文件监听范围。
`.chezmoitemplates` 及已发现的子目录修改会自动清空模板结果，支持 `includeTemplate`
内容更新；不会清空路径/data。也可手动调用 `invalidate_cache("templates")`。
模板、data 或配置失效后，已打开的 diff/preview 也会自动延迟刷新，包含其他 tab 的视图；
初次渲染仍在进行时由已有重试逻辑处理，不会自动写回 source 或 target。
其他 scope 为 `"paths"`、`"data"`（同时清空依赖模板）、`"all"`（默认）。
`.chezmoiignore` 修改只清空路径缓存；不再泛匹配所有 `.chezmoi*` 文件名。
`watch.buffer_write_fallback = "auto"`（默认）只在父目录监听失败或未覆盖时用
`BufWritePost` 兜底，避免正常保存重复失效。某些远程文件系统可能启动成功但静默丢事件，
此时可设为 `true` 强制兜底；`false` 则禁用。兜底只覆盖当前 Neovim 的保存。

`data`、`cat` 和用户模板渲染等可能等待密码的命令没有默认超时。后台调用在右上角显示不抢焦点的
进度浮窗；需要等待结果的操作使用异步进程配合聚焦浮窗，等待期间 Neovim 仍能响应输入。
在浮窗中按 `q`、`Esc`、`Ctrl-C` 或关闭浮窗可取消；离开聚焦浮窗也会取消。
后台命令可用 `:VimoiCancel`、`api.cancel_command()` 或 `<leader>cx` 取消命令；只有一项时直接取消，多项时通过 picker 选择。
取消会结束进程（Unix 下包括同一进程组的子进程），不会继续执行待处理的写回。
路径和配置路径查询等快速命令仍直接执行。模板 diff 的 put/apply/re-add 等待渲染时
使用同一套浮窗；取消初次渲染会结束该 session，两侧 buffer 保留。

## 默认键位

默认普通模式映射如下；全局入口可从 target 或 source buffer 调用：

| 按键 | 功能 | 范围 |
| --- | --- | --- |
| `<leader>cd` | 打开 diff | 全局 |
| `<leader>cp` | 打开模板预览 | 全局 |
| `<leader>ct` | 在 source 与 target 间切换 | 全局 |
| `<leader>cr` | 清理缓存并重新扫描监听 | 全局 |
| `<leader>ca` | 将 target 修改写回模板 | 全局 |
| `<leader>cx` | 选择并取消耗时命令 | 全局 |

设置 `vim.g.mapleader` 后再调用 setup。下面列出默认值；任一项改成字符串可换键，
设为 `false`（或空字符串）可单独关闭，`keymaps = false` 可关闭全部映射。
`gf` / `gF` 只在模板和 symlink source 中启用；`do` / `dp` 和折叠键只在模板 diff
窗口聚焦时启用，离开窗口即恢复原有 buffer 映射：

```lua
require("vimoi.api").setup({
  chezmoi_executable = "chezmoi", -- 也可以是可执行的 wrapper 路径
  chezmoi_config_path = nil, -- 可选；指定后所有命令统一传入 --config
  split = "vertical", -- "horizontal" 在上下分屏中打开 diff/preview
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

例如只调整两个入口，其余保留默认值：

```lua
require("vimoi.api").setup({
  keymaps = { diff = "<leader>hd", readd = false },
})
```

使用自定义配置时，设置 `chezmoi_config_path = "~/path/to/chezmoi.toml"`。
未设置时由 chezmoi 自动查找，插件只在 setup 时查询一次配置路径。
支持 `~` 和相对路径；相对路径以 setup 时的工作目录为准。路径中的 `$` 按字面保留，
不展开环境变量；需要时请显式使用 `vim.env`，例如
`chezmoi_config_path = vim.env.MY_CHEZMOI_CONFIG`（需先设置该环境变量）。

文件监听是 best-effort：监听 setup 或手动刷新时发现的 data/模板目录及相关父目录。
新建、移动目录，文件系统不支持监听，或环境变量变化时，可能需要手动调用
`require("vimoi.api").invalidate_cache()`。source root 和 init 模板映射仍固定为 setup
时的值。

## 模板诊断

所有 gotmpl buffer 默认提供原生 Neovim diagnostics，无须打开 diff 或 preview：编辑后
等待 300ms，先显示 Tree-sitter 语法错误，语法有效时异步检查哨兵骨架。原生补全菜单显示时
的编辑也会检查。只检查模板语法，
不将宿主语言 injection 的解析错误当成模板错误，也不修改其他 LSP 的诊断。

静态文本修改复用当前骨架的成功或失败结果，只更新错误位置；tag 或 data/include 等依赖
变化才重新检查。骨架和已完成的渲染缓存与 diff/preview 共用，相同骨架的并发缓存请求
合并为一个进程；关闭视图或禁用诊断只释放该使用方。显式等待浮窗的取消和全局取消会终止共享进程。
错误通过 tag 在骨架中的 byte 偏移映射回原始 source，支持 UTF-8 和多行 tag；无法可靠
定位的错误以通知展示。过期结果丢弃，取消任务不产生模板错误。

检查会实际执行模板函数，可能调用密码助手；使用相同的可取消后台任务，没有默认超时。
init 模板使用 --init，空 define/block 等哨兵限制保持一致。可关闭或重新启用：

```lua
require("vimoi.api").setup({ diagnostics = { enabled = false } })
```

运行时关闭会清除插件诊断并释放待处理检查；重新启用会检查已打开的模板。
样式使用 `vim.diagnostic.config()` 调整，插件 namespace 为 `vimoi-diagnostics`。

## 环境检查

执行 `:checkhealth vimoi` 检查 Neovim 版本、配置的 chezmoi 可执行文件、setup 已发现的
source/config 路径、gotmpl parser 与 highlights/injections 查询。打开模板后，还会检查该
模板已配置的可选宿主语言 parser（读取现有状态，不重新推断文件类型）；缺少时回退到 Vim syntax，不影响 gotmpl source map。

健康检查不会自动 setup、启动 chezmoi、读取 data、渲染模板或修改文件，也不会触发密码输入。
未完成 setup 时会提示路径尚未发现；配置文件只检查存在性和可读性，不验证配置内容。
未显式指定的默认 config 文件可以不存在。setup 失败时请结合启动错误排查，报告使用最近
一次成功配置或默认值，不会重新执行失败的初始化。

## blink.cmp 模板补全

插件提供可选的 blink.cmp source，不设置 `omnifunc`，也不要求原生补全适配层：

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

`gotmpl` 函数使用空格传参而不是 `()`。上面的 `blocked_filetypes` 使用 blink.cmp
原生配置阻止接受 `Function` 候选时自动添加括号，同时保留正确的函数类型和图标。

该 source 只在 `gotmpl` buffer 中启用，补全常用模板函数、`chezmoi data` 字段、
当前 buffer 声明的 `$variable`，以及 `include`、`includeTemplate`、`template`、
`glob` 的路径。data 首次异步加载后会缓存，候选说明不会展示其值。
action 外提供 `if`、`ifelse`、`range`、`with`、`define`、`block` 和 `comment` snippet，
展开为带占位符的完整模板结构；复用 blink 的 snippet 引擎，不在模板注释中提供候选。

完整使用说明可以在 Neovim 中查看：

```vim
:help vimoi.nvim
```

项目同时提供中英文 help。Neovim 会按照 `'helplang'` 自动选择语言：

```vim
set helplang=cn
:help vimoi.nvim
:help vimoi.nvim@en
:help vimoi.nvim@cn
```

## 模板预览

编辑 source 模板时执行 `:VimoiPreview`，或执行 `:VimoiPreview /path/to/source.tmpl`。
左侧继续编辑模板，右侧显示只读的临时渲染结果；使用当前 buffer 的未保存内容，也支持
未命名 buffer 和没有独立 target 的模板片段。不会读取或写入真实 target，也不会自动保存、
re-add 或 apply。Lua API 为 `require("vimoi.api").preview({ source = "/path/to/source.tmpl" })`，
省略参数则使用当前模板；在已有 diff/preview 的任一侧调用时使用该 session 的 source。

预览复用 diff 的异步渲染、120ms debounce、增量语法缓存和 source map 光标/滚动同步。
静态修改复用已渲染结构，结构变化才按需调用 chezmoi。结果使用宿主语言高亮，不启用
diff 高亮、filler、diff 折叠或合并按键。渲染失败保留上次成功结果并标明已过期，修复后
自动恢复。`diff.validate` 不适用于未保存内容的预览；其余渲染限制与下节相同。

重复执行 diff/preview 或互相切换时，都会复用当前 session 的双窗口。
Session 按窗口绑定，同一 buffer 在其他窗口/tab 中可以有独立视图；文本修改仍会更新
所有共享该 buffer 的视图。关闭或替换任一侧后停止
更新；关闭结果窗口时临时 buffer 自动清理。data/include 等已监听的外部输入变化后自动刷新；
监听漏掉变化或新增目录时，可调用 `invalidate_cache()`，无需再次执行 Preview。
`split = "horizontal"` 可改为 source 在上、结果在下；默认 `"vertical"` 左右分屏。
该选项同时用于 diff，普通文件 diff 也适用；只影响新建分屏，不重新排列已复用的窗口。

## 模板渲染限制

初次打开先显示 source/target 双窗口，再异步渲染和校验；等待时可以继续编辑、切换 tab
或关闭窗口，结果就绪后才启用 diff。完成不会抢焦点；diff 和 preview 中任一侧重命名
或被替换后，旧的刷新和合并结果都会丢弃。

插件使用 `chezmoi execute-template` 渲染注入哨兵的临时模板，以建立 source 与 rendered
ranges 的对应关系。当前支持 `{{-` / `-}}` whitespace trim；自定义 template delimiter
暂不支持。`.chezmoi.{toml,yaml,yml,json,jsonc}.tmpl` 会被映射到 `.chezmoi.configFile`，并使用
`execute-template --init` 渲染。
相邻 template action 之间即使没有静态文本，也有独立哨兵记录该槽位是否执行，以及执行
次数和输出位置；这用于判断空 `if`、`else`、`range` 边界上的合并候选。
同一套静态文本槽位也用于 diff 投影、merge 和滚动映射，不依赖 parser 对普通文本的
节点拆分。槽位内部的裸括号修改会自动转义，不会仅因节点边界而弹出位置选择。
静态文本（包括 trim 后的空白）在本地恢复，只有新模板结构才需要重新渲染；刷新保留
120ms debounce。缓存包括动态结果，data、include 或环境变化后可能需要调用
`require("vimoi.api").invalidate_cache()`；不会保证自动发现所有外部依赖。
不支持依赖纯空白/注释的空 `define` 或 `block` 被忽略、再定义等特殊语义：非空哨兵
会改变 Go 对空定义的判断。普通空 `if`、`range` 和 whitespace trim 不受此限制。

哨兵采用本次模块加载时生成的随机前缀，完整标记为 `prefix .. ID .. prefix`。
当前实现保守地拒绝任何包含该前缀的源码。静态文本本身其实不会引发误解码：它在渲染前
被替换，还原时不会再次扫描；只是当前源码检查尚未区分静态文本和模板标签。
模板表达式、data 或 include 等产生的动态输出不能包含当前完整标记：未知 ID 会报错，
有效 ID 则可能被误替换，导致输出或位置映射错误。动态输出仅含前缀不会触发替换。
随机前缀降低偶然碰撞的可能性，但不保证任意动态输出都不会冲突。

当前 sentinel MVP 不支持依赖以下执行上下文的模板：

- `.chezmoi.sourceFile`
- `.chezmoi.targetFile`
- `.chezmoi.command`
- `.chezmoi.args`
- 间接读取上述字段的 `includeTemplate`

检测与降级策略见 [render environment compatibility](docs/render-environment.md)。

## 三文件 diff

在 chezmoi 管理的真实目标文件或 source state 文件中执行：

```vim
:VimoiDiff
```

插件会自动判断当前路径位于 destination 还是 chezmoi source directory，并分别通过
`chezmoi source-path` 或 `chezmoi target-path` 找到另一侧。已加载 buffer 会直接复用，
因此从 source template 调用时不会丢失尚未保存的修改。

界面只显示真实目标文件和 source template。插件在后台生成第三份 rendered base，
先将 `Rendered Base -> Modified Target` 的 hunk 投影到模板，再交给 Neovim 原生 diff
显示。两侧都会使用原生 `DiffAdd` / `DiffChange` / `DiffDelete` 高亮，并获得原生的
filler lines、`foldmethod=diff` 以及 `[c` / `]c` 跳转。光标和 viewport 使用 sentinel
source map 同步，以正确处理条件与循环展开；session 内会禁用 Snacks smooth scroll，共享 buffer 的最后一个视图关闭后恢复。
开启严格校验时，sentinel 渲染与真实 `chezmoi cat` 结果不一致会
拒绝显示可能错误的映射。

静态 hunk 写回模板时，目标中的字面量 `{{` 会转义为输出该文本的 Go template
字符串 action；删除或相邻修改拼出的 `{{` 也会转义，其他文本仍保持静态。
输出和新 source map 根据原有执行记录直接推算，不额外渲染。仅局部写回；一次 `dp` 或 template re-add 的多处修改可一次 undo/redo。
`dp` 后不再强制收起全部折叠，折叠范围和打开状态由 Neovim 原生机制更新。

diff session 会为 `zo`、`zc`、`za`、`zO`、`zC`、`zA`、`zR` 和 `zM` 安装 buffer-local
映射。单个 fold 命令先通过 source map 找到另一侧对应行，再同步执行；全局 fold 命令则
直接作用于两个窗口。

source template 使用 `gotmpl` filetype 和 parser。普通 `text` 节点会通过 Tree-sitter
injection 按宿主语言组合解析，例如 `init.lua.tmpl` 同时使用 gotmpl 与 Lua 高亮，
`.chezmoiexternal.toml` 使用 TOML，`.chezmoiignore` 和 `.chezmoiremove` 借用
`gitignore` 高亮。脚本会结合 shebang 判断宿主语言，例如 `.sh.tmpl` 中的
`#!/usr/bin/env zsh` 使用 zsh。目标语言没有可用 parser 时，宿主文本回退到 Vim syntax 高亮。
自动识别 `gotmpl` 仅限 chezmoi source 目录，不会影响其他位置的同名文件。
普通模板优先通过 chezmoi 的缓存路径查询取得真实 target 名称，因此 `dot_zshrc.tmpl`
也能识别为 zsh，无需 target 已存在；无法解析 target 时回退到 source 文件名和内容。
普通 managed source 也按 target 判断文件类型，例如 `dot_zshrc`、`private_dot_bashrc`；
保留 Neovim 的文件类型初始化回调。特殊文件与 symlink source 保留自身的识别规则。
模板的 `{{ ... }}` 部分会统一加上背景色；可通过 `highlight.template_bg` 指定单一颜色，
或分别设置深色、浅色主题的颜色，不影响原有语法前景色。

ignore/remove 借用的是高亮规则，不代表 chezmoi 的模式匹配语义与 Gitignore 完全一致。

这是尽力而为的语法高亮：模板表达式可能生成宿主语言的关键 token，条件分支可能分别
包含不完整语句，循环也可能生成列表项或代码块。`injection.combined` 可以组合静态片段，
但无法知道模板运行后的真实源码，因此宿主 parser 仍可能产生错误节点、缺失高亮或错误
高亮；这不会影响 gotmpl 解析、diff source map 或最终 chezmoi 渲染。

非模板 source 文件不会进入 sentinel 或三文件投影流程，而是直接打开 source 与 target
并使用 Neovim 原生双文件 diff，包括原生 `scrollbind`、`cursorbind` 和 `do` / `dp`。

在目标窗口把光标放在 hunk 上按 `dp`，或在模板窗口按 `do`，可以把当前 hunk 写入
source template；也可以显式执行 `:VimoiDiffPut`。写入后插件会推算新映射并刷新
剩余 diff。行级 hunk 会继续拆成独立的字节级编辑，因此同一行跨多个静态槽位的增删改
可以一次合并；无法映射到非重复静态文本的编辑仍会保留手动处理，避免损坏模板控制结构。

反方向，在 source 窗口按 `dp`，或在 target 窗口按 `do`，会把当前 hunk 的**渲染结果**
写入 target，不会复制模板源码；也可执行 `:VimoiDiffApply` 或 `api.apply_hunk()`。
动态输出和循环展开同样支持；只改当前 hunk，其余 target 修改保留。两种方向都局部写入，
支持 undo/redo，不自动保存文件。`diff_get` 和 `diff_put` 分别配置两侧的 `do`、`dp`。
这些语义由映射和插件命令提供；原生 `:diffget` / `:diffput` 或 `normal!` 绕过映射时，
仍会直接操作模板源码。

put、apply 或 template re-add 需要渲染时（首次渲染或 source map 过期），会
打开等待窗口，异步完成后继续合并。等待时按 `q`、`Esc`、`Ctrl-C` 或关闭窗口可取消；离开等待窗口也会取消。
put/apply 保留触发时的光标行。若等待或选择期间两侧文本、session 或渲染上下文变化，也会
取消本次合并，旧回调不能写入新状态。

执行 `:VimoiReAdd [path]`（或 `api.readd(path)`）可以把 target 的修改
写回模板。path 可指定 source 或 target，省略时使用当前 buffer。已有 diff session
会直接复用；否则自动打开 diff，等待初次渲染后继续。也可从只读预览切换过来。
它会一次写回所有能映射到静态文本的 hunk，只修改 source buffer，不自动保存；
无法确定的 hunk 会保留供手动处理。在 `if`、`range` 或 `with` 块结尾插入内容时，
插入点可能位于块内，也可能位于块外；即使当前结果相同，插件也会列出位置让用户选择。
空 `if` 最多会提供块前、块内、块后三个候选；行内控制 action 也使用相同的候选枚举。
候选位置根据已记录的槽位执行次数、顺序和 trim 规则推算。选定后直接重建映射，
包括字面 `{{` 转义产生的常量字符串 action，不再渲染候选或核对完整预期输出。
修改已有控制结构或动态输出仍需手动处理。静态槽位内部的插入不受此限制。
例如把渲染行 `ooo` 改成 `ooouuu`，即使 diff 将其表示为整行替换，也会识别出新增的
`uuu`，并在相邻 `{{ end }}` 两侧提供插入位置。
反过来从 `ooouuu` 删除 `uuu`，或把 `uuu` 改成 `www`，若旧字节只对应一个非重复静态
槽位，就直接应用；多个不同静态槽位都能解释同一编辑时才提示选择。
同一行有多处变化时，每一处独立定位；`dp` 会把整个 hunk 作为一组提交。
手动编辑目标或模板 buffer 时也会延迟重新渲染并更新投影 diff，不会退回普通的
source-vs-target diff。

刷新会优先走增量路径：修改目标文件只重新计算 diff hunks；修改模板时先检查 gotmpl
语法树与字节变化范围，局部更新 action 边界。静态文本、trim 空白、重复展开区域或多个
静态槽位的修改都可以复用结构渲染，在本地恢复 source map 和 rendered base。
新的、未缓存的 action 序列才会重新调用 `chezmoi execute-template`。
编辑事件本身不会同步刷新 diff：连续修改会经过 debounce，模板重渲染通过异步进程完成，
过期的渲染结果会被丢弃。最终的原生 filler、fold 和 highlight 更新仍需回到 Neovim 主线程。

也可以手动指定 source template 和目标文件，方便测试或集成其他工作流：

```vim
:VimoiDiff /path/to/source.tmpl /path/to/target
```

```lua
require("vimoi.api").diff_files("/path/to/source.tmpl", "/path/to/target", {
  validate = false,
})
```

默认只执行一次 `execute-template`，并将移除哨兵后的结果作为 rendered base。对于已经声明
不支持的 chezmoi 上下文字段，可以开启严格校验；这会额外执行一次 `chezmoi cat`：

```lua
require("vimoi.api").setup({
  diff = {
    validate = true,
  },
})
```

调试时可通过 `require("vimoi.gotmpl.session").last_profile` 查看最近一次打开 diff 或预览的分阶段耗时。

## 路径跳转

`:VimoiToggle [path]` / `api.toggle(path)` 在 source 与 target 间切换，不必进入 diff。
省略 path 时打开当前文件的另一侧；显式传入时打开该路径的另一侧。预览结果窗口切回所属
source，source 窗口则打开真实 target。没有对应文件的 source-only 片段会报错。
它不渲染、apply 或自动保存，保留 Neovim 对未保存 buffer 的正常保护。

在 gotmpl、`.chezmoitemplates` 以及 chezmoi 特殊路径文件中，插件会设置 buffer-local
`gf`：

| 位置 | 路径基准 |
| --- | --- |
| `include "path"` | chezmoi source directory |
| `template "name"` / `includeTemplate "name"` | source state 中的 `.chezmoitemplates` |
| `glob "pattern"` | destination directory |
| `.chezmoiignore{,.tmpl}` / `.chezmoiremove{,.tmpl}` | destination directory |
| `symlink_*` 内容 | 生成的 symlink 所在目录 |
| 绝对路径、`~` 路径和 `file://` URL | 文件系统中的对应路径 |

通配符或多个 `.chezmoitemplates` 产生多个匹配时，通过 `vim.ui.select` 选择。无法确认是
chezmoi 路径或者没有找到文件时，会回退到 Neovim 原生 `gf`。

`gF` 使用相同的路径规则，并额外识别 `path:line` 和 `path:line:column`；没有位置后缀时
与增强版 `gf` 相同。对应 API 是 `goto_file({ line = true })`。异步查询或 picker 等待期间，
若发起窗口被关闭/替换、当前窗口切换或原 buffer 内容变化，跳转结果会丢弃。

对于从 destination directory 得到的路径，插件会优先调用 `chezmoi source-path` 跳到
source state，避免直接修改之后会被 chezmoi 覆盖的真实配置。目标未受管理或没有实体
source（例如 ignore/remove 中的路径）时，才打开 destination 中的实际路径。

安装可选的 [vim-matchup](https://github.com/andymass/vim-matchup) 并启用其 Tree-sitter
匹配后，可用 `%` 跳转 if/else/end、range、with、define 和 block，支持 trim 和 else 链。
插件只提供 gotmpl 查询，不自行覆盖 `%`，未安装 vim-matchup 时保留原生行为。

## 功能规划

详见 [FEATURES.md](FEATURES.md)。

## 开发检查

安装上述依赖后，运行 `python3 tests/run.py` 执行测试，也可追加测试文件名，例如
`python3 tests/run.py public_api.lua`。需要 Python 3 和 Unix shell；每个测试使用独立的
chezmoi 配置、target 和状态数据库，不加载个人 Neovim 配置。parser 需已安装且可从
Neovim 的 runtimepath 找到。性能测试单独运行，见 [性能对比](docs/preview-benchmark.md)。

格式检查：`stylua --check lua ftdetect tests`。LuaLS 检查应包含真实的 Neovim runtime
library，并保留全部诊断等级；不要通过关闭诊断使检查通过。

局部写入的性能、边界处理和测试说明见 [局部写入实测](docs/buffer-edits.md)。

## License

[MIT](LICENSE)，Copyright (c) 2026 dirichy。

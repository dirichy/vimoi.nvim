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

需要 Neovim 0.11+ 和 chezmoi 2.x。完整模板高亮、语法感知补全和模板引用跳转需要 `gotmpl` Tree-sitter parser。
未安装时，实验性回退支持预览、diff 和静态写回；模板表达式仍由 chezmoi 校验。
宿主语言 parser 可选，缺少时 rendered 高亮使用 Vim syntax。已在 Linux 上测试。

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
  split = "horizontal", -- 上下分屏
  keymaps = { readd = false }, -- 关闭默认 ReAdd 映射
}
```

全部选项见 `:help vimoi-setup`。配置在启动时一次传入，修改后重启 Neovim。

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

`:VimoiFiles` 通过 `vim.ui.select` 列出受管理的文件和 symlink source，复用你已有的 picker UI。
选择后编辑 source，再用 `:VimoiToggle` 切换 target。每次重新查询列表，遵循 chezmoi 的 ignore 规则。
查询耗时较长时可用 `:VimoiCancel` 取消。

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
可通过 `highlight.mode` 改用 `"injection"`，或设为 `"disabled"` 只保留模板高亮。
`highlight.template_bg` 可调整模板 action 的背景。
Injection 模式缺少宿主 parser 时，直接在模板上使用 Vim syntax，属于尽力而为的回退。

![渲染结果高亮、未执行分支与模板 action 背景](https://github.com/dirichy/vimoi.nvim/releases/download/demos/highlighting.gif)

[完整清晰度的高亮实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/highlighting.mp4)

[Injection 高亮（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/injection.mp4) · [关闭宿主高亮（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/disabled.mp4)

模板错误随编辑检查。宿主诊断复用已启用的 Neovim LSP 或 nvim-lint 配置，
检查渲染结果并将错误映射回 source；nvim-lint 仅支持 stdin 检查器。
设置 `diagnostics.host = false` 可只保留模板诊断。
详见 `:help vimoi-highlighting` 和 `:help vimoi-diagnostics`。

![模板错误和映射回 source 的宿主诊断，以及修复过程](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diagnostics.gif)

[完整清晰度的诊断实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/diagnostics.mp4)

## 补全

在 blink.cmp 配置中注册 source：

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

补全函数、data 字段、局部变量、路径和模板块 snippet。
`blocked_filetypes` 防止补全模板函数时自动添加圆括号。

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

![真实补全菜单：data、函数、局部变量、路径与块 snippet](https://github.com/dirichy/vimoi.nvim/releases/download/demos/completion.gif)

[完整清晰度的补全实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/completion.mp4)

## 路径跳转

模板及 symlink source 中的 `gf` 支持 include、共享模板、glob 和 symlink 路径；
`gF` 还支持 `path:line[:column]`。多个匹配通过 picker 选择，受管理的 target 优先打开 source。
安装 [vim-matchup](https://github.com/andymass/vim-matchup) 并启用 Tree-sitter 匹配后，
可用 `%` 跳转模板控制块。路径规则见 `:help vimoi-navigation`。

![切换 source/target 保留未保存修改，gf/gF 跳转及 vim-matchup 块匹配](https://github.com/dirichy/vimoi.nvim/releases/download/demos/navigation.gif)

[路径跳转与切换实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/navigation.mp4)

## 取消任务与刷新

后台任务持续 200ms 后显示进度；编辑更新采用 200ms 防抖。
进度显示前也可用 `:VimoiCancel` 或 `<leader>cx` 取消任务。
聚焦的等待浮窗中也可按 `q`、`Esc` 或 `Ctrl-C`。取消待处理的写回后不会继续修改文件。

![取消真实的耗时渲染后继续编辑并重新预览](https://github.com/dirichy/vimoi.nvim/releases/download/demos/cancel.gif)

[任务取消实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/cancel.mp4)

data、配置和已发现的共享模板变化后自动刷新。若结果未更新，按 `<leader>cr` 手动刷新。
模板执行可能调用密码助手，等待期间可以取消，没有默认超时。

![修改共享模板和配置数据后刷新已有预览](https://github.com/dirichy/vimoi.nvim/releases/download/demos/dependencies.gif)

[完整清晰度的依赖刷新实录（MP4）](https://github.com/dirichy/vimoi.nvim/releases/download/demos/dependencies.mp4)

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
| 模板格式化、目标图标、透明加密 | 未提供 | Conform、mini.icons、可选加解密 |
| 文件选择与部署 | 受管理文件选择、source / target 切换，部署使用 CLI | 多种文件 picker、apply 命令，默认保存后 apply |
| 默认键位 | 全局快捷键，可关闭 | 可选的 source buffer 局部键位 |
| Neovim 要求 | 0.11+ | 0.10+ |

需要格式化、加密和部署配套时，可以考虑它；需要比较渲染结果并将实际文件的静态修改带回模板时，vimoi 更侧重这一流程。
详细实现对比与历史调研见 [插件对比](docs/plugin-comparison.md)。

## 范围与限制

- 动态、重复输出及 `define` / `block` 正文中的修改通常需要手动编辑 source。
- 不支持自定义模板分隔符，或在 `chezmoi cat` 与 `apply` 下产生不同结果的模板。
- 加密文件、symlink 和脚本 source 不支持普通文本 ReAdd。
- 不提供格式化、图标、文件浏览或 apply 命令，部署继续使用 chezmoi CLI。
- 不提供 chezmoi 加密 source 的透明编辑。若只需保护仓库内容，更推荐 [git-crypt](https://github.com/AGWA/git-crypt)：解锁后的模板可直接编辑，本地工作区以明文落盘。参见 [chezmoi 透明加密说明](https://www.chezmoi.io/user-guide/encryption/transparent/)。

更多限制见 `:help vimoi-limitations`。

## 帮助

执行 `:checkhealth vimoi` 检查环境，`:help vimoi.nvim@cn` 查看完整中文帮助。
[录制演示](docs/demos/README.md) · [开发文档](docs/module-responsibilities.md) · [功能规划](FEATURES.md)

## License

[MIT](LICENSE)，Copyright (c) 2026 dirichy。

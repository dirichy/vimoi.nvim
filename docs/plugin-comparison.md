# chezmoi 插件功能对比

检查日期：2026-10-22。初次调研检查了 README 和实现源码，没有运行第三方插件。
随后在隔离的 headless Neovim 中做了双方预览测试，见 [benchmark 与功能缺口](preview-benchmark.md)；
下文的架构对比保留初次静态检查时的说明，性能结论以实测报告为准。
“未发现”表示本次检查没有找到对应实现，不推断作者未来计划。vimoi 的当前范围以
[FEATURES.md](../FEATURES.md) 为准。

后续更新：vimoi 已补上模板与非模板 source 的 target 文件类型识别、独立 Toggle 导航、
依赖失效后的视图刷新、块 snippet、可选 vim-matchup 查询及横向分屏。
下文保留修改前的调研快照，当前完成状态以 FEATURES 和 benchmark 文档的状态表为准。

## 2026-10-25：与 chezmoi-template.nvim 的当前对比

本次重新浅克隆到 `/tmp/vimoi-compare-chezmoi-template`，提交仍为
[`670ba83`](https://github.com/dpezto/chezmoi-template.nvim/tree/670ba83095ba6571f3125a5e5fd4118505a2c3c6)。
逐项核对 README、默认配置和相关实现；本轮没有运行第三方插件，也没有新增性能测量。
下表反映当前 vimoi；后续章节保留 2026-10-22 的历史快照，不能将其中的旧缺口当作当前状态。
已补 `completion.mask` 值说明与按完整字段路径遮盖，默认全部遮盖。

| 功能 | 当前 vimoi.nvim | chezmoi-template.nvim |
| --- | --- | --- |
| source / target 导航 | 独立 Toggle，保留两侧未保存内容 | source、target、edit，另有可选自动 redirect |
| target 文件类型 | 模板及普通 managed source 按真实 target 识别 | 模板及普通 managed source 均有 |
| 宿主高亮 | 默认解析渲染结果并投射回源码；可选 injection；缺少 parser 回退 syntax | Tree-sitter injection |
| 预览 | 未保存 buffer 实时只读预览，失败保留旧结果；支持横向或纵向分屏 | 相同基本能力，慢渲染默认降级为保存刷新 |
| 比较和写回 | 原生 diff 投影、同步滚动、折叠、双向 do/dp；ReAdd 保留表达式写回可确定的静态修改 | 预览中以 extmark / virtual lines 显示相对已部署文件的差异；未发现对应 hunk 写回 |
| 无名 buffer 比较 | `diff_buffers()` 支持已加载的无名及 scratch buffer | 未发现同类公开入口 |
| 模板诊断 | 编辑时检查语法与执行错误 | 保存时完整执行模板检查 |
| 宿主诊断 | 复用已启用 LSP 和 nvim-lint stdin 检查器，检查渲染结果并映射回源码 | 未发现同类集成 |
| blink 补全 | 函数、data 字段、局部变量、路径、块 snippet；可选 data 值说明与按字段路径过滤 | 函数、data 字段和值说明、按字段模式遮盖敏感值、块 snippet |
| 路径与块导航 | gf/gF 覆盖 include、template、includeTemplate、glob、symlink 等；可选 vim-matchup | gf 跳转共享模板；可选 vim-matchup |
| 宿主格式化 | 未提供 | Conform：屏蔽模板、格式化、恢复，必要时整行屏蔽 |
| 图标 | 未提供 | mini.icons 按 target 名称解析 |
| 透明加密 | 未提供 | 可选 `.age` / `.asc` 解密读取、加密保存，委托 chezmoi |
| managed-files picker | 未提供；现有 picker 用于候选选择 | snacks / telescope / fzf-lua / mini.pick / vim.ui.select |
| 部署 | 无 apply 命令；Put/Get 与 ReAdd 只改 buffer | 显式 apply，默认 `apply.on_save = true`、`force = false` |
| 默认按键 | 全局快捷键，可全部关闭；视图映射按窗口启用 | 默认关闭，可选 source buffer 局部快捷键 |
| 耗时渲染 | 后台进度与取消入口，无默认超时 | 模板执行 10 秒超时；预览默认超过 500ms 降级为保存刷新 |
| 版本与平台 | Neovim 0.12+；目前验证 Linux | README 要求 Neovim 0.10+，声明 macOS / Linux / Windows 测试 |

实现依据：对方的 [默认配置与入口](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/init.lua)、
[预览与差异显示](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/commands.lua)、
[诊断](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/diagnostics.lua)、
[补全](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/blink.lua)、
[格式化](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/format.lua)、
[加密](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/encryption.lua)
和 [CLI 调用](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/resolve.lua)；
我们的 [公开 API](../lua/vimoi/api.lua)、[源文件规则](../lua/vimoi/core/source.lua)、
[文件类型](../lua/vimoi/editor/filetype.lua)、
[宿主高亮](../lua/vimoi/editor/host_highlight.lua) 和 [诊断](../lua/vimoi/editor/diagnostic.lua)。

选择上，它更适合需要格式化、加密、文件浏览和部署配套的 source 编辑流程；
vimoi 更侧重渲染结果与实际文件的比较，以及保留模板结构的静态写回。
格式化与透明加密仍值得独立研究，但分别需要处理合法宿主输入、模板恢复和明文持久化、失败保存、取消语义，
不应为了功能对等而直接加入。默认保存后 apply 也不能照搬到我们当前的显式 buffer 修改流程。
预览性能结论继续以已有独立实测为准，不从代码结构推断整体快慢。

## 历史调研：本地仓库与版本

仓库放在 `/tmp/vimoi-plugin-comparison/`，均为浅克隆；临时目录可能被系统清理。
下列链接固定到本次检查的提交，避免之后更新导致结论错位。

| 仓库 | 提交 | 本地目录名 |
| --- | --- | --- |
| [xvzc/chezmoi.nvim](https://github.com/xvzc/chezmoi.nvim/tree/4167bbec76f693f481a5243f1be521ff0ccf1a6d) | `4167bbe` | `xvzc-chezmoi.nvim` |
| [dpezto/chezmoi-template.nvim](https://github.com/dpezto/chezmoi-template.nvim/tree/670ba83095ba6571f3125a5e5fd4118505a2c3c6) | `670ba83` | `dpezto-chezmoi-template.nvim` |
| [andre-kotake/nvim-chezmoi](https://github.com/andre-kotake/nvim-chezmoi/tree/d88b78d803a77e8e9931cad9094b0329f01dd8fa) | `d88b78d` | `andre-kotake-nvim-chezmoi` |
| [alker0/chezmoi.vim](https://github.com/alker0/chezmoi.vim/tree/7a498ea65f658993237fb0469001bdf71f68cf94) | `7a498ea` | `alker0-chezmoi.vim` |
| [Lilja/vim-chezmoi](https://github.com/Lilja/vim-chezmoi/tree/8b1983b2b90af3edbc3ebdee75a044ff74b599a5) | `8b1983b` | `Lilja-vim-chezmoi` |
| [GianniBYoung/chezmoi-telescope.nvim](https://github.com/GianniBYoung/chezmoi-telescope.nvim/tree/f60166e14c08d41ef301acee17597087f98baf88) | `f60166e` | `GianniBYoung-chezmoi-telescope.nvim` |
| [GianniBYoung/chezmoi-snacks.nvim](https://github.com/GianniBYoung/chezmoi-snacks.nvim/tree/9fe505e9a6ceea9806272405c8c8aa72b35dd819) | `9fe505e` | `GianniBYoung-chezmoi-snacks.nvim` |

Snacks 版本是沿 Telescope 版本的 README 链接补充检查的。精确提交信息另存于该目录的 `manifest.json`。

## 功能概览

`—`：未发现对应实现。文件选择指受管理文件浏览入口，不包括针对几个候选调用 `vim.ui.select`。

| 功能 | vimoi.nvim | chezmoi-template.nvim | xvzc/chezmoi.nvim | nvim-chezmoi |
| --- | --- | --- | --- | --- |
| 打开对应 source | 通过 diff/re-add，尚无独立入口 | 有 | 有 | 有 |
| CLI apply | 尚无；Diff Put/Get 仅改接收方 buffer 的 hunk | 有，默认保存后 apply | 有，可选保存后 apply | 有，可选自动/确认/不 apply |
| 受管理文件选择 | — | 多种 picker 和原生回退 | Telescope / Snacks / mini.pick / fzf-lua | Telescope |
| 未保存模板预览 | 实时、只读 | 实时、只读 | — | 手动执行一次、只读 |
| 模板感知的原生 diff、do/dp | 有 | 预览用 extmark 显示差异 | — | — |
| 保留模板的静态修改 re-add | 有，手动触发 | — | — | — |
| 模板与宿主语言同时高亮 | TS injection / syntax 回退 | TS injection | — | 目标文件类型识别 |
| source 属性名与目标文件类型 | 部分，见下文 | 有 | 打开 source 工作流 | 有 |
| 模板 diagnostics | 编辑时 debounce，语法及执行错误 | 保存时执行原文校验 | — | — |
| blink 补全 | 函数、data、局部变量、路径 | 函数、data 值说明、块片段 | — | — |
| 模板感知的宿主语言格式化 | — | Conform 集成 | — | — |
| 目标文件图标 | — | mini.icons 集成 | — | — |
| 加密 source 编辑 | — | 可选透明解密/加密 | — | 部分支持 |
| 耗时命令取消 UI | 有，含全局选择取消 | 未发现同类 UI | 未发现 | 未发现 |

其余四个插件的职责更集中：

| 插件 | 已有功能 | 与 vimoi 的关系 |
| --- | --- | --- |
| alker0/chezmoi.vim | 属性文件名识别、普通 source 的目标文件类型、模板与宿主语法高亮、特殊文件支持 | 文件类型识别值得参考；模板主要走 Vim syntax，README 要求模板停用 Tree-sitter |
| Lilja/vim-chezmoi | 在 `chezmoi edit` 启动的编辑会话中，保存后执行 apply | 单一自动 apply 功能，不是模板编辑套件 |
| chezmoi-telescope.nvim | source/target 文件选择，Add、ReAdd、Forget、Update | 通用文件操作入口；ReAdd 是直接调用 CLI |
| chezmoi-snacks.nvim | 类似 Telescope 版本，使用 Snacks picker，增加文件选择命令 | 同上；ReAdd 前会保存已修改 buffer |

保存 source 后 apply 是 source → target；自动 re-add 是 target → source。两者方向和风险不同。
我们明确不做自动 re-add，不能因此把其他插件的自动 apply 误记成同一种功能。

## 最接近的 chezmoi-template.nvim

它与我们都在解决模板编辑体验，但各自投入的重点不同。

**预览与 diff：** 它渲染完整的当前 buffer，预览可以用 extmark 和 virtual lines 标出相对真实
target 的差异。我们维护模板到渲染结果的 source map，将 hunks 投影到原生 diff，支持映射后的
双向 do/dp 和静态 re-add。本次检查的其他仓库也未发现等价的模板静态反向写回。
实现见其 [commands.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/commands.lua)
与我们的 [compare](../lua/vimoi/compare/init.lua)。

**刷新与耗时任务：** 它的预览有 150ms debounce、在途请求合并、相同内容检查，渲染超过
500ms 后会退回保存时刷新；模板执行设有 10 秒超时。我们使用结构骨架缓存、共享在途渲染，
静态编辑可以避免再次启动外部进程，并允许用户主动取消长任务。这是实现策略的差异，未实测
双方性能；完整原文渲染也避免了我们已记录的一部分骨架语义限制，不能简单称为劣势。
见其 [resolve.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/resolve.lua)。

**诊断：** 它在保存时渲染完整 buffer，解析错误行列，并用请求序号丢弃旧结果。我们在编辑时
debounce，先处理 Tree-sitter 语法错误，再执行骨架并映射位置；成功和失败结果都可复用。
它并非完全没有缓存：路径、data 等也有缓存和失效处理；只是未发现与我们相同的骨架及共享渲染机制。
见其 [diagnostics.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/diagnostics.lua)。

**补全：** 它有块片段、data 值说明以及敏感字段遮盖。我们有局部变量和 chezmoi 路径补全，
目前不展示 data 值，也没有专门的块片段提供器。双方各有缺项，不能只按“支持 blink”打平。
见其 [blink.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/blink.lua)。

**格式化：** 它用占位内容屏蔽模板片段，交给 Conform 的宿主语言 formatter，再恢复模板；
必要时退回整行屏蔽。这个方案值得研究，但 formatter 需要合法的目标语言语法，并不能直接复用
我们用于运行时映射的哨兵就完成。见其
[format.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/format.lua)。

**其他编辑便利：** 它还提供目标图标、vim-matchup 模板块匹配、source/target 导航、多种 picker，
以及可选的 `.age` / `.asc` 透明编辑。加密实际交给 chezmoi，不是自己实现密码学；加解密代码
存在同步等待。我们目前没有这些集成；我们的 gf/gF 则覆盖更多路径表达式。
见其 [encryption.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/encryption.lua)
和 [init.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/lua/chezmoi-template/init.lua)。

它的实际配置默认 `apply.on_save = true`、`force = false`，加密和默认键位则默认关闭。
这些默认行为与我们的显式写回策略不同，借鉴功能时也需要重新决定默认值。

## 通用入口与轻量插件的实际边界

- **xvzc：** 编辑入口将 target 解析为实际 source 后直接编辑，并非所有编辑都通过临时文件。
  watch 可以在保存 source 后 apply，命令底层有 Plenary `job:sync()`；回调参数不代表整个调用异步。
  见 [__edit.lua](https://github.com/xvzc/chezmoi.nvim/blob/4167bbec76f693f481a5243f1be521ff0ccf1a6d/lua/chezmoi/commands/__edit.lua)
  和 [__base.lua](https://github.com/xvzc/chezmoi.nvim/blob/4167bbec76f693f481a5243f1be521ff0ccf1a6d/lua/chezmoi/commands/__base.lua)。
- **andre-kotake：** 模板预览读取当前 buffer，但需要手动再次执行；主要命令执行路径同步等待，
  超时为 60 秒。apply 默认附加 `--force`，加密编辑属于其文档明确说明的部分支持。
  见 [command.lua](https://github.com/andre-kotake/nvim-chezmoi/blob/d88b78d803a77e8e9931cad9094b0329f01dd8fa/lua/nvim-chezmoi/chezmoi/command.lua)
  和 [commands](https://github.com/andre-kotake/nvim-chezmoi/tree/d88b78d803a77e8e9931cad9094b0329f01dd8fa/lua/nvim-chezmoi/chezmoi/commands)。
- **Telescope / Snacks：** 有 ReAdd 命令不等于支持模板静态回写，它们直接执行 `chezmoi re-add`。
  文件列表扫描 source 树，再通过字符串替换构造展示/target 路径，未使用完整的 source 属性解析。
  Telescope README 的 Remove 与实现也有出入，实际注册的是 Forget。
  见 [Telescope 实现](https://github.com/GianniBYoung/chezmoi-telescope.nvim/tree/f60166e14c08d41ef301acee17597087f98baf88/lua/telescope/_extensions/chezmoi)
  和 [Snacks 实现](https://github.com/GianniBYoung/chezmoi-snacks.nvim/blob/9fe505e9a6ceea9806272405c8c8aa72b35dd819/lua/chezmoi/init.lua)。
- **alker0：** source 命名规则和特殊文件处理比我们的宿主文件类型识别更全面；主要高亮路线
  是 Vim syntax，不能照搬为 Tree-sitter 方案。
  见 [filetype.vim](https://github.com/alker0/chezmoi.vim/blob/7a498ea65f658993237fb0469001bdf71f68cf94/autoload/chezmoi/filetype.vim)。
- **Lilja：** 通过父进程判断是否由 `chezmoi edit` 启动，保存时 shell 调用 apply；README 也说明
  直接打开 source 不适用。见 [完整实现](https://github.com/Lilja/vim-chezmoi/blob/8b1983b2b90af3edbc3ebdee75a044ff74b599a5/plugin/vim-chezmoi.vim)。

## 我们实际缺少什么，下一步如何选

1. **先统一目标文件类型识别。** `filetype.host_filetype()` 当前主要去掉 `.tmpl` 后按 source
   文件名识别，没有统一按真实 target 查询。因此 `dot_zshrc.tmpl` 这类名字可能识别不到宿主语言；
   普通的 `dot_zshrc` 也没有统一的 managed-source 类型接管。diff 中可以从 target 补回一部分，
   直接打开 source 或 preview 却不一定有这一条件。应复用现有路径缓存，避免另起一套命名规则。
2. **补独立 Source/Edit，再补显式 Apply。** 这是其他通用插件已经覆盖、我们日常操作仍缺的入口。
   Apply 必须与 Diff Put/Get 区分，先决定未保存 source/target、覆盖和取消的语义。
3. **有需要再加受管理文件选择。** 优先一个原生入口并复用 `vim.ui.select`，不必先做多 picker 适配框架。
   列表应该让 chezmoi 解释管理规则，避免手写 `dot_` 替换。
4. **较小的编辑增强可以随后选。** 块片段、模板块跳转、图标都可以按使用需要加入；不要因为别人有
   就一起引入依赖。data 值说明还要考虑密码与敏感信息，当前不显示值本身就是简单明确的策略。
5. **格式化和加密编辑另行设计。** 前者有宿主语法和模板恢复问题，后者涉及持久化、失败写入、
   外部解密耗时及取消，不适合当作几个 CLI 包装顺手补上。

目标文件类型正确、宿主高亮正确，并不等于 LSP 工作区正确。本次未在这些项目中找到可以直接
采用的完整 target-workspace 方案，这一项仍需单独研究。

我们保留当前模板映射与原生 diff 的定位，不追求复杂动态输出反向合并，也不做自动 re-add。
本次仅增加调研文档，没有修改插件功能或用户配置。

## 已做的本地验证

除了静态阅读，还在本项目最小 Neovim 环境中调用 `vimoi.editor.filetype.host_filetype()`，使用空 buffer
比较 source 命名与实际 target 命名，得到：

| 输入路径 | 结果 |
| --- | --- |
| `/tmp/dot_zshrc.tmpl` | 未识别 |
| `/tmp/.zshrc` | `zsh` |
| `/tmp/dot_bashrc.tmpl` | 未识别 |
| `/tmp/.bashrc` | `sh` |

这是文件类型 helper 的探针结果，不是对用户真实配置或所有模板场景的完整复现。

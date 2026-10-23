# Features

本文按当前实现整理。状态为「已完成」「方案替代」「部分完成」「待做」；待做项保留为规划，
不代表已决定下一步全部实现。当前使用说明以 [README](README.md) 和中英文 help 为准。

## 当前定位与原始目标

目前完成的主体是 **chezmoi 模板编辑工作流**：source map、原生 diff、只读预览、模板感知的
双向 hunk 操作、补全与路径跳转。所有写回都由用户显式触发，只修改 buffer，不自动保存。

保留 chezmoi 的 source 与 target 分离设计；不会实现保存后自动 re-add。已有手动
`:VimoiReAdd [path]` 用于普通文件和模板感知的写回，不再规划自动同步开关、连续保存补跑或
专为自动同步服务的属性缓存。复杂动态输出不尝试反向还原模板，由用户手动编辑。

## 已完成

| 功能 | 当前行为与实现位置 |
| --- | --- |
| 模板语法与 source map | `gotmpl/source_map.lua` 收集完整 template tag 与静态槽位；记录未执行、一次执行及重复执行的位置和顺序，处理 trim 和空控制块 |
| 两窗口、三份数据的模板 diff | 展示 Source Template 与 Modified Target；Rendered Base 在后台参与比较 |
| 双向打开 diff | `:VimoiDiff` 支持从 source 或 target 打开，也支持显式文件对；普通文件使用原生双文件 diff |
| 独立 source/target 导航 | `:VimoiToggle [path]` / `api.toggle(path)` 切换到另一侧；默认 `<leader>ct`，复用双向路径缓存，不渲染、apply 或自动保存 |
| 分屏方向 | `split = "vertical"`（默认）或 `"horizontal"`；diff/preview 共用，只影响新建分屏，已有窗口继续复用 |
| 原生 diff 展示与导航 | 投影 hunks 后复用原生高亮、filler、`[c` / `]c` 和 `foldmethod=diff` |
| 光标、滚动与折叠同步 | 通过 source map 对齐两个窗口；session 期间协调 Snacks smooth scroll，关闭最后一个共享视图后恢复设置 |
| 静态修改写回模板 | target 的 dp / source 的 do、`:VimoiDiffPut`；支持行内多个槽位、增删改和字面 `{{` 转义 |
| 批量 re-add | `:VimoiReAdd [path]` / `readd(path)`；普通文本文件复制 target buffer 到 source，模板仅写回可推算的静态修改；接收任一侧路径，默认当前 buffer，需要时打开 diff，不自动保存 |
| 渲染结果写入 target hunk | source 的 dp / target 的 do、`:VimoiDiffApply`；复制渲染结果，支持动态输出和循环，不复制模板源码 |
| 控制边界插入选择 | 对空控制块及相邻静态槽位枚举位置，通过 `vim.ui.select` 选择；不是通用动态模板反向合并 |
| 局部写入 | 只写变化字节，多处修改可一次 undo/redo；不强制重新收起全部折叠 |
| 只读预览 | `:VimoiPreview [source]`；使用未保存的 source，结果临时且只读，不写真实 target；失败时保留旧结果并标明过期 |
| 增量更新与缓存 | 编辑 debounce；静态、trim、重复区域等修改复用结构；新 action 结构异步渲染，过期结果不写入新状态 |
| 窗口绑定 session | 重复打开或切换 diff/preview 复用双窗口；同一 buffer 的其他窗口/tab 可有独立视图 |
| 文件类型识别与懒加载 | source 根目录内识别模板和特殊文件；普通 managed source 按真实 target 判断类型并保留原生初始化回调。规则统一在 `filetype.lua`，不建立全部 target 的属性索引 |
| 宿主语言高亮 | 普通模板按真实 target 路径识别宿主语言，复用 CLI 路径缓存；gotmpl injection、模板背景色、脚本 shebang 与无 parser 时的 syntax 回退，特殊文件保留自身规则 |
| 路径跳转 | 增强 gf / gF，支持 include、includeTemplate、template、glob、ignore/remove、symlink 等；多匹配使用 picker |
| blink.cmp 补全 | 常用模板函数、data 字段、局部变量和 chezmoi 路径；action 外有 if/ifelse/range/with/define/block/comment snippet。目前只集成 blink |
| 模板块匹配 | 为可选 vim-matchup 提供 Tree-sitter 查询，支持 trim、嵌套和 else 链；不自行覆盖 `%` |
| 缓存失效与监听 | 配置、已发现的 data / include 模板目录及 ignore 路径监听；支持编辑器外变化、按 scope 失效和保存事件兜底。渲染上下文失效后自动刷新所有打开的视图，不写回真实文件 |
| init 模板 | 识别 `.chezmoi.{toml,yaml,yml,json,jsonc}.tmpl`，映射 config 路径，使用 `execute-template --init` |
| 可取消耗时命令 | `job.lua` 管理进程、进度与取消；后台通知位于右上，等待结果时使用异步进程与聚焦浮窗，无默认 10 秒超时 |
| 全局取消选择 | `<leader>cx` / `:VimoiCancel`；一项直接取消，多项通过 picker 选择；Unix 下终止同一进程组的子进程 |
| 用户入口与键位配置 | 已提供的用户命令都有 Lua API；默认键位可覆盖、单项禁用或全部关闭 |
| 配置与帮助文档 | 支持 executable/config 路径、监听、补全、高亮、diff 校验与键位；提供中英文 `:help vimoi.nvim` |
| 模板 action 背景 | 默认取主题的 `NormalFloat` 背景；`highlight.template_bg` 支持高亮组名、固定颜色或深浅色配置，保留语法前景色 |
| 模板 diagnostics | 默认启用，可配置关闭；300ms debounce，复用哨兵骨架、缓存和在途渲染，语法/执行错误映射到原始 source；静态修改复用成功及失败结果 |
| 宿主 diagnostics | 默认自动复用已启用的 LSP 和 nvim-lint 的 stdin 检查器；对隐藏渲染快照检查，经 source map 映射回模板，保留来源/级别/错误码；动态区域保守定位，旧快照结果隔离 |
| 渲染结果高亮（实验） | `highlight.mode = "rendered"` 替代宿主 injection；对完整输出使用原生 Tree-sitter query，把可见静态文本的颜色映射回 source；持久 extmark 保留旧颜色并跟随编辑；隐藏 output buffer 增量解析；保留 gotmpl action，关闭诊断仍可使用；未执行静态片段使用 Comment，循环采用第一次执行 |
| 关闭宿主高亮 | `highlight.mode = "disabled"` 关闭宿主 injection、渲染高亮和 Vim syntax 回退；保留模板 action 高亮及背景，不影响诊断或 source map |
| 环境健康检查 | `:checkhealth vimoi` 检查版本要求、可执行文件、已发现路径、gotmpl parser/查询及打开模板的可选宿主 parser；不启动 chezmoi、不渲染或写文件 |
| 自动化覆盖 | 路径、配置、缓存、任务取消、窗口生命周期、diff/preview/写回等测试；source map 覆盖条件、循环、trim、重复文本、空块与 includeTemplate |

## 已选其他方案替代

| 原规划 | 当前方案 | 仍有的边界 |
| --- | --- | --- |
| 静态文本全局对齐，结合 AST 推导运行时映射 | 将静态槽位替换为哨兵，记录执行位置、次数和顺序，再恢复静态文本 | include 内部的表达式不会因此获得细粒度反向映射；哨兵碰撞等限制见 README |
| 逐个静态/动态/控制节点建模并维护置信度 | 使用 `template_tags`、`literal_parts`、渲染区域分类和写回候选 | 没有原规划完整的 exact/bounded/unknown 置信度模型，也未暴露完整的五类 hunk 分类接口 |
| `:VimoiAutoMerge` 批量 merge | 改为 `:VimoiReAdd [path]`，突出「target 修改写回模板」的用途 | 单向操作；无法自动迁移的部分仍需手动编辑 |
| 静态 put/re-add 后重新渲染并验证候选 | 根据原执行记录、trim 与静态字节编辑推算结果并重建 source map | 结构变化仍需正常渲染；推算不负责反解动态模板 |
| 依靠额外渲染验证每个边界候选 | 根据槽位执行次数、顺序和 trim 规则推算位置，用户选择 | 用户仍需判断候选是否符合预期的模板语义 |
| 用 virtual lines 显示被删除行等 diff 效果 | 提供投影 hunks，交给原生 diff 高亮、filler 和折叠 | 用户直接执行原生 :diffget/:diffput 会绕过模板感知映射 |
| 所有 chezmoi 调用异步 | 预期耗时的 data、cat、用户模板渲染异步；快速路径/config 身份查询仍直接执行 | 没有把所有快速查询都改为异步，也不将其标为未完成工作 |
| 为各种 picker 单独适配 | 使用原生 `vim.ui.select`，复用用户已有的 picker 替换 | 不内置 Telescope/fzf-lua 等专用适配器 |

## 部分完成，不能直接勾选为完成

| 原规划 | 已有能力 | 缺少的部分 |
| --- | --- | --- |
| 文件类型及管理属性识别与缓存 | source 根目录识别、按需 source/target 路径查询和缓存；普通模板与非模板 managed source 均按真实 target 名称识别 | 尚无全部受管理文件的属性索引；仅在具体操作需要时考虑 |
| static/dynamic/repeated/boundary/unknown 分类 | 内部区分 static、dynamic、repeated、ambiguous，写回规划检查边界并报告跳过原因 | 稳定的用户可见分类与冲突浏览；不能认为完整五类模型已实现 |
| 边界修改交互 | 控制边界插入有 picker；静态修改可按字节拆分 | 无法安全映射到静态槽位的修改由用户手动处理；复杂动态反向合并不在计划中 |
| 上下文不兼容检测与降级 | 已记录不支持字段；`diff.validate = true` 时比较哨兵结果与 `chezmoi cat`，不一致则拒绝 diff | AST 字段检测、精确错误原因及自动降级尚未实现；严格校验默认关闭，preview 不适用 |
| 编辑 source 时保留目标语言体验 | 已有独立 Toggle、目标文件类型、宿主语言高亮、预览和 diff | source 路径上的 LSP 工作区仍未解决 |
| 模板语法校验 | 已有独立于 diff/preview 的默认 diagnostics，支持语法与执行错误定位 | 没有额外的手动完整原文校验命令；无法定位的错误仍以通知展示，沿用哨兵限制 |
| 外部 source 变化后刷新 | 配置、data、include 模板依赖失效后自动延迟刷新现有视图，初次渲染由 guard 重试 | 不是全部 source state 的索引与属性自动重扫；未监听的新目录仍需手动 invalidate/rescan |
| 安静通知与可替换通知 | 普通通知走 `vim.notify`，支持用户替换；后台任务不抢焦点 | 任务进度由 job 自有浮窗显示，尚无替换该 UI 的配置；写回成功仍有通知 |
| 工程质量配置与测试 | 当前功能的配置、路径/命令/缓存/写回/窗口测试、checkhealth 和中英文 help | 未来新增功能时扩展相应测试，不为已取消的自动同步规划测试 |

## 已明确不做

- 保存 target 后自动 re-add，包括加密文件的自动 re-add、连续保存任务合并、自动同步开关和排除配置。
- 复杂动态输出的反向合并，包括替用户决定修改模板表达式、data 或生成常量；这类情况手动编辑 source。
- 为上述两项目标新增自动同步基础设施或通用动态反向执行 trace。

## 待做：用户操作与模板增强

- [x] `:VimoiToggle`：独立切换 source/target，不必同时进入 diff。
- [ ] `:VimoiApply`：用户显式应用当前 source 文件到真实 target；现有 DiffApply 仅改当前 hunk 的 buffer，不等同于 chezmoi apply。
- [ ] `:VimoiAdd [file]`：加入管理。
- [x] 模板错误 diagnostics，保留原始 source 的行列映射。
- [ ] 当前 hunk 两侧临时强调显示。
- [ ] 保存模板后可选 apply；必须先确定授权、未保存内容和覆盖 target 修改的规则。
- [ ] source template 的目标路径/LSP 工作区上下文。

## 待做：后续增强

- [ ] `:VimoiStatus`：受管理文件和同步状态列表。
- [ ] source directory 浏览入口。
- [x] 可配置 diff/preview 的横向或纵向分屏。
- [ ] 浮窗或新 tab 打开方式。
- [ ] source 中以虚拟文本显示渲染值；当前使用独立只读 preview。
- [ ] 忽略项、外部资源和脚本的专用操作。
- [ ] 可替换的任务进度 UI；普通通知已可通过 vim.notify 替换。

## 后续候选（未承诺实现顺序）

`checkhealth`、模板 diagnostics、source 目标文件类型、独立导航、依赖刷新、snippet、
可选块匹配及分屏方向已完成。后续可以考虑显式 Apply 和受管理文件选择。
Apply 应只操作明确的当前文件；实现前确定未保存 source、未保存
target 及取消时的行为，避免隐式保存或覆盖。其余候选及取舍见下面的对比，不代表全部承诺实现。

## 参考同类插件后的功能取舍

以下选取 2026-10-22 源码调研中的代表性功能；仓库、固定提交与实现依据见
[插件对比](docs/plugin-comparison.md)，预览性能实测与更完整的缺口清单见
[preview benchmark](docs/preview-benchmark.md)。以下仍是规划判断，不将候选项记为已实现。

### 值得后续加入或完善

| 代表功能与参考项目 | 我们当前的缺口 | 建议与取舍 |
| --- | --- | --- |
| 目标文件类型识别：alker0、chezmoi-template | 已补模板与非模板 managed source 的 target 名称识别 | 复用 CLI 路径缓存，不另写属性前缀解析。文件类型正确仍不等于解决 LSP 工作区 |
| 独立 source 编辑与 apply：xvzc、nvim-chezmoi | 独立 Toggle 已完成；DiffApply 仍只改 target buffer 的 hunk，不执行 CLI apply | 显式当前文件 Apply 留作后续；保存后自动 apply 继续保留为待设计项，不照搬其他插件的默认开启行为 |
| 受管理文件选择：xvzc、Telescope / Snacks 扩展 | 当前 picker 只选择写回候选、路径匹配或待取消任务，没有 managed-files 浏览入口 | 有实际需要时加入；由 chezmoi 提供列表，优先 `vim.ui.select`，复用用户已有 UI，不先做多 backend 适配 |
| 块片段与模板块匹配：chezmoi-template | 已加入 blink snippet 和可选 vim-matchup 查询 | 复用现有 snippet 引擎和匹配插件，不增加必需依赖或自行接管 `%` |

### 已有替代方案或覆盖更适合我们的需求

| 同类功能 | 当前方案 | 判断与保留的边界 |
| --- | --- | --- |
| 预览中用 extmark / virtual lines 标出差异：chezmoi-template | 只读实时 preview；需要比较和写回时使用 source map 投影后的原生 diff | 无需另做一套 diff 展示；原生 hunks、filler、折叠和映射后的 do/dp 更符合我们的交互目标，但两种 UI 并非完全相同 |
| 直接调用 CLI re-add：Telescope / Snacks 扩展 | 手动 `VimoiReAdd` 支持普通文本文件；模板写回可映射的静态修改并保留结构 | 已覆盖模板编辑的核心需求；不需要再增加同名的 CLI 包装。动态输出仍需手动处理，不能宣称替代 CLI 的所有 re-add 行为 |
| 保存时完整渲染诊断、预览慢时降级为保存刷新：chezmoi-template | 编辑时 debounce，骨架缓存、共享在途渲染、旧结果丢弃及用户主动取消；diagnostic 也检查 TS 语法错误 | 已有适合持续编辑的方案，不照搬固定超时与刷新降级。完整原文校验仍可作为独立候选，弥补骨架语义限制；预览基准的静态编辑收益不能推广为所有模板或整个插件更快 |
| include/template 跳转：chezmoi-template | 增强原生 gf/gF，覆盖 include、includeTemplate、template、glob、symlink 等路径 | 已有较广覆盖，继续维护统一路径规则；无需为相同用途再加一套导航入口 |

### 可选增强，暂不作为下一步

| 代表功能 | 建议 | 原因与边界 |
| --- | --- | --- |
| 宿主语言格式化：chezmoi-template 的 Conform 集成 | 值得单独研究，暂不承诺实现 | 需要屏蔽模板、保证 formatter 输入语法可接受并恢复模板；运行时 source map 哨兵不能直接解决。先确认常见模板上的收益和恢复可靠性 |
| 加密 source 透明编辑：chezmoi-template、nvim-chezmoi | 留作独立候选 | 可以委托 chezmoi 加解密，但还需设计 buffer 读写、明文持久化、失败保存及取消；不同于自行实现密码学，也不同于自动 re-add |
| 目标图标、补全中的 data 值说明：chezmoi-template | 按需要选择，不作为核心缺口 | 图标可做可选集成；data 值当前不显示，若以后显示需决定敏感值处理，不必为追求功能对等加入额外配置 |
| Add / Forget / Update 等 CLI 入口：Telescope / Snacks 扩展 | Add 保留原规划，其余等具体工作流需要再加 | 简单包装命令的收益有限；优先补足模板编辑闭环，不把所有 CLI 子命令搬进插件 |

自动 re-add 和复杂动态输出反向合并仍按「已明确不做」处理；同类插件的功能不会改变这一边界。

## 暂不纳入范围

- 重新实现 chezmoi 模板引擎、加密或密码管理。
- 保证 gotmpl 宿主语言 injection 始终语法完整；模板生成 token 或拼接不完整语句时仍可能高亮不准确。
- 静默用 target 或渲染结果覆盖 source template。
- 自动执行全局 `chezmoi apply`、Git commit 或 push。
- 替代 chezmoi CLI，或强依赖特定插件管理器、picker、通知插件。
- MVP 中自动映射 `.chezmoi.sourceFile`、`.chezmoi.targetFile`、`.chezmoi.command`、`.chezmoi.args` 或自定义 delimiter。

## 历史设计说明

[template merge mode](docs/template-merge.md) 和 [render environment compatibility](docs/render-environment.md)
保留了设计探索过程，部分方案已被替代。尤其保存触发的自动合并、静态文本全局对齐、强制候选渲染验证，
均不能当成当前实现要求。自动 re-add 与复杂动态反向合并已明确不做。当前状态以本文和使用文档为准。

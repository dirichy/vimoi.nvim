# 模块职责整理与实测

## 当前结构：render 配置与模块命名

`diff.validate` 和中间版本的 `session.validate` 已统一为 `render.validate`，因为构造校验
属于共享渲染服务。旧 `diff` / `session` 配置会提示迁移错误；`api.diff` / `api.diff_files` 的单次 `validate` 参数保留，
仍覆盖共享 source session 的构造策略。

原 `lua/vimoi/gotmpl/` 同时包含渲染、窗口和写回逻辑，不能整体准确地称为 render。
内部模块按五个主要职责归组；顶层只保留 `init.lua`、`api.lua`、`blink.lua` 和 `health.lua`
这四个配置、用户操作及 Neovim 集成入口。顶层另有实验性 `parser.lua`，只提供
`collect_template_tags(source)`；它不实现 AST，也不模拟 Tree-sitter 的节点 API。

| 目录 | 模块与职责 |
| --- | --- |
| `core/` | `cli`、`job`、`watch` 管理 chezmoi 命令、任务与监听；`source` 统一源文件规则；`util`、`buffer_edits` 提供共享工具和局部字节修改 |
| `render/` | `init` 按 source session 管理 source 级校验、渲染、输出 buffer、防抖、缓存和订阅；`source_map` 管理模板结构、哨兵和位置映射 |
| `compare/` | `init` 统一打开 diff/preview 并管理窗口生命周期；`diff_hunks` 计算差异块及 source 投射；`native_diff`、`sync_scroll` 处理原生 diff 适配及滚动同步 |
| `merge/` | `init` 统一显式写回流程；`plan` 负责模板合并规划与转义 |
| `editor/` | `filetype`、`lazyload` 管理文件类型与加载；`highlight`、`host_highlight`、`diagnostic`、`goto` 管理高亮、诊断和导航 |

`render/init.lua` 是共享渲染服务入口，直接加载为 `require("vimoi.render")`；
内部每个 source 的渲染状态仍称 session，相关类型和生命周期保持不变。
`compare/init.lua` 合并原打开入口与视图生命周期；`merge/init.lua` 保留写回入口。
两者直接实现逻辑，不增加转发模块。`require("vimoi.compare")` 与 `require("vimoi.merge")`
仍直接加载各自目录下的 `init.lua`。
`core/buffer_edits.lua` 被 session、preview 和 merge 共用，因此不归某个功能目录独占。
目录仅用于组织代码，不改变模块加载时机、共享状态所有权或取消/清理规则。

打开入口合并后曾从 24 个模块减为 23 个；文件规则独立后当前为 24 个模块。
不保留旧内部 require 路径的兼容入口。

上述职责调整阶段相对此前工作区净增 **5 行运行时代码**（7,056 → 7,061，包含空行、
注释和类型声明，不计测试、文档）：

- `core/source.lua` 集中 init 文件名、模板规则和路径语义，不初始化 Neovim filetype、
  不加载 CLI；`editor/filetype.lua` 复用同一规则表，仅处理 Neovim 检测、注册和宿主语言。
  CLI、render、merge、goto 直接使用规则模块。
- 原 `view/` 改为按对照功能命名的 `compare/`：preview 对照 source 与渲染结果，
  diff 对照 source 与 target。`compare/diff_hunks.lua` 是视图和合并共用的纯计算，
  与窗口实现分别维护；diff/preview 继续共用窗口生命周期，不增加转发或协调模块。
- 无法定位的渲染错误直接作为第一行诊断展示，保留原始错误并注明位置不可用。
  重复刷新覆盖同一诊断，成功后自动清除；删除 `reported` 与 `render.report_error()`，
  不再维护通知去重状态。
- 自动诊断/高亮消费者的合并订阅、开关协调与清理仍留在 render。暂不新增消费者
  调度模块，避免为了依赖分层再引入生命周期协议。
真正的 `gotmpl` filetype、Tree-sitter parser 和 query 仍使用原名。
这轮整理不改变渲染算法，不据此声称性能提升。

## 简化配置、滚动与计时

以下是独立于上述模块迁移的一轮行为调整：运行时 Lua 从 **7,061 行减少到 6,913 行**，
净减 **148 行**，模块仍为 24 个。行数包含注释、空行和类型，不含测试、benchmark 与文档。

- `setup()` 只初始化一次，重复调用明确报错，配置修改后重启。删除固定/动态配置的
  区分、已有 session 的开关迁移和高亮模式切换时的全量刷新；初始化失败仍可重试。
  公共 setup 使用 `util.once(initialize, { repeat_error = "..." })` 明确拒绝重复调用；省略该选项的
  内部初始化仍保持幂等。
- source 到重复输出固定选第一次执行。基本双向行对应、范围高亮和滚动同步保留；
  视口只同步逻辑行偏移，不再追求精确屏幕行对齐，也不补偿多行展开的完整可见性。
  折叠、换行和文件边界使用 Neovim 原生行为。
- 删除 `last_profile`、cat/渲染时间戳以及打开流程中的计时参数。

端到端测量现在运行：

```sh
NVIM_LOG_FILE=/tmp/vimoi-compare-benchmark.log nvim --headless -n -i NONE -u NONE -l tests/compare_benchmark.lua
```

脚本自行建立临时 source、target、chezmoi 配置及 persistent state。关闭自动诊断和
宿主高亮，保留默认 cat 校验；分别测量 1 行、1,000 行模板的 diff 与 preview。
每组使用独立的新 source session，预热 2 次后记录 5 次并输出 JSON 中位数及样本。
计时从调用用户入口到视图和映射就绪，不包括 setup、源文件加载或屏幕绘制；
通过真实渲染结果校验，轮询间隔 1ms。可用 `VIMOI_BENCH_RESULT` 指定 JSON 输出路径。

这个脚本用于观察端到端 wall time；局部 CPU 和调用次数仍使用
`tests/render_cache_benchmark.lua`，构造校验使用 `tests/session_validation_benchmark.lua`。
脚本独立运行，比较版本时保持 fixture、配置和运行环境一致，不与测试或 LSP 并行。
本轮不据代码删减声称运行速度提升。

## 前一轮整理与性能记录

以下记录对应此前从 26 个模块整理到 24 个模块的版本，不是当前命名迁移的性能对照。

日期：2026-10-25；整理前基线为 `9a6c1c0`。用户操作 API 和配置保持不变。

## 保留的改动

- `vimoi.merge` 统一 put/get/re-add、路径分派、普通文件和模板的写回流程，取代
  `vimoi.readd` 与 `gotmpl.merge`。模板位置规划仍由 `gotmpl.merge_plan` 负责；
  打开 diff/preview、普通文件 re-add 都不加载规划模块。
- `diagnostic` 统一模板错误展示与宿主 LSP/nvim-lint 的投射、取消和清理，取代
  独立的 `host_diagnostic`。两个诊断 namespace 保留，关闭宿主诊断不会清空模板错误。
  诊断模块仍按需加载，不增加启动加载模块。
- `view.current()` 统一获取当前有效视图并清理失效绑定，供 toggle、fold、open 和写回使用。
  异步写入时的路径、正文和上下文检查保留，因为它们验证的是等待期间是否发生变化。
- 正常渲染将已经准备好的输入交给 `trace_async`。同一对象在回调前完成正文解码；
  如果等待期间出现新的字面文本编辑，则对最新 prepared 再解码，避免旧位置覆盖新内容。
- session 的临时快照共享 `map.regions` 及 source/output 行索引，diff/merge 不再重新
  构建同一份区域及行索引。source/output 全文仍只在操作期间读取，不存入长期状态。

`lazyload` 保持不变。曾试合 `highlight` 与 `host_highlight`，但只少 5 行，
却会让非 rendered 模式在启动时也加载映射绘制实现，因此撤回。session/view、
source_map/merge_plan、diff_hunks/native_diff 的职责边界保留。

运行时 Lua 模块从 **26 减为 24**；行数从 **7,043 变为 7,057**，净增 **14 行**。
统计包含空行、注释和类型声明，不计测试与文档。这次收益主要是减少入口、明确所有权和
复用已有计算结果，合文件本身不会大幅减少算法代码。本轮补查增加了少量范围查找和
类型说明代码，没有增加持久缓存或生命周期机制。

## 实测范围

原始记录见 [JSON](benchmarks/module-refactor-2026-10-25.json)。

启动测量比较两份 checkout，使用同一份 chezmoi fixture，固定在同一个允许使用的
CPU 上，交替执行 15 轮；记录从 require/setup 到返回的时间，不含 Neovim 进程启动。
所有高亮模式的已加载模块集合均保持一致。中位数如下，单位 ms：

| 模式 | 整理前 wall / CPU | 整理后 wall / CPU |
| --- | ---: | ---: |
| rendered | 19.33 / 4.88 | 19.34 / 4.86 |
| injection | 19.31 / 4.70 | 19.20 / 4.72 |
| disabled | 19.24 / 4.71 | 19.36 / 4.76 |

启动开销基本持平；这些小差异不作为加速结论。

首轮本地计算测量运行 5 个独立 Neovim；每个案例预热 33 次，记录 100 次，汇总各进程中位数。
先真实执行一次 chezmoi 获取骨架输出，随后通过 scheduled callback 返回相同骨架，
仅测准备、解码和 hunk 计算的 CPU 时间，不包含 chezmoi 执行或屏幕绘制。
旧实现忽略 prepared 输入及快照缓存字段，因而同一脚本可以比较两版。

| 模板 | 准备与解码 CPU：前 → 后 | hunk CPU：前 → 后 |
| --- | ---: | ---: |
| 8 个 action | 0.042 → 0.023 ms | 0.013 → 0.003 ms |
| 1,000 个 action | 1.261 → 0.619 ms | 0.419 → 0.042 ms |

实际 prepare/正文解码工作均从每次两遍降为一遍；等待期间产生新编辑时仍需要对最新
位置解码。普通小模板绝对节省很小，不能把上述比例当作整个渲染流程的加速比例。

当前版本可运行：

```sh
XDG_STATE_HOME=/tmp/vimoi-render-bench-state NVIM_LOG_FILE=/tmp/vimoi-render-bench.log \
  nvim --headless -n -i NONE -u NONE -l tests/render_cache_benchmark.lua
```

复现这轮历史对照时，请使用该轮版本的 benchmark 脚本；以 `9a6c1c0` 的 checkout
作为基线 cwd。当前脚本已迁移内部模块名称，不能直接在旧 checkout 中运行。

## 补查重复扫描

在首轮改动的工作区版本上继续检查，并保留以下调整：

- regions 利用 restore 已记录的连续执行序号生成，不再排序。空输出、循环和逆序 source
  对应仍按输出顺序保留；没有新增排序缓存。
- 每个 hunk 对已排序 regions 二分查找起点，并在超过末端时停止，避免遍历整张映射。
  边界使用严格小于/大于比较，保留零宽插入两侧的候选区域。
- 原生 diff 的行号投射直接使用 map.source_starts，不再为每个 hunk 扫描 source 文本。
- merge 规划直接复用 trace.output_starts；每个不同的隔离 target 仍单独计算自己的索引，
  没有把不同正文的索引混用。picker 候选标签使用 source 索引，只截取所在行，
  避免逐候选拆分全文。

补查基准和首轮基准的比较起点不同：补查的 before 已包含首轮缓存复用。
两版固定同一 CPU，交替运行各 5 个独立进程；稀疏案例每个进程预热 53 次，
记录 30 次，再汇总各进程中位数。最终基准独立运行，没有同时执行测试或 LSP。

1,000 个 action、每 10 行一个静态修改，共 100 个 hunk；单位为 CPU ms：

| 本地计算阶段 | 补查前 | 补查后 |
| --- | ---: | ---: |
| regions 构建 | 0.374 | 0.080 |
| 稀疏 hunk 投射 | 2.596 | 0.610 |
| 原生 source 行号投射 | 11.200 | 0.032 |
| merge 规划 | 20.328 | 6.412 |

regions 构建仍使用每进程 33 次预热、100 次记录。原生投射通过清空 view 的已投射
hunk 后调用 hunk_at 的回退路径测量，等价于 update 中的投射计算，不含原生 diff
协议的文件读写、窗口绘制或光标同步。规划结果校验为 100 个静态编辑、无跳过及候选。
8 个 action 的绝对节省很小，规划时间没有稳定优势。以上为局部工作量测量，
不能解释为整次 UI 渲染或真实 chezmoi 命令相同倍数的加速。

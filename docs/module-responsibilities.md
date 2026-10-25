# 模块职责整理与实测

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

对比基线时，用 `9a6c1c0` 的 checkout 作为 cwd，运行同一份 benchmark 脚本即可。

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

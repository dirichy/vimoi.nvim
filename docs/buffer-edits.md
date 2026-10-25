# 合并结果局部写入

`dp` 和手动 template re-add 先规划静态修改及候选位置，按需交互选择，再生成转义后的
source edits，通过现有执行记录推算新输出和 source map，最后局部修改 buffer，不自动写盘。
不重新渲染候选或验证完整输出；动态及无法推算的修改留给用户手动处理。

## 实现与取舍

- `merge_plan.plan()` 只规划 edits、choices 和 skipped。选择完成后，
  `merge_plan.apply_source_edits()` 构造转义后的 source 文本和实际 edits；
  `source_map.rebuild_after_edits()` 根据原有执行记录重建映射。
- `merge` 用协程按顺序等待结果、选择位置并检查写回快照；模态等待和取消复用
  `job.wait()`，有效渲染通过 `session.register(..., { once = true })` 获取。`buffer_edits.apply()` 只负责按 edits
  写入 buffer，不理解模板。多个同位置 edits 使用候选构造时确定的实际顺序。
- 完整行修改用 `nvim_buf_set_lines()`，行内修改用 `nvim_buf_set_text()`，减少对未修改
  文本、extmark 和解析缓存的影响。行首索引每次操作只建立一次。
- 多处修改在 source buffer 中通过 `undojoin` 合为一次 undo/redo；没有另建撤销状态。
- Neovim 把最后一个换行存为 `endofline` 选项。涉及该边界的 edits 合并成物理文本后缀，
  避免访问不存在的额外 buffer 行。原生 undo 不恢复该选项，保持原来的行为。
- 删除 put 后强制执行两次 `zM` 的逻辑，交给原生 diff 更新折叠。已打开的折叠和 `zR`
  状态经过回归验证；不额外保存/恢复折叠，几何范围变化仍遵循 Neovim 的处理方式。

`core/buffer_edits.lua` 同时供合并及只读预览刷新使用；模板转义由 `merge_plan` 负责。
没有引入新配置、写入阈值或额外按键劫持。候选文本构造、映射重建和 diff 刷新仍有
处理整份文本或映射数组的工作，因此不是整个合并流程都变成严格的局部计算。

## 一次本机测量（2026-10-20）

使用 Neovim headless，模板含 100/400/1600 个 if，仅交替修改末行的四个字节。
比较旧的 `util.set_buffer_text()` 与生产 `buffer_edits.apply()`，后者包含坐标转换、
行首索引和 buffer 切换。每组预热八次，九批各二十次，交替顺序，取批次平均值中位数。
GC 保持开启，仅在每批之前主动回收。单位为毫秒，不代表跨机器保证。

| 样例 | 全量写入 | 局部写入 | 全量写入＋解析 | 局部写入＋解析 |
| --- | ---: | ---: | ---: | ---: |
| 100 if / 4.9KB | 0.0234 | 0.0073 | 0.655 | 0.135 |
| 400 if / 19.6KB | 0.0769 | 0.0096 | 2.635 | 0.520 |
| 1600 if / 78.4KB | 0.2898 | 0.0225 | 11.021 | 2.009 |

这里的解析是写入后实际查询 buffer 语法缓存的成本：全量写入报告整 buffer 变化，
收集节点分别为 702/2802/11202；局部写入均为 2。这不是 `dp` 端到端耗时，不包含
候选计算、映射重建、diff 更新和 UI。测量时的合并实现还包含候选渲染校验，
这一步后来已移除；表格仅测写入及解析成本。大量分散 edits 仍有多次 API 调用，
不能据此推断任意 template re-add 都有同样的提速比例。

复现：

```sh
env XDG_STATE_HOME=/tmp nvim --headless -n -i NONE -u tests/minimal_init.lua \
  -l tests/buffer_write_benchmark.lua
```

## 回归验证

`tests/diff_buffer_edits.lua` 对照候选文本检查 1216 组写入与 undo/redo，包含 Unicode、
整行/行内增删改、空 buffer、EOF、模板括号转义、多处 edits 和相同插入位置。
另验证未修改行及同行未修改区域的 extmark，检查变更通知不会扩大到整 buffer。

实际 diff 集成测试覆盖 put、手动 template re-add、交互选择和取消、模板边界及转义。
初次渲染验证失败由单独的异步初始化测试覆盖，不是局部写入前的候选验证。
`diff_byte_edits_integration.lua` 验证真实 put 的一次 undo/redo 和模板标签标记；
`diff_fold_refresh.lua` 验证原生更新保留打开的折叠及 `zR` 状态。

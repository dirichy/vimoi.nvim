# 合并结果局部写入

`dp` 和 auto merge 仍先生成候选模板、验证完整渲染结果，通过后才修改 source buffer，
不会自动写盘。变化仅在最后的写入阶段：复用转义后的实际 edits，倒序局部应用。

## 实现与取舍

- `apply_source_edits()` 返回候选文本及实际使用的 edits，保留模板括号转义后的范围。
  同一位置的 edits 也复用候选计算的实际应用顺序，不再另算一次 diff。
- `merge_plan.plan()` 只规划 edits、choices 和 skipped；选择完成后，put 和 auto merge
  用 `merge_plan.prepare_candidate()` 构造实际写入及预期输出；`merge` 负责选择和验证，
  结构不变时复用 source map，否则异步渲染，并在写入前检查原始快照。
- 完整行修改用 `nvim_buf_set_lines()`，行内修改用 `nvim_buf_set_text()`，减少对未修改
  文本、extmark 和解析缓存的影响。行首索引每次操作只建立一次。
- 多处修改在 source buffer 中通过 `undojoin` 合为一次 undo/redo；没有另建撤销状态。
- Neovim 把最后一个换行存为 `endofline` 选项。涉及该边界的 edits 合并成物理文本后缀，
  避免访问不存在的额外 buffer 行。原生 undo 不恢复该选项，保持原来的行为。
- 删除 put 后强制执行两次 `zM` 的逻辑，交给原生 diff 更新折叠。已打开的折叠和 `zR`
  状态经过回归验证；不额外保存/恢复折叠，几何范围变化仍遵循 Neovim 的处理方式。

`gotmpl/buffer_edits.lua` 同时供合并及只读预览刷新使用；模板转义由 `merge_plan` 负责。
没有引入新配置、写入阈值或按键劫持。完整候选解析、校验和 diff 刷新仍然存在，
因此不是整个合并流程都变成增量计算。

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
候选计算、渲染校验、diff 更新和 UI。大量分散 edits 的写入仍有多次 API 调用成本，
不能据此推断任意 auto merge 都有同样的提速比例。

复现：

```sh
env XDG_STATE_HOME=/tmp nvim --headless -n -i NONE -u tests/minimal_init.lua \
  -l tests/buffer_write_benchmark.lua
```

## 回归验证

`tests/diff_buffer_edits.lua` 对照候选文本检查 1216 组写入与 undo/redo，包含 Unicode、
整行/行内增删改、空 buffer、EOF、模板括号转义、多处 edits 和相同插入位置。
另验证未修改行及同行未修改区域的 extmark，检查变更通知不会扩大到整 buffer。

实际 diff 集成测试覆盖 put、auto merge、交互选择和取消、渲染验证失败、模板边界及
转义。`diff_byte_edits_integration.lua` 验证真实 put 的一次 undo/redo 和模板标签标记；
`diff_fold_refresh.lua` 验证原生更新保留打开的折叠及 `zR` 状态。

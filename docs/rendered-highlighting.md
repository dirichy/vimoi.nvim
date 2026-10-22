# 渲染结果高亮原型

`highlight.mode = "rendered"` 停用 source 上的宿主 injection，保留 gotmpl 自身的
高亮。默认模式为 "injection"，可在同一会话中通过 setup 切换。
模式 "disabled" 同时关闭宿主 injection、渲染高亮和 Vim syntax 回退，保留模板
action 的高亮及背景，不关闭诊断或 source map。

## 渲染与生命周期

`diagnostic.lua` 已有按 source/context 管理的异步渲染和 300ms debounce，本原型
复用这一条计算链，不额外启动一套 chezmoi 请求。诊断发布和渲染高亮分别由开关
控制，关闭 diagnostics 仍能得到高亮。静态文本修改复用骨架渲染结果，重新恢复
当前原文及映射。

成功渲染后，`host_highlight.lua` 用完整输出建立原生 string parser，并解析全部
语言子树。每个快照重新建树，尚未做跨快照的 Tree-sitter 增量更新。编辑后先撤掉
旧快照；重绘时还检查 changedtick 和 context generation，防止 debounce 前错位。
卸载 buffer、切回 injection 或改变 filetype 时清理快照；关闭窗口时丢弃其视口缓存。

## 查询与绘制

保留 Neovim 高亮器的处理顺序：语法树 → highlights query → capture 的带语言
高亮组 → 重绘范围查询 → ephemeral extmark。没有复制私有高亮器或修改全局 API，
parser、query、metadata range 和 decoration provider 都调用原生接口。

source 的 `on_win` 将可见静态区域通过 source_map 转为 output 行范围，并合并相邻
查询范围。遍历所有语言子树，使用各语言的原生 highlights query。capture 先与
子树 included ranges 相交，再与精确静态映射相交，最后转回 source 行列。
这样跨模板 action 的宿主字符串会拆成多个 extmark，不覆盖 action。

沿用 `@capture.language`、priority、普通 conceal、spell 和 URL metadata；颜色由
当前 colorscheme 决定。相同快照和视口复用查询结果，`on_range` 只绘制当前重绘范围
内的 ephemeral extmark，不在隐藏输出上创建高亮 extmark。

## 限制与验证

- 动态输出没有对应的可编辑字符，不映射到模板 action。
- `literal_parts` 中没有任何 output occurrence 的非空静态区域，使用原生 `Comment`
  高亮，表示当前渲染未执行。包括条件分支和零次执行的循环体；不覆盖模板 action。
  同样按视口裁剪和缓存，缺少宿主 parser 时也会绘制 Comment。
- 循环重复区域取第一次执行，避免不同执行的颜色相互覆盖。
- 不投射 LSP semantic tokens，不实现原生的 conceal_lines 和 spell navigation。
  子语言同优先级重叠时，未使用原生私有 `_subpriority`，尚不能保证所有重叠效果一致。
- 完整输出仍需解析；只限制查询和绘制范围，不承诺比 injection 更快。
- `tests/host_highlight.lua` 验证 UTF-8、query metadata、循环、未执行分支、多行 YAML、
  视口范围、旧快照拒绝，以及开关切换。
- `tests/host_highlight_ui.lua` 分配真实伪终端，对比映射后文本与原生 Lua 字符串的
  `screenattr`，并验证滚动到第 250 行仍有相同颜色，以及未执行文本与真实 Comment
  的前景和样式一致。

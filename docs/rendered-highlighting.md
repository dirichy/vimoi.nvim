# 渲染结果高亮实现

`highlight.mode = "rendered"` 停用 source 上的宿主 injection，保留 gotmpl 自身的
高亮。默认模式为 "rendered"，可在同一会话中通过 setup 切换到 "injection"。
模式 "disabled" 同时关闭宿主 injection、渲染高亮和 Vim syntax 回退，保留模板
action 的高亮及背景，不关闭诊断或 source map。

## 渲染与生命周期

`render/init.lua` 按 source/context 管理异步渲染和 120ms debounce，视图、高亮和诊断复用同一计算链。
诊断发布和渲染高亮分别由开关控制。静态文本修改复用骨架渲染结果，重新恢复当前原文及映射。

每个 source buffer 对应唯一的只读 output buffer，preview 直接展示它，diff 读取它的映射及文本，
高亮使用它的原生 parser，宿主诊断也在同一个 buffer 上运行 LSP/lint。映射范围、行索引、
文本长度和版本保存在 output 状态中；高亮不再保留完整 source/output 文本快照。
单独高亮时不设置
filetype、不启动 provider；预览和宿主诊断按需设置宿主 filetype。新旧 output 做 line diff，每个 hunk 再缩小到实际改变的
字节范围，复用 merge 的 `buffer_edits.apply()` 写入。原生 buffer parser 接收编辑事件，
保留旧语法树并进行增量解析；相同 output 不写 buffer、不重新建树。首次或大范围更新
仍可能需要较多解析工作；目前 `parse(true)` 是同步调用。

编辑或 context 变化后，继续保留已显示的持久 extmark；Neovim 自动调整它们的位置。
旧 snapshot 的坐标只在 changedtick 和 context 仍匹配时用于创建新标记，避免把旧坐标
用到新文本上。等待渲染期间，新滚入且未缓存的区域可能暂时没有宿主颜色；临时模板
语法/渲染错误保留上一次成功的高亮。成功渲染后才替换颜色。卸载 buffer、切换模式或
改变宿主语言会清理标记；关闭窗口只清理对应视口的标记。output 由 source 生命周期统一管理，
关闭预览或高亮不会删除它，卸载 source 时才清理。

## 查询与绘制

使用原生宿主 parser、highlights query、`@capture.language`、priority、普通 conceal、
spell 和 URL metadata，再通过 source_map 投射到 source。与原生 Tree-sitter 的临时
高亮不同，这里使用持久 extmark，让原生机制在等待渲染时保留颜色及移动范围。

source 的 decoration provider 只使用 `on_win` 来观察可见范围。当前快照与视口未变时
不重新查询、不重新设置标记。需要更新时，将 source 可见范围映射到 output 行范围，
查询所有相关语言子树，先与 included ranges 相交，再与静态映射相交，转回 source。
跨模板 action 的 capture 拆成多段，不覆盖 gotmpl。新视口的标记全部建立后，才删除
该窗口上一份标记。各窗口分别维护有限的视口结果，不对整个文件预先创建高亮标记。

同范围、同优先级且 metadata 相同的 capture 合成一个 `hl_group` 数组，按 query
顺序叠加，后者覆盖前者。持久 extmark 之间不能依赖创建顺序解决同优先级冲突；
分别创建会使 Lua table key 的 `@variable`/`@property`、YAML key 的
`@string`/`@property` 在编辑及滚动后出现不稳定覆盖。

持久 extmark 使用 `right_gravity = false`、`end_right_gravity = true` 和
`invalidate = true`。在范围内输入时旧样式自然扩展；完全删除的范围隐藏，原生 undo
可以恢复其位置。没有额外的位置锚点或逐帧复制高亮的 `on_range` 回调。

快照更新时调用 `nvim__redraw({ buf = source, valid = false })` 唤醒可见窗口，刷新其
视口结果。终端测试不主动 `redraw!`，直接检查正常异步更新后的屏幕样式。

2000 行 YAML、30 次单行局部修改的本机实测：重新创建 string parser 的中位数为
6.34ms，持久 buffer 更新（包含 diff、局部写入及解析）的中位数为 3.62ms。该测量
不包括 chezmoi 渲染和屏幕绘制，不能据此推断整体编辑延迟；数据见
[highlight-incremental.json](benchmarks/highlight-incremental.json)。

## 限制与验证

- 动态输出没有对应的可编辑字符，不映射到模板 action。
- `literal_parts` 中没有任何 output occurrence 的非空静态区域，使用原生 `Comment`
  高亮，表示当前渲染未执行。包括条件分支和零次执行的循环体；不覆盖模板 action。
  同样按视口裁剪和缓存，缺少宿主 parser 时也会绘制 Comment。
- 循环重复区域取第一次执行，避免不同执行的颜色相互覆盖；例如第一次是注释、第二次
  是字符串时，source 使用注释颜色。首次执行的输出位置不必与源码顺序一致。
- define/block 为不透明整体标签，正文没有静态映射，因此不会投射宿主颜色；需要正文
  高亮时可使用 injection。调用输出仍按动态内容处理，不对应正文内部。
- 首次成功渲染前可能没有宿主颜色；初始模板错误不会生成高亮快照。
- 不投射 LSP semantic tokens，不实现原生的 conceal_lines 和 spell navigation。
  子语言同优先级重叠时，未使用原生私有 `_subpriority`，尚不能保证所有重叠效果一致。
- 增量解析收益取决于输出的实际变化；if/range 变化可能影响大量输出，不承诺比
  injection 更快。
- `tests/host_highlight.lua` 验证 UTF-8、query metadata、循环、未执行分支、多行 YAML、
  视口范围、旧颜色随编辑移动，以及开关切换。
- `tests/host_highlight_ui.lua` 分配真实伪终端，对比映射后文本与原生 Lua 字符串的
  `screenattr`，并验证滚动到第 250 行仍有相同颜色，以及未执行文本与真实 Comment
  的前景和样式一致，以及 debounce、换行和临时错误期间的颜色保留。
  Lua table key 和 YAML key 另外与原生 Tree-sitter 对照，在连续输入、撤销/重做及
  滚动过程中持续采样屏幕颜色，验证重叠 capture 的顺序稳定。
- `tests/host_highlight_incremental.lua` 验证 output buffer/parser 复用、分离的最小字节
  编辑、无修改时复用语法树、UTF-8、EOF 和模式切换清理。
- `tests/host_highlight_mapping.lua` 用独立原生查询和逐槽位穷举对照，验证整个文档与单行
  视口中的逐字节 capture/priority；覆盖首次执行乱序、跳过/重复、break/continue、
  define/block 多次调用及间隔文本、trim、UTF-8、YAML/JSON/TOML/shell、HTML 内的
  JavaScript 和 Markdown 内的 Lua，以及迭代顺序变化、反向滚动和多窗口关闭清理。
  TUI 测试另外将其中六种情况的实际屏幕颜色与原生完整输出逐项对照。

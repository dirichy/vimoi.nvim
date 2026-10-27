# 实验性标签收集回退

`lua/vimoi/parser.lua` 只有 `collect_template_tags(source)` 这个接口，返回零起点、右开
区间以及左右 trim 标志。普通 action 独立返回；define/block 与正文合成不透明区间，
保持现有 source map 的写回边界。

内部 tokenizer 流式返回有效的开闭分隔符，不建立 token 数组。它跳过 Go 的双引号字符串、
字符常量、原始字符串与注释中的伪分隔符；普通文本直接查找下一个 `{{`，正文里的引号或
反斜杠不会转义它。只在 define/block 内计数控制块嵌套，不建立表达式树、不处理变量作用域，
也不验证 pipeline。词法边界按 Go 的 text/template lexer 规则处理，trim 只识别
空格、tab、CR、LF。未闭合字符串、注释、action 或不透明定义返回错误，不能猜测边界。

`render/source_map.lua` 继续优先使用原生 Tree-sitter 及已有增量缓存；只有无法获得 gotmpl
parser 时才调用这个收集器。Tree-sitter 报出的语法错误不会被回退掩盖。回退是无状态的，
每次调用扫描完整 source，不另建 buffer 缓存或失效协议。表达式和控制语法由异步 chezmoi
执行校验；已有取消流程、source map、render 校验及静态写回规则不变。

没有 gotmpl parser 时，模板 source 保留 gotmpl filetype 和基础 action 样式。渲染结果的
宿主高亮仍可使用 Tree-sitter 或 Vim syntax。语法感知补全与模板函数引用跳转仍依赖
真实 AST，暂不为这些接口实现回退。执行错误按 chezmoi 提供的位置映射；缺少列号时，
只在候选标签唯一的情况下标记整个标签，不猜测函数或变量节点。

`tests/parser.lua` 将范围和 trim 与 Tree-sitter 对照，再强制缺少 parser 验证完整 layout；
覆盖字符串、字符、raw string、注释、四种 ASCII trim、负数、Unicode 和嵌套定义。
`tests/parser_fallback.lua` 对照完整渲染 trace，并验证无 AST 时的 diff、写回、预览和
执行错误恢复。`tests/parser_fallback_ui.lua` 在模板、宿主 parser 都缺失时复用原生
Vim syntax 的屏幕对照，检查映射、编辑、undo/redo、滚动与旧颜色保留。

参考：[Go text/template lexer](https://go.dev/src/text/template/parse/lex.go)。

# Blink 补全审计与优化

保持 Source.new/enabled/get_trigger_characters/get_completions、回调响应结构、取消语义和现有
completion 配置。工作区基线为 c3729e4，未增加补全结果缓存或新的 buffer 生命周期所有者。

## 先验证的问题

最小配置的 completion_audit 在原版确认：普通双引号/反引号字符串中的 .na 会给字段候选，
字符串里看似 include 的内容也会触发路径处理；未知字符串参数请求 data。字段补全一次
调用全 buffer 读取一次，并深拷贝整份 data 一次。新增回归同时覆盖转义引号、假分隔符、
无 parser fallback、路径请求路由、响应可变对象隔离以及 managed buffer 的上下文覆盖。

## 最终实现

- Tree-sitter 分隔符直接返回行列与字节位置，删除 buffer_text + byte_to_position 的全文
  往返。当前行已经读过时直接切片，多行只读取当前动作。fallback 复用当前行内容并识别
  引号、转义、注释，不把字符串里的 {{ / }} 视为动作边界。
- data_for_completion 只浅拷贝根表及需要覆盖的 chezmoi 元数据，其他嵌套数据按只读共享。
  候选说明仍独立生成有深度、条目、字符串长度限制的预览，不修改缓存。分支变量名集合
  只包含布尔标记，else 时改为浅拷贝。
- 只有实际未闭合的路径字符串会进行路径补全，普通字符串与 rune 不给代码候选。保留
  include/template/includeTemplate/glob 的路径补全及多行 action、变量作用域、mask 行为。
- include/template/includeTemplate 直接使用 setup 已确定的 source_root；glob 目标路径及
  data 字段仍请求共享 data。无关字符串提前返回，不请求 data，也不准备运行上下文。
- 静态内建目录和 snippet 描述原来已是模块级数据，继续复用。带坐标的 CompletionItem
  每次独立创建，避免消费者修改或不同 buffer/cursor 的 textEdit 相互污染，不缓存响应。

无 parser 的变量名 fallback 仍扫描整个 buffer，保持其原有近似作用域行为；没有引入
changedtick 缓存或借用 source-map 渲染状态。首次 Tree-sitter 解析、变量作用域遍历、目录
枚举和 data 预览仍各有成本，不把本次结果解释为所有补全路径恒定耗时。

## 性能

```sh
python3 tests/run_completion_benchmark.py --runs 3
```

原版从固定提交归档到临时目录，两版交替串行运行独立 Neovim 进程各 3 次；每个进程
预热 8 次，记录 7 轮、每轮 32 次。数据以同一同步 stub 表示已加载缓存，输入相同并核对
候选 checksum。表中是每进程中位数的中位数，单位 CPU ms；不含 CLI/调度等待、首次
解析或 blink 菜单绘制，不据此承诺端到端收益。

| 输入 | 原版 32 次 CPU ms | 当前 32 次 CPU ms |
| --- | ---: | ---: |
| 单行、小 data | 0.201 | 0.143 |
| 单行、无关 data 含 10000 项对象 | 47.400 | 0.112 |
| 10000 行、小 data | 26.203 | 0.101 |

7 轮共 224 次字段请求中，Lua 全 buffer 读取和整份深拷贝均从 224 次降为 0；字段本身仍
需要 data，所以这组 data_requests 不变。普通字符串与 source/template 路径则由独立行为
测试确认不请求 data。大 data 测试是大量不相关子树，并非省略了候选预览工作。

原始记录：[基线](benchmarks/completion-before.json)、[当前](benchmarks/completion-after.json)。
112 项全套回归通过，最终读取路径调整后 completion/completion_audit/parser_fallback 再次
通过。LuaLS 使用真实 Neovim library 和全部诊断，既有诊断与本次诊断分别检查。

## chezmoi-template.nvim 本地对照复查

参考仓库克隆在被忽略的 .dev/reference/chezmoi-template.nvim，核对版本为
[0ef7791be27844a0fc0da0356467297e182e616e](https://github.com/dpezto/chezmoi-template.nvim/tree/0ef7791be27844a0fc0da0356467297e182e616e)。
具体对照其 [blink.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/0ef7791be27844a0fc0da0356467297e182e616e/lua/chezmoi-template/blink.lua)
和 [resolve.lua](https://github.com/dpezto/chezmoi-template.nvim/blob/0ef7791be27844a0fc0da0356467297e182e616e/lua/chezmoi-template/resolve.lua)。

| 项目 | 参考实现 | 本次保留的策略 |
| --- | --- | --- |
| 上下文 | Tree-sitter 根树解析，沿节点父链屏蔽字符串；使用当前窗口 | 根树分隔符及局部动作扫描，使用 Blink 给定 buffer/cursor，路径字符串为允许的例外 |
| 数据 | 首次读取 data 时同步 wait，flatten 全部叶子键并生成文档缓存 | 共享异步读取，只生成当前层匹配字段，限制预览大小 |
| 候选缓存 | data/action/block 缓存，返回时 deepcopy items，防止 Blink 修改缓存 | 静态描述已在模块中复用，响应按本次坐标新建，不增加响应缓存及失效规则 |
| fallback | 当前行最后一对分隔符正则，文档注明不处理字符串/多行 | 当前行扫描引号/转义/注释，保留近似变量作用域限制 |

因此不照搬全量 flatten 或缓存完整 CompletionItem 的方法：本插件还需要变量作用域、路径
补全、按 buffer 覆盖运行上下文和动态 mask；复用完整响应需要额外失效/坐标处理。双方
都保护响应的可变对象，本插件以独立构建实现，不需要再深拷贝共享静态目录。

新增非当前 buffer、关闭字符串后继续字段补全、raw 路径及 fallback trim 路径用例，
completion/completion_audit/parser_fallback 三项复查通过。未改变实现 API 或引入额外缓存。
本节为源码行为对照，未做不同功能模型之间的性能排名。

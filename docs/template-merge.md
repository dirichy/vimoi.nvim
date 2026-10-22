# Template merge mode

> 历史设计稿，部分方案已被替代。当前状态见 [FEATURES](../FEATURES.md) 和
> [README](../README.md)。实际使用哨兵槽位映射；静态写回由用户显式触发，只修改 buffer，
> 通过本地推算重建映射，不做候选重新渲染验证，也不在保存时自动合并。
> 自动 re-add 和复杂动态输出的反向合并已明确不做；动态修改由用户手动编辑 source。

## 目标

用户仍然编辑目标文件，以保留正常的文件路径、LSP、formatter 和项目上下文。保存模板
管理的文件时，插件尝试把用户对渲染结果的修改迁移到 source template。只有无法证明
安全的修改才进入交互式 merge mode。

这个过程必须是保守的：漏掉一次自动合并只会多一次人工处理，错误地改坏模板则可能
影响多台机器。

## 三种输入和一种输出

设：

- `S`（Source）：当前 source template。
- `B`（Base）：保存前由 `S` 渲染出的 target state。
- `M`（Modified）：用户保存后的目标文件。
- `R`（Result）：准备写回 source state 的新模板。

概念上这是一次三方合并：

```text
             S (template / ours)
            /
B (rendered base)
            \
             M (modified / theirs)

                   -> R (new template)
```

这里的 `S`、`B`、`M`、`R` 只表示本设计稿中的角色，不是 chezmoi CLI 的参数名。

## 为什么不直接套用 `diff(S, B)`

`B -> M` 能准确描述用户改了什么，但 hunk 的行号不能直接用于 `S`。模板表达式、条件、
循环和 include 会使 `S -> B` 出现替换、插入或删除。若用户修改落在这些区域，直接把
渲染值写入 `S` 会破坏模板语义。

`diff(S, B)` 只能描述两份文本看起来哪里不同，不能判断一段相同文本究竟是静态文本、
模板表达式的输出，还是循环生成的重复内容。因此它不能作为 source 与 rendered output
之间的语义映射。

第一版就应解析 Go template。Neovim 通过原生 Tree-sitter API 使用 `gotmpl` parser；
`nvim-treesitter` 可以负责安装 parser，但 merge 核心不依赖它的 Lua API。parser 不可用时
应由 health check 说明原因，template merge 不应静默退化为不可靠的正则解析。

## Source map

映射分成两个阶段。

### 1. 语法映射

Tree-sitter 将 `S` 分为带 byte range 的节点：

- 静态文本节点：理论上可以原样出现在 `B` 中。
- 输出 action：其 source range 对应运行时生成的文本。
- 控制节点：`if`、`with`、`range`、`define`、`template` 等。
- 注释和 whitespace trim：不直接输出，但会改变相邻静态文本的有效范围。

这里得到的是 source span 及其父子、控制作用域关系，还没有 rendered span。

### 2. 渲染映射

按 source 顺序把静态文本节点与 `B` 中完全相同的片段做全局对齐，而不是逐个执行无上下文
的字符串搜索。对齐结果用于推导动态节点的输出边界：两个已确认静态锚点之间的 rendered
区间，归属于包含它们的最小动态或控制作用域。

映射不是简单的行号表，而是一组关系：

```text
source span -> zero, one, or many rendered spans
rendered span -> source span + kind + confidence
```

需要支持以下情况：

- 未执行的条件分支：source span 对应零个 rendered span。
- 普通表达式：一个 source span 对应一个 rendered span。
- `range` 循环：一个 source span 可能对应多个 rendered span。
- 重复的静态文本：必须依靠前后锚点和 AST 作用域消除歧义。
- include/template 调用：若未解析被调用模板，其输出先标记为 `unknown`。
- whitespace trim：按 `{{-` 和 `-}}` 缩小静态节点的有效 source span，哨兵插在待裁剪
  空白的内侧，避免改变原始渲染语义。

每条映射携带置信度：

- `exact`：边界由两个唯一静态锚点确定。
- `bounded`：能确定所属动态节点，但内部无法继续细分。
- `unknown`：include、解析错误或锚点歧义导致无法定位。

Tree-sitter 本身只能提供第一阶段。第二阶段仍然必须结合一次真实的 chezmoi 渲染；这是
语法树无法告诉我们的运行时信息。

当前 sentinel MVP 使用 `execute-template`，它与真实 target 渲染的上下文差异记录在
[render environment compatibility](render-environment.md)。任何自动写回功能都必须先验证
移除哨兵后的输出与 `chezmoi cat` 完全一致。

## 用户修改映射

在 source map 建立后计算 `diff(B, M)`。每个用户 hunk 会落入以下类别：

- `static`：完全落在一对一、`exact` 的静态映射内，可以迁移到 source。
- `dynamic`：落在表达式或控制节点的 rendered span 内，需要人工修改模板。
- `repeated`：对应循环产生的一对多映射，需要判断所有实例是否发生相同修改，否则冲突。
- `boundary`：跨越静态与动态边界，视为冲突。
- `unknown`：映射置信度不足，视为冲突。

一个用户 hunk 只有满足下列条件时才可自动迁移：

- hunk 完全位于 `exact` 的静态映射中。
- rendered span 与 source span 是一对一关系。
- 纯插入的前后位置映射到 source 中同一个连续边界。
- 多个 hunk 映射后不重叠。

不满足条件的 hunk 标记为冲突。安全 hunk 使用 byte range 从后向前应用到 `S`，得到
候选结果 `R`，避免前面的修改改变后续位置。行级 diff 只用于展示，内部映射使用 byte
range，以便精确标记行内模板表达式。

### 示例：可以自动迁移

```text
S: color = "{{ .theme }}"     B: color = "dark"     M: color = "dark"
S: timeout = 10               B: timeout = 10        M: timeout = 20
```

第二行在模板和渲染结果中完全相同，因此 `timeout = 10 -> 20` 可以安全迁移。

### 示例：必须冲突

```text
S: user = "{{ .username }}"   B: user = "alice"     M: user = "bob"
```

插件不知道用户想把模板变量改成常量、修改数据源，还是换一个模板表达式，因此不能自动
决定。

## 保存流程

1. 打开文件后识别其 source path，并取得 `S` 和当时的 `B`。
2. 用户照常编辑目标文件；插件不改变 buffer 名称或内容。
3. `BufWritePost` 后取得 `M`，计算安全 hunk 和冲突 hunk。
4. 没有用户变化时直接结束。
5. 所有 hunk 都安全时生成候选 `R`，执行渲染验证。
6. 存在冲突或验证失败时打开 merge mode，不修改 source template。
7. 用户确认结果后才原子地写入 source state。

需要为每次任务记录 source 内容摘要和 buffer `changedtick`。若 merge 期间 source template
或目标 buffer 已再次变化，当前结果立即过期，必须基于新状态重算。

## 渲染验证

自动写回前必须验证候选模板：

- 模板可以被 chezmoi 正常渲染。
- 候选模板的渲染结果与当前 `M` 完全一致。
- source 文件从读取以来没有被其他进程修改。

若无法在不改动真实 source 的情况下让 chezmoi 渲染候选文件，第一版应降级到 merge
mode，而不是采用“先覆盖、失败再恢复”的方式。

## 两窗口三文件 diff mode

参与比较的仍然是 `S/B/M` 三份数据，但 rendered base `B` 是内部数据，不单独占用窗口。
默认只显示用户需要操作的两份文件：

```text
+------------------------------+------------------------------+
| Source template (S)          | Modified target (M)          |
| editable                     | real target buffer           |
+------------------------------+------------------------------+
             hidden: Rendered base (B)
```

`vim.text.diff(B, M)` 产生真正的增删改 hunk。目标窗口直接标记这些 hunk，并用 virtual lines
显示已经从目标中删除、但仍存在于 rendered base 的内容。随后通过 sentinel source map
将每个 hunk 投影到 `S`。

两个窗口使用同一个 source-map 模型创建 extmark：

- Source 中标出模板 action、静态锚点和冲突节点。
- Modified 中标出 `B -> M` 的用户 hunk，以及它被分类为 static/dynamic/repeated 的原因。
- 后续可在任一侧移动光标时同步突出另一窗口中的对应范围。

每个冲突 hunk 提供以下操作：

- `keep-template`：保留 source template 的对应内容。
- `take-target`：使用目标文件内容；若会替换模板表达式，必须明确警告。
- `edit-result`：跳到 Result 中手工改写模板。
- `next-conflict` / `prev-conflict`：在冲突间导航。
- `render-preview`：渲染当前 Result 并与 Modified target 比较。
- `confirm`：验证通过后写入 source。
- `abort`：关闭界面，不修改 source；目标文件仍保留用户刚才的修改。

extmark 只投影视图状态并跟随 Result 的编辑移动。真实映射保存在独立的数据模型中，
不能反过来从 extmark 推断合并结果。

## 建议配置

```lua
require("vimoi.api").setup({
  template_sync = {
    -- "safe": 自动迁移安全 hunk；有冲突时打开 merge mode
    -- "prompt": 每次先询问
    -- "off": 不处理模板目标文件
    mode = "safe",
    open_on_conflict = true,
    require_exact_render = true,
  },
})
```

## 第一版边界

- 只处理文本文件；展示可以按行，内部统一使用 byte range。
- 依赖 `gotmpl` Tree-sitter parser 解析 source，但不重写 AST。
- 动态区域可以精确显示其 source/rendered 范围，但第一版仍由用户决定如何修改模板。
- 一对多映射、include 和无法唯一对齐的区域默认视为冲突。
- 依赖 `.chezmoi.sourceFile`、`.chezmoi.targetFile`、`.chezmoi.command` 或
  `.chezmoi.args` 的模板暂不支持自动映射。
- 自定义 template delimiter 暂不支持。
- 不自动修改 `.chezmoidata` 来满足目标内容变化。
- 不在 merge 成功后自动 commit、push 或 apply 其他文件。

## 实现顺序

1. 定义 source-map 数据结构以及 `S/B/M` 快照和摘要。
2. 用 `gotmpl` parser 提取 source span、作用域、trim 信息，并添加 fixture 测试。
3. 实现静态锚点与 `B` 的全局对齐，覆盖条件、循环、重复文本和 include。
4. 完成两窗口 diff 视图，将隐藏的 `B -> M` diff 投影为跨窗口 extmark。
5. 加入 `B -> M` hunk 分类以及可编辑的 Source/Result buffer。
6. 接入候选模板渲染验证和原子写回。
7. 最后才启用无冲突时的自动 source 写回。

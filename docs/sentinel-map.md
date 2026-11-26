# 哨兵位置索引

当前保留平行数组，暂不实现节点对象、树、增量槽位更新或内容 interning。
已有 Tree-sitter 语法增量收集、骨架执行复用和共享 session 生命周期不变。

## 恢复与消费者边界 / Restoration and consumer boundaries

`restore` 只在全部哨兵解码成功后提交重复类型和输出字段；返回失败时 prepared 对象保持
原样，可以重试。成功后仍原地完成同一对象，重复调用直接返回已有结果。
重复类型通过解码成功后再遍历一次已有 `output_slots` 提交，增加一次线性遍历，不增加数组。

`source_parts(map, first?, last?)` 按源码顺序返回槽位、源码起止字节、首次输出字节和是否
重复。首次输出为 nil 表示跳过，0 是有效输出位置。省略边界会包含全部空字面量锚点；
视口查询保留起点二分，不扫描视口前的槽位。merge 和 highlight 共用这一路径，不自行
解读 `output_indices` 对字面量、TAG/TRIMMED 的不同含义。TAG 的源码边界仍是公开的
平行数组数据，merge 按快照读取动作文本，不新增动作索引或缓存。

session 的 `set_prepared` 统一切换骨架执行键、取消旧请求并失效执行结果/错误。
字面量修改保留相同执行键及在途请求；等待新结果期间保留最后成功的 map/output。
恢复建图、全量字面量扫描仍是线性复杂度；点查询和视口起点仍是二分，无新增持久数据。

`restore` commits repeated kinds and output fields only after every sentinel decodes successfully.
A failed call leaves the prepared object unchanged for retry. Successful restoration still completes
the same object in place, and subsequent calls return that completed result.
Committing repeated kinds takes one additional linear pass over the existing `output_slots`, with no
additional array.

`source_parts(map, first?, last?)` yields slot, source start/end bytes, first output byte, and repeated
status in source order. A nil output means skipped; zero is a valid output position. Unbounded
iteration includes empty literal anchors. Viewport queries retain binary search at the start.
Merge and highlighting share this query instead of interpreting the overloaded `output_indices`.
Tag source boundaries remain public parallel-array data; merge reads action text from its snapshot.

The session's `set_prepared` owns execution-key changes, cancellation, and result/error invalidation.
Literal edits retain the same key and pending request; the last successful map/output remains while
new results are pending. Restoration and full literal scans remain linear, point queries and viewport
starts retain binary search, and no persistent index, cache, or abstraction layer is added.

## 数据

| 字段 | 含义 |
| --- | --- |
| `source_bytes` | 源码槽位起点，末尾多一项结束边界；end 直接取下一个起点 |
| `source_types` | LITERAL、REPEATED、TAG、TRIMMED 或 BOUNDARY |
| `trim_flags` | TAG 的两位标记：1 左 trim，2 右 trim，3 两侧 trim |
| `output_indices` | 字面量首次执行或 0；动作/trim 的右侧输出锚点；边界自身的执行 |
| `output_bytes` | 输出顺序的位置，含虚拟 BOF/EOF |
| `output_slots` | 每个输出位置对应的源码槽位 |
| `source_starts/output_starts` | 两侧行首索引，用于字节与行列转换 |
| `source_size/output_size` | 两侧字节长度 |

所有字节从 0 开始，范围左闭右开，数组与哨兵序号从 1 开始。空字面量和首尾定位槽位可
产生重复起点；源码二分取起点不大于查询位置的最后一个槽位。没有逐槽位对象、length、
end、text、精确执行次数或 occurrences，也没有独立 first/next 数组和 tail_source。

控制关键字不存入 map。merge 用到时从本次 trace.source 快照按动作边界取原文，调用
source_map.action_keyword，再识别 if/range/with/else/end。解析空 block/嵌套结构也共用
同一个头部识别函数，保留 trim 空白及 Unicode 标识符边界规则；不新增 control 缓存。
例如空 if 中插入文字，放在体外会始终输出，放在体内受条件约束，merge 因而需要识别
控制关键字；普通 {{ .name }} 不属于控制动作。滚动和高亮不进行这些按需识别。

例如源码 `A{{ "XYZ" }}B` 输出 `AXYZB`：

```lua
source_bytes   = { 0, 0, 1, 12, 13, 13 }
source_types   = { BOUNDARY, LITERAL, TAG, LITERAL, BOUNDARY }
trim_flags     = { [3] = 0 }
output_indices = { 1, 2, 3, 3, 4 }
output_bytes   = { 0, 0, 4, 5 }
output_slots   = { 1, 2, 4, 5 }
```

## 全流程与缓存

1. source session 监听 buffer 更新。source_map 使用 parser 的 on_bytes/on_changedtree 调整
   原始动作范围、局部收集语法；词法 fallback 进入同一个槽位构建路径。define 仍不透明；
   非空 block 正文透明，空 block 保留原文，避免改变 Go 的空定义语义。
2. 根据动作范围建立源码起点、类型和动作属性数组。被裁剪空白独立占槽位；每个动作间隙
   保留一个字面量，即使长度为 0；首尾各补零长度定位槽位。不构建中间节点对象。
3. prepare 从本次 source 字符串快照取动作原文，字面量换成稳定序号的哨兵。trim 空白不
   输出，虚拟 BOF/EOF 不进入 CLI 骨架。临时 sentinel_slots 把序号关联到源码槽位，增删
   trim 槽位不改变骨架；skeleton_starts 保存动作在骨架中的位置，供模板错误定位。
4. 骨架与上下文未变时复用 rendered_skeleton；否则由 session 异步执行 chezmoi。
   CLI 共享执行缓存、取消和过期请求检查保持原有所有者，不额外增加缓存层。
5. restore 先补虚拟 BOF，单次扫描执行后的骨架，恢复文字并追加 output_bytes/output_slots。
   字面量按需从 source 快照切取，在一次解码内复用，不逐次访问实时 buffer。首次执行填
   output_indices，重复执行标记 REPEATED，最后补 EOF。
6. 逆序维护右侧最早执行下标：字面量保留首次执行或 0；TAG/TRIMMED 填入右侧锚点。
   单个 output_indices 承担直接映射与动态范围兜底，不再给字面量保存 next。
7. session 更新共享只读输出 buffer，发布数组、行首索引、tick、路径及上下文版本。
   操作快照共享这些数组，只在操作期间读取全文；等待新结果或失败时保留上次成功输出，
   消费者按版本判断是否可查询旧 map。槽位和映射仍然全量建立，不声称已有增量更新。

## 查询

| API | 方法 | 成本 |
| --- | --- | --- |
| `source_slot(map, byte)` | 二分源码起点，重复起点取最后一个 | O(log P) |
| `source_span(map, byte)` | 字面量首次执行；动作/trim 用自身右锚点构造动态范围 | O(log P) |
| `output_position(map, byte)` | 二分输出位置，计算文字偏移或动态间隙 | O(log E) |
| `source_parts(map, first, last)` | 二分视口起点，迭代相关字面量 ID | O(log P + V) |
| `regions(map, first, last)` | 二分输出边界，局部生成字面量和间隙范围 | O(log E + K) |

未执行字面量的 output_indices 为 0，读取紧邻后续槽位的锚点兜底；切分保证后面是动作、
trim 或 EOF，不需扫描。动态范围由右锚点 k 与其前一条输出执行 k-1 构造，最后检查
查询点确实落在其源码范围内。虚拟边界保证邻接记录存在，不新增可编辑静态范围。

diff/诊断使用局部 regions，高亮按视口选字面量首次执行颜色，未执行文字用 Comment。
merge 保留重复/歧义写回限制，按需识别控制关键字；模板错误则使用临时骨架位置。
不缓存全量 range 表，rendered_regions 仅在明确请求全量投影时展开。

source EOF 与 output EOF 明确对应，空输出的 byte 0 也按 EOF 处理。旧 tail_source 把普通
文字 abc 的输出 EOF 映射到源码 byte 0 的历史最近锚点规则已删除。首尾锚点不改变 CLI
输出、骨架缓存键或空定义判定。

## 阶段性能记录

下方保留各阶段对照。混合版仅作为历史实验，当前以开头及“恢复平行数组”一节为准。

## 原哨兵索引与 range 基线对照

基线为 `5237e8152c37834daff49d2a4f653b217abd615f`，对照为平行数组重构前的哨兵索引实现。
同机 Linux、Neovim 0.12.6、chezmoi 2.74.2，两个版本使用相同生成输入和空白工作目录。

以下是重构前保存的历史结果；当前命令会比较当前实现，不能重新生成这一历史表。

```sh
python3 tests/sentinel_query_benchmark.py
```

脚本将基线归档到临时目录，交替、串行运行两版独立 Neovim 进程，各 3 次；不并行执行
其他测试。每个进程的定位测试预热 4 轮、记录 8 轮，每轮 512 次不重复命中光标行缓存的
查询。下表为各进程中位数的中位数，单位 ms；“旧 → 新”。两版所有查询结果校验值一致。

| 输入 | 512 次 source → output CPU | 512 次 output → source CPU |
| --- | ---: | ---: |
| 普通文本（2000 行，1 个槽位） | 0.315 → 0.313 | 0.127 → 0.112 |
| 200 个标签 | 0.253 → 0.240 | 2.065 → 0.117 |
| 2000 个标签 | 1.506 → 0.252 | 18.693 → 0.152 |
| 10000 个标签 | 16.248 → 0.353 | 120.649 → 0.194 |
| 200 行循环执行 30 次 | 0.380 → 0.193 | 9.545 → 0.153 |
| 2000 组跳过/执行分支 | 35.995 → 0.272 | 49.794 → 0.174 |

建图列包括缓存语法下的 prepare、哨兵解码、索引和行表生成，不含进程；CPU 时间只统计
Neovim。端到端列包括同一异步 notify 路径的 prepare、未缓存的 chezmoi 执行、解码和建图，
预热 2 次、记录 5 次；不含编辑 debounce、buffer 写入、宿主 parser 或屏幕重绘。

| 输入 | 建图 CPU ms | 含 CLI 的端到端 wall ms |
| --- | ---: | ---: |
| 普通文本（2000 行，1 个槽位） | 0.080 → 0.053 | 27.49 → 22.69 |
| 200 个标签 | 0.143 → 0.186 | 17.41 → 24.41 |
| 2000 个标签 | 0.951 → 0.869 | 28.52 → 39.11 |
| 10000 个标签 | 5.321 → 5.723 | 54.81 → 41.82 |
| 200 行循环执行 30 次 | 1.302 → 1.073 | 21.36 → 32.45 |
| 2000 组跳过/执行分支 | 2.512 → 2.345 | 46.54 → 41.53 |

大规模点定位的收益明确；简单/小输入的 source 查询差异很小。索引不是零成本：万标签
输入的建图 CPU 约增加 0.40ms，循环和跳过分支的建图则有所下降。端到端受进程和调度
影响，在多轮试跑中方向会变化，因此不据此承诺整体编辑或渲染提速。

平行数组重构前，实现代码相对 range 基线净增 87 行 Lua，不含测试和文档。维护成本主要是二分查询、跳过分支的后缀索引和
边界投影；相应删除了整份执行 range/region 缓存及各消费者的重复扫描。没有新增缓存层。

逐进程统计及环境信息见 [基线记录](benchmarks/sentinel-query-before.json) 与
[哨兵索引记录](benchmarks/sentinel-query-after.json)。记录保留每个独立进程的中位数，
不代表所有平台或输入的性能保证。

## 验证

`tests/sentinel_queries.lua` 用独立的旧式全量 range/线性查找算法，逐字节核对源码定位、
输出定位和区间边界，覆盖分支跳过、重复、执行乱序、break/continue、trim、UTF-8、空哨兵
和 EOF。其余 diff、merge、诊断、高亮、真实终端和共享 source session 回归继续复用。

## 平行数组与对象哨兵表对照

对照为本轮修改前的完整工作区快照 `/tmp/vimoi-before-arrays`，不是上面的 range 提交。
两个版本使用相同脚本与输入，各在独立 Neovim 进程中串行执行 3 次。脚本同时核对全部
source/output 查询校验值；建图与查询使用局部 CPU 时间，包含 CLI 的渲染使用 wall time。

```sh
python3 tests/sentinel_query_benchmark.py \
  --baseline-dir /tmp/vimoi-before-arrays --output-prefix parallel-arrays --runs 3
```

下表为“对象哨兵表 → 平行数组”，查询列均为 512 次的总 CPU ms：

| 输入 | source → output | output → source | 建图 CPU ms | map 分配 KiB |
| --- | ---: | ---: | ---: | ---: |
| 普通文本 2000 行 | 0.315 → 0.299 | 0.123 → 0.125 | 0.050 → 0.063 | 30.2 → 30.5 |
| 200 个动作 | 0.224 → 0.191 | 0.132 → 0.102 | 0.174 → 0.185 | 130.9 → 26.9 |
| 2000 个动作 | 0.242 → 0.214 | 0.153 → 0.132 | 0.897 → 1.129 | 1282.5 → 240.9 |
| 10000 个动作 | 0.356 → 0.255 | 0.195 → 0.155 | 5.772 → 6.726 | 6656.5 → 1792.9 |
| 200 行循环 30 次 | 0.193 → 0.187 | 0.150 → 0.125 | 1.110 → 0.895 | 939.6 → 212.9 |
| 2000 组跳过/执行分支 | 0.277 → 0.166 | 0.183 → 0.151 | 2.335 → 3.652 | 3551.8 → 880.2 |

map 分配量是已缓存语法和公共字符串存在时，再创建一份发布映射，GC 后增加的 Lua 堆
用量；保留与 session 相同的槽位、执行与行首数组，排除完整文本、骨架及临时 trace。
它衡量映射的增量常驻分配，不是整个 Neovim 的 RSS，也不包含公共字符串的总占用。
普通文本的空间几乎全在行首数组；其余样例减少约 73%–81%。

大输入定位更快，但建图不是全面改善：万动作多约 0.95ms，分支样例多约 1.32ms；循环
样例少约 0.22ms。阶段对照表明，统一槽位的解析/骨架准备成本上升，循环解码受益于
取消逐执行对象。曾实测临时保存全部槽位文本，解码虽变快，额外数组抵消了部分收益；
最终使用按需切片并在一次解码内复用文字，不让查询路径读取 buffer 或扫描空白。

包含 CLI 的渲染中位数如下，单位 wall ms；跨轮方向仍会变化，不据此承诺端到端提速：

| 输入 | 对象哨兵表 | 平行数组 |
| --- | ---: | ---: |
| 普通文本 2000 行 | 23.26 | 27.43 |
| 200 个动作 | 27.79 | 28.35 |
| 2000 个动作 | 37.05 | 45.74 |
| 10000 个动作 | 57.51 | 53.72 |
| 200 行循环 30 次 | 25.19 | 22.33 |
| 2000 组跳过/执行分支 | 56.47 | 45.78 |

可读性方面，源码定位统一为二分 `slot_starts`，没有数值打包的 meta，重复状态直接由类型
表达；结束位置统一取相邻边界。代价是消费者要区分槽位下标与执行下标，merge 原始文字
间隙需跳过动作/trim 分类，临时哨兵序号还需关联槽位以保持骨架稳定。没有增加兼容层或
新的缓存所有者。旧对象形状只在测试 helper 中重建，用于独立线性 oracle 和既有期望值。

仅统计 `lua/`，包含注释和类型说明，不含测试、文档：提交基线 7639 行，对象哨兵版
7726 行，平行数组版 7761 行。因此本轮净增 35 行，相对提交净增 122 行，并非行数减少。

原始记录：[对象版](benchmarks/parallel-arrays-before.json)、
[平行数组版](benchmarks/parallel-arrays-after.json)。原有 111 项回归全部通过，并增加源码
覆盖、trim 槽位、重复起点、首次执行/重复状态和后缀索引的独立校验。LuaLS 保留真实
Neovim library 与全部诊断；与修改前相同的 5 项 `core/cli.lua` 诊断仍在，本轮无新增。

## 混合版实验对照（已撤回）

基线为上一轮工作区平行数组版快照 `/tmp/vimoi-before-index-cleanup`，对照为当时的混合版。
两个实现独立进程交替运行各 3 次，输入和脚本相同。因 EOF 行为有意改变，双方定位样本
排除末尾仅代表 EOF 的行；EOF 则由逐字节行为测试单独校验，其余查询校验值一致。

```sh
python3 tests/sentinel_query_benchmark.py \
  --baseline-dir /tmp/vimoi-before-index-cleanup --output-prefix final-hybrid --runs 3
```

下表为“上一轮全数组 → 最终混合版”；查询是 512 次总 CPU ms，map 为 GC 后增量常驻 KiB：

| 输入 | source → output | output → source | 建图 CPU ms | map KiB |
| --- | ---: | ---: | ---: | ---: |
| 普通文本 2000 行 | 0.149 → 0.178 | 0.069 → 0.077 | 0.034 → 0.040 | 31.3 → 30.4 |
| 200 个动作 | 0.226 → 0.259 | 0.111 → 0.134 | 0.215 → 0.229 | 26.9 → 76.6 |
| 2000 个动作 | 0.209 → 0.209 | 0.130 → 0.128 | 1.149 → 1.077 | 240.9 → 723.5 |
| 10000 个动作 | 0.255 → 0.292 | 0.151 → 0.154 | 7.002 → 6.450 | 1792.9 → 4193.1 |
| 200 行循环 30 次 | 0.197 → 0.204 | 0.119 → 0.119 | 0.924 → 0.898 | 212.9 → 262.4 |
| 2000 组跳过/执行分支 | 0.163 → 0.164 | 0.142 → 0.152 | 3.731 → 3.494 | 880.2 → 2217.8 |

最终混合版以可读性和职责分离为取舍，没有全面减少内存：动作/分支密集输入约为纯数组
的 2.3–3 倍；循环样例只多约 49 KiB。大输入建图下降约 3%–8%，点查询仍为微秒级，
小输入有轻微回退。CLI wall time 在多轮中有涨有跌，不以它证明整体渲染提速。

仅统计 lua/，含注释与类型说明、不含测试文档：上一轮 7761 行，最终 7768 行，净增 7 行；
相对提交基线净增 129 行。source_map 的 EOF 和边界逻辑缩短，但不可变节点、flatten
数据和虚拟锚点需要明确描述。内容节点不含位置和执行状态；不为未来增量增加树或缓存。

111 项回归通过，新增/调整校验覆盖不可变长度节点、单 output_indices 的两种含义、虚拟
边界不改变骨架/真实范围、EOF 双向规则，以及旧语法和 merge 场景。格式检查与 LuaLS
继续使用真实 Neovim library、全部诊断；本轮无新增诊断。

原始数据：[全数组基线](benchmarks/final-hybrid-before.json)、
[最终混合版](benchmarks/final-hybrid-after.json)。

## 恢复平行数组（移除 controls 之前）

最终选用平行数组，撤回源码节点对象和长度字段；保留混合实验中独立验证过的统一
output_indices、虚拟首尾定位、EOF 双向对应及删除 tail_source。没有实现树、增量槽位或
内容缓存。control 仍为按 TAG 槽位索引的稀疏关键字表，直接服务 merge 的候选位置判断。

以相同万动作输入，独立进程逐字段清除并完整 GC 的内存拆分估算：原数组约 1.75 MiB，
混合实验约 4.09 MiB，当前约 1.50 MiB。差异主要是取消逐槽位 table，同时把两组执行索引
缩为一组；数据不包含公共文本、语法缓存及临时 trace，也不是 Neovim RSS 或瞬时分配量。
本轮仅重测内存，不将它用于推断 CPU 或端到端耗时。

111 项回归、修改文件格式检查通过，LuaLS 无新增诊断（原有 core/cli.lua 诊断保留）。
实现 Lua 从混合实验的 7768 行变为 7764 行，净变动 -4 行，不含测试文档。

原始内存拆分见 [最终数组内存记录](benchmarks/final-arrays-memory.json)。

## 控制关键字按需识别

进一步移除了临时 tag_controls、常驻 controls 和 session 发布/快照中的对应字段。
source_map.action_keyword 复用原有的动作头部识别逻辑；解析阶段只用返回值维护结构栈，
merge 阶段从已持有的源码快照取动作，按需识别控制关键字。不缓存调用结果，也不读取
实时 buffer。原本的控制关键字白名单只在 merge 中保留一份。

## 最终提交基线对照

当前选用平行数组与按需控制关键字识别。以下对照固定提交基线
5237e8152c37834daff49d2a4f653b217abd615f，可直接通过默认命令复现：

```sh
python3 tests/sentinel_query_benchmark.py --output-prefix source-map --runs 3
```

两个版本独立进程交替串行运行各 3 次；查询样本排除 EOF 行以隔离有意改变的边界规则，
所有内部定位校验值一致，EOF 由行为测试独立验证。查询列为 512 次总 CPU ms，建图不含
CLI，map 列为排除公共文本、语法缓存和临时 trace 后的 GC 常驻增量 KiB。

| 输入 | source → output CPU ms | output → source CPU ms | 建图 CPU ms | map KiB |
| --- | ---: | ---: | ---: | ---: |
| 普通文本 2000 行 | 0.178 → 0.159 | 0.090 → 0.073 | 0.046 → 0.040 | 31.289 → 30.266 |
| 200 个动作 | 0.268 → 0.160 | 2.089 → 0.082 | 0.148 → 0.154 | 271.547 → 22.617 |
| 2000 个动作 | 1.442 → 0.210 | 18.697 → 0.126 | 0.967 → 1.110 | 2675.570 → 190.617 |
| 10000 个动作 | 10.819 → 0.265 | 116.255 → 0.152 | 5.495 → 6.481 | 13660.070 → 1535.930 |
| 200 行循环 30 次 | 0.397 → 0.211 | 9.876 → 0.119 | 1.310 → 0.905 | 4514.461 → 209.094 |
| 2000 组跳过/执行分支 | 23.266 → 0.160 | 38.314 → 0.146 | 2.819 → 3.193 | 6553.945 → 623.984 |

大输入点查询收益明确；万动作建图多约 0.99ms，循环则减少约 0.41ms。CLI wall time
跨轮仍有波动，不据此承诺整体渲染提速。最终 111 项回归通过，LuaLS 保留真实 Neovim
library 和全部诊断，无新增问题，原有 core/cli.lua 的 5 项诊断未屏蔽。

原始记录：[提交基线](benchmarks/source-map-before.json)、
[最终实现](benchmarks/source-map-after.json)。

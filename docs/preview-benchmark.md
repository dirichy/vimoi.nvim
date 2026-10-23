# 实时预览 benchmark 与功能缺口

日期：2026-10-22。对比当前工作区的 vimoi.nvim 与 dpezto/chezmoi-template.nvim
提交 `670ba83095ba6571f3125a5e5fd4118505a2c3c6`。

## 方法与范围

- 环境：Intel Core i5-14600K，Linux x86_64，Neovim 0.12.6，chezmoi 2.73.3。
- 每个场景、每个插件启动 3 次独立 Neovim，串行执行并交替顺序，避免两者争用 CPU。
  共 24 个进程；每次首次预览一次、静态编辑六次、修改模板表达式六次，共校验 312 次输出。
- 模板为约 200、2,000、10,000 行 YAML，包含分散的 `if/end` 控制块和一个可修改的
  `printf` 表达式。另测 2,000 行模板中实际执行 `{{ output "/usr/bin/sleep" "0.2" }}`，
  用已知的外部命令等待模拟慢 helper；不是密码管理器或网络服务实测。
- 使用空 chezmoi 配置和临时 source/target，每次以 CLI 完整渲染建立正确输出基准；未读取真实 dotfiles。
  两个插件的 source 和 preview 都启用 gotmpl/YAML Tree-sitter，高亮查询与运行时目录彼此隔离。
- 两边均关闭 diagnostics，专测共同具备的 preview；对方关闭 apply-on-save、格式化和图标集成。
  先打开 source，等待 200ms 完成 scheduled 高亮与对方自动 data 预热，再开始测首次预览。
  因此“首次”是当前进程第一次打开预览，不是冷 OS 缓存、插件 setup 或文件打开的总耗时。
- 刷新延迟从局部 buffer 编辑开始，计到预览最后一次对应的 `on_lines` 发布；每次确认完整输出
  正确才进行下一次编辑。保留默认 debounce：vimoi 为 120ms，对方为 150ms。
  每次测量前刷新 libuv 的缓存时钟，避免连续 Lua 调用中的旧时钟让定时器提前到期。
- 同时统计 chezmoi 进程调用，并以 5ms heartbeat 观察事件循环额外延迟。heartbeat 只是
  粗略响应性指标，不等于 CPU 时间或严格的最长阻塞时间。
- 这是 headless buffer 更新测试，不含屏幕实际绘制、输入法、用户其他插件或快速连续输入压力。
  不比较 diff/merge：对方没有等价的模板映射与反向写回工作流。

## 实测结果

单位 ms；表内均为中位数。首次每格 3 个样本，静态和表达式修改每格各 18 个样本。

| 模板 | 插件 | 首次预览 | 静态编辑刷新 | 表达式修改刷新 |
| --- | --- | ---: | ---: | ---: |
| 203 行 | vimoi | 23.7 | 121.3 | 152.8 |
| 203 行 | chezmoi-template | 19.7 | 177.7 | 179.9 |
| 2,003 行 | vimoi | 28.1 | 124.1 | 153.6 |
| 2,003 行 | chezmoi-template | 19.5 | 178.7 | 187.9 |
| 10,003 行 | vimoi | 35.1 | 131.7 | 166.8 |
| 10,003 行 | chezmoi-template | 35.7 | 199.9 | 200.2 |
| 2,003 行，200ms helper | vimoi | 236.0 | 123.5 | 357.8 |
| 2,003 行，200ms helper | chezmoi-template | 226.6 | 392.1 | 388.0 |

首次预览的最小–最大范围：

| 模板 | vimoi | chezmoi-template |
| --- | ---: | ---: |
| 203 行 | 21.8–24.8 | 18.1–21.5 |
| 2,003 行 | 26.7–28.4 | 19.0–20.9 |
| 10,003 行 | 31.5–36.5 | 30.3–40.3 |
| 2,003 行，200ms helper | 232.3–236.8 | 224.9–227.6 |

每次编辑中 heartbeat 额外延迟的中位数（不含首次预览；不是 CPU 耗时）：

| 模板 | vimoi 静态 / 表达式 | chezmoi-template 静态 / 表达式 |
| --- | ---: | ---: |
| 203 行 | 6.2 / 6.9 | 0.8 / 1.5 |
| 2,003 行 | 7.7 / 8.0 | 1.9 / 2.2 |
| 10,003 行 | 16.4 / 16.9 | 6.4 / 6.4 |
| 2,003 行，200ms helper | 7.2 / 8.7 | 1.6 / 2.1 |

### 相同 debounce 的对照

再将对方 debounce 调为 120ms，与 vimoi 相同，其余条件不变，另跑 24 个进程、312 次输出校验。
下表为中位数 ms；静态和表达式修改每格各 18 个样本。

| 模板 | vimoi 静态 / 表达式 | chezmoi-template 静态 / 表达式 |
| --- | ---: | ---: |
| 203 行 | 121.3 / 151.5 | 148.9 / 151.9 |
| 2,003 行 | 123.7 / 156.5 | 153.1 / 144.8 |
| 10,003 行 | 129.2 / 162.1 | 167.8 / 166.9 |
| 2,003 行，200ms helper | 123.8 / 362.5 | 360.6 / 356.4 |

## 如何理解结果

静态编辑时，vimoi 在所有样本中都没有启动外部渲染进程，对方每次启动一个。
模板表达式修改和首次预览时，双方每次都启动一个 `execute-template`。
因此慢 helper 的静态编辑收益来自避免重复执行，不能推广为所有编辑都能跳过 helper。

相同 debounce 下，普通模板的静态编辑优势约为 28–39ms；表达式修改差距约为 0–12ms，
2,000 行这一组是对方快约 12ms。慢 helper 的静态编辑差距仍超过 200ms，缓存收益依然存在。

首次预览需要建立 source map，小中模板里 vimoi 慢约 4–9ms，万行这一组接近；
首次样本每项只有三个，应结合范围解读。
默认编辑延迟还包含 120/150ms 的定时等待，不能直接将总耗时之比称为算法加速比，
也不能简单减去配置值就当作准确 CPU 耗时。大文件的映射维护也会增加主线程工作。

这组模板以静态内容和简单控制块为主，未覆盖大型循环展开、密集行内 action、trim、include
依赖更新、加密和真实密码交互。完整原文渲染也不受我们部分骨架语义限制；结果没有证明
骨架在所有模板上都更快或完全等价。此次没有据此修改生产代码。

## 调研时的功能缺口与当前状态

以下按实际工作流列调研时的缺口，最后一列记录后续实现或规划；已有功能换名字或换一种展示方式不算新的能力。
源代码依据和固定提交链接见 [插件对比](plugin-comparison.md)，规划状态见 [FEATURES](../FEATURES.md)。

| 功能 | 它的行为 | 我们当前的状态或建议 |
| --- | --- | --- |
| 独立 Source/Edit 和 Target 导航 | 不开 diff 即可跳转，显示/打开 target；Edit 参数补全受管理路径 | 已用单一 Toggle 在 source/target 间切换，可接收路径；目前用原生文件参数补全，尚无专用 managed-path 补全 |
| CLI apply 与保存后可选 apply | 应用当前文件，也可显式应用全部；默认保存后 apply | 显式当前文件 Apply 值得；保存后 apply 另行决定，不等同于 Diff Put/Get，也不同于自动 re-add |
| 受管理文件选择与列表 API | source/target 文件对列表，支持多种 picker 和原生回退 | 值得按需要补；先复用 vim.ui.select，不必照搬所有 backend |
| 非模板 source 的目标文件类型 | `dot_zshrc` 等普通 source 也按 target 识别 | 已加入，复用 CLI 路径缓存与 Neovim 初始化回调 |
| 共享模板保存后立即刷新预览 | 保存 `.chezmoitemplates/` 中任意文件会重渲染打开的预览 | 已复用失效事件自动延迟刷新打开的 diff/preview，也覆盖已监听的外部变化 |
| 模板块片段 | if/else、range、with、define、block、注释等完整片段 | 已通过 blink 提供标准 LSP snippet |
| 模板块 `%` 匹配 | vim-matchup 查询支持 if/else/end 和 trim 标记 | 已加入可选查询，无必需依赖，不自行覆盖按键 |
| 宿主语言格式化 | Conform 屏蔽模板、格式化宿主文本并恢复模板 | 有价值但需单独验证，不能直接套用运行时哨兵 |
| 透明加密 source 编辑 | 可选打开解密、保存重新加密，委托 chezmoi | 较大独立功能；需要设计读写失败、取消和明文持久化行为 |
| 目标文件图标 | mini.icons 显示真实 target 对应图标 | 可选外观集成，优先级较低 |
| data 值说明 | 补全文档展示值，配置字段模式遮盖敏感值 | 可选；我们目前显示字段类型，不显示实际值 |
| 打开 target 自动转到 source | 可选 redirect，默认关闭 | 有需要再加；它会改变原生打开文件的行为，不建议默认启用 |
| 预览横向分屏 | 可以选择 horizontal / vertical | 已加入 split 选项，diff/preview 共用 |

它还支持 preview 内直接标注相对磁盘 target 的差异、慢渲染后退回保存刷新以及 q/重复命令关闭。
这些属于不同的 UI 与刷新策略；我们已有原生 diff、缓存和主动取消，不应全部算成待补功能。
模板诊断、高亮、实时预览、路径跳转和基础补全双方都已有，也不列为缺失。

## 复现

需要本地已安装 gotmpl/YAML parser、chezmoi、Neovim 0.12 和 Python；无需安装第三方集成插件。
在项目根目录执行，checkout 参数指向上面固定提交的原始仓库：

```sh
python3 tests/run_preview_comparison_benchmark.py \
  --checkout /tmp/vimoi-plugin-comparison/dpezto-chezmoi-template.nvim \
  --output /tmp/vimoi-preview-benchmark.json
```

脚本：[Python runner](../tests/run_preview_comparison_benchmark.py)、
[Neovim 测量脚本](../tests/preview_comparison_benchmark.lua)。
原始样本：[默认 debounce](benchmarks/preview-2026-10-22.json)、
[相同 debounce](benchmarks/preview-matched-debounce-2026-10-22.json)。
复现后一组时加 `--match-debounce`；两组合计 48 个 Neovim 进程、624 次完整输出校验。

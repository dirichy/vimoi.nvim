# 首次 cat 校验并行化实测

日期：2026-10-25。对比提交 `9227cda` 中的串行构造与并行版本。

构造仍读取固定磁盘基线：先启动 cat，再准备和执行哨兵骨架，等两者输出后比较。
任何一侧失败或取消都会停止另一侧；buffer 编辑不打断构造。并行任务只在构造闭包内管理，
没有新增 session 持久状态字段或通用并行框架。运行时代码净增 38 行。
当时的内部 profile 曾拆分骨架完成后的额外 cat 等待；该计时现已移至独立 benchmark，
运行时不再保留 `last_profile` 或计时字段。下文历史数据测量的是 session 首次发布结果的总耗时。

## 测量方法

- Linux x86_64，Neovim 0.12.6，chezmoi 2.73.3；详细版本及原始样本见
  [JSON](benchmarks/cat-validation-2026-10-25.json)。
- 两版共用当前其他模块，只替换 `render/init.lua`；脚本读取历史 `gotmpl/session.lua`
  并仅迁移内部 require 与配置名称，不改变串行算法。使用 minimal headless 配置，
  关闭高亮和诊断，source、destination、配置及状态目录都在临时目录，不读取真实 dotfiles。
- 每个模板、每个版本运行 3 个独立 Neovim，交替串行/并行的测量顺序。每个进程预热 3 次、
  记录 15 次，总计每格 45 个样本。计时从注册 source 到首次发布有效 output；不含 setup、
  创建/读取 source buffer 和屏幕绘制。每次销毁 session 并清除模板执行缓存，模拟首次构造。
- 两版都实际执行 chezmoi；100 ms helper 使用 `output "sh" "-c" "sleep 0.1; printf hello"`，
  模拟可重叠的外部等待，不代表真实密码管理器或网络请求。
- 最后一轮基准独立运行，未同时执行回归测试或 LSP 检查。这是本机观察值，
  进程调度和 CPU 频率会影响结果，不应当作固定加速比例。

## 结果

单位 ms，均为中位数。

| 模板 | 串行 | 并行 | 减少耗时 | 耗时减少比例 |
| --- | ---: | ---: | ---: | ---: |
| 1 行简单模板 | 51.4 | 18.6 | 32.8 | 63.8% |
| 1,000 行、1,000 个 action | 66.6 | 36.1 | 30.5 | 45.8% |
| 1 行，外部命令等待 100 ms | 266.6 | 132.1 | 134.5 | 50.4% |

这项优化只影响 session 的首次构造，后续编辑本来就不重复 cat 校验。
慢 helper 的等待能明显重叠；普通模板的收益是本机约 30 ms。

复现：

```sh
python tests/run_session_validation_benchmark.py --baseline-ref 9227cda --output /tmp/cat-validation.json
```

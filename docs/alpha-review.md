# 首次 alpha 发布前检查

检查日期：2026-10-22。覆盖全部 Lua 模块、ftdetect、Tree-sitter 查询、测试、
中英文帮助、README 和功能规划。此次检查不包含 alpha tag 或 GitHub Release。

## 公开 API

保留现有命令、默认键位和配置名称，没有发现必须推翻的命名。
公开范围是 `setup()`、`:help vimoi-api` 列出的 `vimoi.api` 操作，以及
`vimoi.blink` 集成；其他模块、session 表、调试数据不是稳定接口。

- `diff`、`diff_files`、`preview` 始终返回 `nil`，内部 session 不再泄漏给调用方。
- `toggle(path?)` 成功返回打开的路径，遵循原生未保存 buffer 的保护机制。
- `put_hunk`、`get_hunk`、`readd` 是交互操作，只有立即完成时才有结果；等待渲染或
  选择时也返回 `nil`。目前没有完成回调或 promise，脚本不能据此判断最终是否成功。
- `readd` 的公开结果包括 `merged`、`skipped`、`reasons[].reason`；部分合并的原始
  hunk 可同时计入 merged/skipped，一个 hunk 可有多个跳过原因。内部 hunk 对象不承诺稳定。
- 进程/config 路径、watch、keymaps 首次成功 setup 后固定；其余可更新选项在后续
  setup 省略时恢复默认值。这个行为已在中英文帮助和 README 说明。
- `ReAdd` 将普通文件内容或模板静态修改写回 source buffer；Diff Put/Get 按当前窗口决定方向，
  分别送往另一侧或取入当前 buffer。
  二者都不会自动保存，也不是直接执行 chezmoi 的 re-add/apply。

暂时保留 `diff_files(source, target, opts)` 这个显式文件对入口；它和
`diff({ source = ..., target = ... })` 存在功能重叠，但参数意图清楚，没有为兼容增加别名。
alpha 若要提供程序化异步完成接口，应单独设计，不让脚本依赖内部 session。

## 本次修复

1. 精确按完整 buffer 名称查找文件。`bufnr(path)` 接受模式，曾把 `file[1]` 匹配为
   已打开的 `file1`，可能让 diff 选错 buffer。新增括号、通配符、美元符号、空格、
   管道字符及无关未保存 buffer 的回归测试。
2. 最后一个模板 diff 关闭后恢复用户原有 `diffexpr`；多个视图共存时保留共享处理器，
   再次打开时重新安装。覆盖其他 tab 的普通 diff、自定义处理器和关闭后重开。
3. checkhealth 只读取已配置的宿主语言，不再通过文件类型推断间接启动 chezmoi。
4. 错误的常用配置在 CLI/watch/keymap 一次性初始化前拒绝，修正后可以重新 setup。
   不承诺任意外部初始化错误都能事务回滚。
5. 新增仓库内的 `tests/run.py`，隔离每个测试的默认 chezmoi 配置、target、状态数据库
   和 Neovim 状态；测试不再依赖之前遗留在 `/tmp` 的渲染文件。
6. 补齐公开返回值、gotmpl parser 依赖和测试入口文档；忽略生成的日志、数据库及帮助标签。

## 验证

- `python3 tests/run.py`：81/81 通过；加强后的 diffexpr 生命周期测试另行通过。
- 一次并行全量运行中 `diff_async_open.lua` 超时；单独及 8 次并行重复运行均通过，
  后续全量运行也通过。没有靠增加超时或关闭断言掩盖，首次失败的具体原因尚未定位。
- LuaLS 使用真实 `/usr/share/nvim/runtime/lua`，检查到 Hint，零诊断。
- `stylua --check lua ftdetect tests` 通过。
- 中英文 `helptags`、本地 Markdown 链接、Python 脚本语法检查通过。

这些是当前 Linux 环境的检查结果，不代表已验证 Windows 或所有 chezmoi 2.x 版本。
没有因本次检查更改渲染算法，也没有新增性能收益的宣称。

## 仓库准备

- 用户确认采用 MIT，以 GitHub 用户名 `dirichy` 署名，已补齐 LICENSE。
- 仓库地址为 `https://github.com/dirichy/vimoi.nvim`，README 和中英文帮助已补充
  lazy.nvim 安装示例；用户已授权在文档复核通过后公开。尚未发布 alpha tag 或 Release。
- 检查时尚无 Git 元数据，随后按用户要求初始化 Git；已确认日志、状态数据库和
  生成的帮助标签被忽略，不进入初始提交。

骨架渲染、哨兵碰撞、复杂动态反向合并及缓存外部依赖的限制继续以中英文帮助的
limitations 为准；本次未扩大支持范围。

## 公开前文档复核

- README 增加快速开始、英文帮助入口和实测版本，移除重复的内部调度说明。
- 修正局部写入说明中过时的自动合并、候选渲染验证描述；历史设计与当前行为明确区分。
- README、中英文帮助的完整默认配置与源码一致；22 个 Lua 示例均可编译。
- 本地 Markdown 链接、代码围栏、中英文帮助标签及插件内帮助引用检查通过。
- 公开 API、默认键位、导航相关的 3 个测试脚本通过。本轮仅改文档，未修改功能代码。

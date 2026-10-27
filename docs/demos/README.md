# 功能实录

README 使用 GIF 直接展示，MP4 保留原始清晰度。录制使用独立 chezmoi source、target、配置和状态数据库，
不读取个人 dotfiles，不模拟补全或注入诊断。样式统一定义在 [common/settings.tape](common/settings.tape)。

## 场景

| 脚本 | 内容 |
| --- | --- |
| [diff.tape](diff.tape) | 循环展开后的双向同步滚动、原生折叠、do/dp、插入位置选择与撤销 |
| [readd.tape](readd.tape) | 双向同步滚动，批量写回静态修改并保留动态表达式 |
| [preview.tape](preview.tape) | 未保存模板实时预览、双向同步滚动、分支切换、撤销和错误恢复 |
| [highlighting.tape](highlighting.tape) | rendered 宿主高亮、未执行分支、撤销恢复及模板 action 背景 |
| [completion.tape](completion.tape) | 真实 blink.cmp 菜单：data、函数、局部变量、路径和块 snippet |
| [diagnostics.tape](diagnostics.tape) | 模板语法及执行错误，nvim-lint + luac 宿主诊断及修复 |
| [dependencies.tape](dependencies.tape) | 保存共享模板和配置数据后刷新已有预览，以及手动刷新 |
| [navigation.tape](navigation.tape) | source/target 切换保留未保存修改，gf 共享模板/include、gF 行号、真实 vim-matchup 的 % |
| [plain.tape](plain.tape) | 普通 source 的目标类型识别、原生 do、未保存 target 的 ReAdd 与撤销 |
| [buffers.tape](buffers.tape) | 两个未命名 scratch buffer 的 API、上下分屏、hunk 写回、撤销及 ReAdd |
| [cancel.tape](cancel.tape) | 取消真实 sleep 子进程，保留 buffer，继续编辑后成功预览 |
| [injection.tape](injection.tape) | injection 模式下切换执行分支，直接解析宿主片段 |
| [disabled.tape](disabled.tape) | 关闭宿主颜色后保留模板 action 高亮 |

README 中的主要交互功能均有对应实录；配置选项和所有路径写法不逐一单独成片。
路径实录覆盖共享模板、include、受管理 destination 的行号定位和块匹配；glob picker、
symlink 路径及原生跳转回退仍由测试覆盖。LSP 与 nvim-lint 的宿主诊断展示相同，
这套实录使用真实 nvim-lint；chezmoi merge 外部编辑器流程不另录。

顶部只展示 diff、静态写回和 preview 三段主演示；其余实录放在 README
对应功能介绍中，另外两种高亮模式提供 MP4 链接；全部十三个场景参与构建和发布。高亮配置在启动时一次传入，不在回放中重复 setup。

## 本地构建与查看

从仓库根目录运行：

```sh
# 构建全部十三段：录制、回放验证、GIF 转换、播放索引和本地 README。
python3 docs/demos/build.py

# 只重录指定场景。
python3 docs/demos/build.py completion diagnostics

# 复用已有媒体，只更新索引和本地 README。
python3 docs/demos/build.py --readme-only

# 检查依赖和隔离配置，不录制。
python3 docs/demos/build.py --check
```

每段产物位于 `docs/demos/output/`：GIF、MP4、PNG 封面及验证 JSON。
仓库根目录的 `README.local.md` 和 `README.zh-CN.local.md` 复用原 README 正文，
仅将媒体和语言切换链接改为本地相对路径。生成的 README 和媒体均被 Git 忽略。
直接修改原 README 后，用 `--readme-only` 重新生成即可。

支持相对图片的 Markdown 预览器（包括当前 MdKite）可直接显示本地 GIF。
MdKite 当前不转换相对 video 路径，查看高清 MP4 时请从文件系统用浏览器打开
`docs/demos/output/index.html`；在仓库根目录的 Neovim 中也可以执行：

```vim
:lua vim.ui.open(vim.fn.getcwd() .. "/docs/demos/output/index.html")
```

索引只展示仍有录制脚本的场景，优先采用英文 README 的 GIF 顺序，其余按名称排列。
以前生成的旧媒体不必删除，也不会重新进入索引或后续干净的 CI 构建。

默认测试入口 `python3 tests/run.py` 在全部 Lua 测试通过后运行完整构建；CI 使用同一入口。
`python3 tests/run.py --skip-demos` 或指定 Lua 文件名只运行 Lua 测试。`build.py --check`
只检查依赖和启动，不能替代完整回放验证；新增或修改 tape 后应运行完整测试或构建。

Lua 测试支持 Neovim 0.11+，可通过 `--nvim /path/to/nvim` 选择版本；默认使用 PATH
中的 `nvim`。演示录制仍使用下面列出的 Neovim 0.12+ 环境。

`verify.lua` 检查真实回放结果：补全菜单、snippet、诊断、模板表达式保留、依赖刷新、跳转记录、未保存修改、上下分屏和真实任务取消等。
三段核心演示共用 [common/scroll.tape](common/scroll.tape)，验证 source 和 output 两个方向都确实带动对侧视口。
验证失败或未运行到验证步骤时构建失败。直接运行 VHS 需自行提供 `VIMOI_DEMO` 和 `VIMOI_DEMO_RESULT`，建议统一使用构建脚本。

## 依赖

Python 3、VHS、ttyd、FFmpeg（含 ffprobe）、Chromium / Google Chrome、Neovim 0.12+、chezmoi，
以及 JetBrainsMono Nerd Font Mono 字体。诊断场景还需要 luac。缺少工具时先安装。

录制需要 gotmpl / YAML / Lua parser 及 highlights query。完整 Lua 测试所需语言统一列在
[tests/parsers.txt](../../tests/parsers.txt)，包含 HTML/Markdown 等宿主和注入语言。CI 安装脚本与
测试入口共用此清单，缺失时在运行测试前报错；新增语言测试时应同步更新清单。

| Neovim 插件 | 场景 | 自定义路径环境变量 |
| --- | --- | --- |
| folke/tokyonight.nvim | 全部 | `VIMOI_DEMO_TOKYONIGHT` |
| NStefan002/screenkey.nvim | 全部 | `VIMOI_DEMO_SCREENKEY` |
| Saghen/blink.cmp | completion；Lua matcher | `VIMOI_DEMO_BLINK` |
| mfussenegger/nvim-lint | diagnostics；luac provider | `VIMOI_DEMO_LINT` |
| andymass/vim-matchup | navigation；真实 % 块匹配 | `VIMOI_DEMO_MATCHUP` |

默认从 `stdpath("data") .. "/lazy/<插件名>"` 加载插件。字体匹配检查：
`fc-match 'JetBrainsMono Nerd Font Mono'`。VHS 的 ttyd / Chromium 需要允许监听本地端口的环境。
`init.lua` 退出时清理临时 source、target 和状态；回放中只有依赖刷新场景会保存临时文件。

## 样式、画质和节奏

参考 chezmoi-template.nvim 的 [style.tape](https://github.com/dpezto/chezmoi-template.nvim/blob/670ba83095ba6571f3125a5e5fd4118505a2c3c6/assets/tapes/style.tape)：
蓝紫到玫瑰色渐变背景、Colorful 窗口按钮、较薄内边距和圆角，编辑器使用 TokyoNight Night。
[backdrop.png](common/backdrop.png) 原样来自该项目同一提交，版权与 MIT 许可见 [backdrop.LICENSE](common/backdrop.LICENSE)。
背景素材约 23KB，是录制输入；生成的视频不纳入 Git。

原始录制 2560×1440，字号 36，抓帧率 30fps。当前 VHS / FFmpeg 组合的 H.264 MP4 实测输出为 25fps，
实际编码参数保存在 JSON。GIF 为 1920×1080、20fps，使用两遍转换：先根据变化区域生成调色板，
再用固定 Bayer 抖动编码，兼顾文字颜色和静态渐变的稳定性，不一次缓存整段原始视频帧。

GIF 的调色板最多 256 色，因此渐变、抗锯齿细节和文件体积无法同时达到 MP4 水平。
README 选择兼容性较好的 GIF；需要原始清晰度时使用 MP4。
常规输入 35ms/键，核心教程 45ms/键，可见停顿约 0.6–1.8 秒。
启动和演示标签准备放在隐藏部分，不计入播放时长。

## GitHub Actions 与发布

[Record demos](../../.github/workflows/demos.yml) 在 main 的插件代码、query、测试、README 或录制素材变化时运行，也可手动运行。
新增根目录 `.tape` 后会自动录制；工具和插件版本在工作流中固定。

每次构建产生保留七天的 demos artifact，包含 GIF、PNG、MP4、验证 JSON 和播放索引。
默认分支全部成功后，发布 job 使用 `GITHUB_TOKEN` 覆盖
[demos Release](https://github.com/dirichy/vimoi.nvim/releases/tag/demos) 同名附件；其他分支仅生成 artifact。
demos 是 prerelease，不作为插件 latest release。本地构建不上传附件。

GitHub README 通过普通图片语法显示 Release GIF；MP4 是高清下载链接，无须依赖 HTML 视频内嵌。
GIF URL 为 `https://github.com/dirichy/vimoi.nvim/releases/download/demos/<场景>.gif`。
发布步骤完成后检查 README 引用的 GIF/MP4 地址；本地构建成功不代表线上附件已经更新。

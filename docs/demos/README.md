# 录制 README 演示

| 脚本 | 内容 |
| --- | --- |
| `preview.tape` | 预览静态编辑和条件分支切换；未执行文本使用 Comment；撤销修改 |
| `diff.tape` | 模板与循环展开后的输出同步滚动；`do` / `dp` 传递 hunk；选择插入位置并撤销 |
| `readd.tape` | 批量写回 target 的静态修改，保留模板表达式和无法反推的差异 |

## GitHub Actions

[Record demos](../../.github/workflows/demos.yml) 在 `main` 的插件代码、query 或录制素材
变化时运行，也可在 Actions 页面手动运行。依赖版本在工作流中固定。

每次运行生成保留七天的 `demos` artifact。默认分支录制成功后，覆盖
[demos Release](https://github.com/dirichy/vimoi.nvim/releases/tag/demos) 中同名的六个
GIF/MP4 附件；其他分支只生成 artifact。README 引用这些附件，媒体不写入 Git。

发布 job 使用自带 `GITHUB_TOKEN` 的 `contents: write` 权限；`demos` 标为
prerelease，不作为插件的 latest release。

## 本地录制

依赖：VHS、ttyd、FFmpeg、Chromium、Neovim 0.12+、chezmoi、gotmpl/YAML parser、
JetBrains Mono 字体，以及以下两个 Neovim 插件：

| 插件 | 默认目录 | 自定义路径的环境变量 |
| --- | --- | --- |
| `folke/tokyonight.nvim` | `stdpath("data") .. "/lazy/tokyonight.nvim"` | `VIMOI_DEMO_TOKYONIGHT` |
| `NStefan002/screenkey.nvim` | `stdpath("data") .. "/lazy/screenkey.nvim"` | `VIMOI_DEMO_SCREENKEY` |

从仓库根目录运行：

```sh
mkdir -p docs/demos/output
vhs docs/demos/preview.tape
vhs docs/demos/diff.tape
vhs docs/demos/readd.tape
```

产物位于被 Git 忽略的 `docs/demos/output/`。录制配置使用 `tokyonight-storm` 和
`highlight.mode = "rendered"`；顶部 KEYS 栏显示输入，三秒无输入后清空。
`init.lua` 为每次录制创建独立的 chezmoi source、target、配置及状态数据库，退出时清理；
演示中的修改仅保留在这些临时文件的 buffer 中。

字体不正确时检查 `fc-match 'JetBrains Mono'`。VHS Action 将字体安装到
`~/.local/share/fonts`；CI 把它链接到隔离的 `$XDG_DATA_HOME/fonts`，刷新缓存并检查
实际匹配的字体，找不到 JetBrains Mono 时停止录制。

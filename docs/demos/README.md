# README 演示录制

三段演示来自真实 Neovim 和 chezmoi 操作，用 VHS 重放并编码：

- `preview.tape`：首次打开模板即有高亮；打开只读预览，修改静态文本，切换条件分支，
  用 Comment 标识未执行文本，然后 undo。
- `diff.tape`：展开 diff 折叠，在模板与 24 次循环展开后的 target 间双向同步滚动；
  在 target 用 `do` 获取渲染后的 hunk，再用 `dp` 写回新增文本，展示空 if 块边界的
  三个插入位置并选择块内；最后在 source undo。
- `readd.tape`：批量把 target 中的静态修改写回 source buffer；动态表达式保留，
  无法反推的动态修改继续显示为 diff。

## GitHub Actions

[Record demos](../../.github/workflows/demos.yml) 在 `main` 的插件代码、query 或录制素材
变化后自动运行，也可以在 Actions 页面手动运行。工作流安装固定版本的 Neovim、
chezmoi、VHS、Tree-sitter CLI，以及固定 commit 的 parser 安装器、Tokyonight 和
screenkey，安装 gotmpl/YAML parser 后录制三段演示。

每次运行生成 `demos` artifact，保留七天，供下载检查。默认分支成功后，把六个
GIF/MP4 上传到固定的 [demos Release](https://github.com/dirichy/vimoi.nvim/releases/tag/demos)，
覆盖同名附件；其他分支手动运行只生成 artifact。这个 Release 标为 prerelease，
不会成为插件的 latest release。README 引用固定附件地址，首次成功发布后生效。
只需工作流自带的 `GITHUB_TOKEN`，发布 job 使用 `contents: write` 权限。

生成文件统一放在 `docs/demos/output/`，由 `.gitignore` 排除；工作流不提交媒体，
也不另建保存媒体的 Git 分支。历史上已提交的视频仍在旧 commit 中，本次迁移不改写历史。

## 本地重录

从仓库根目录运行，需要 VHS、ttyd、FFmpeg、Chromium、Neovim 0.12+、chezmoi，
以及 runtimepath 中的 gotmpl 和 YAML parser。主题使用真正的 `folke/tokyonight.nvim`
的 `tokyonight-storm`，不加载个人 Neovim 配置。默认从
`stdpath("data") .. "/lazy/tokyonight.nvim"` 加载；其他安装位置可以设置
`VIMOI_DEMO_TOKYONIGHT=/path/to/tokyonight.nvim`，已经在 runtimepath 中时无需设置。
使用 JetBrains Mono 字体；未安装时可调整 tape 的 `FontFamily`。

按键显示使用 [screenkey.nvim](https://github.com/NStefan002/screenkey.nvim)，默认从
`stdpath("data") .. "/lazy/screenkey.nvim"` 加载，也可以通过
`VIMOI_DEMO_SCREENKEY=/path/to/screenkey.nvim` 指定安装位置。录制开始时自动开启，
顶部固定的 KEYS 栏显示真实输入，包括 `Ctrl+D`、`Ctrl+W`、`do`、`dp` 和菜单选择；
停止输入三秒后清空，展开底部的插入位置菜单时仍然可见。

```sh
mkdir -p docs/demos/output
vhs docs/demos/preview.tape
vhs docs/demos/diff.tape
vhs docs/demos/readd.tape
```

每次在 `docs/demos/output/` 中生成同名 GIF 和 MP4，不加入版本控制。录制使用 `highlight.mode = "rendered"`，并正常启用
filetype detection 和 syntax，首次打开模板也会经过插件的标准初始化。YAML 输出也
启用原生 Tree-sitter 高亮，让两侧使用同一套 query 和主题；关闭持续搜索高亮，避免
搜索匹配的背景掩盖未执行文本的 Comment 样式。
`init.lua` 创建独立的临时 chezmoi source、target、配置和状态数据库，退出时清理。
不操作真实 dotfiles，不执行 apply，不保存演示中的 buffer 修改。
`VIMOI_DEMO=diff` 和 `VIMOI_DEMO=readd` 只用于选择示例数据。

窗口标题和状态栏是演示专用配置；同步滚动、hunk 传递、插入位置菜单和 re-add
使用插件与 Neovim 的实际行为，不模拟结果。本目录的 Lua 文件、模板和 tape 是
可修改的录制素材，不属于插件用户 API。

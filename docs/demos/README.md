# README 演示录制

这两段演示来自真实的 Neovim 和 chezmoi 操作，用 VHS 按脚本重放并编码：

- `preview.tape`：打开只读预览，修改静态文本，切换条件分支，然后 undo。
- `readd.tape`：打开模板 diff，把 target 中的静态修改写回 source buffer；动态修改保留供手动处理。

## 重录

从仓库根目录运行，需要 VHS、ttyd、FFmpeg、Chromium、Neovim 0.12+、chezmoi，
以及 Neovim runtimepath 中的 gotmpl parser。YAML parser 可选。使用 JetBrains Mono
字体；未安装时可调整 tape 的 `FontFamily`。

```sh
vhs docs/demos/preview.tape
vhs docs/demos/readd.tape
```

每次生成同名 GIF 和 MP4。`init.lua` 不加载个人 Neovim 配置，并创建独立的临时
chezmoi source、target、配置和状态数据库，退出时清理。不操作真实 dotfiles，
不执行 apply，不保存演示中的 source 修改。`VIMOI_DEMO=readd` 只用于选择第二组示例。

主题、窗口标题和状态栏是演示专用配置；预览、diff 与 re-add 行为来自插件本身。
本目录的 Lua 文件和 tape 是可修改的录制素材，不属于插件用户 API。

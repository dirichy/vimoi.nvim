Output docs/demos/output/completion.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-completion.log"

Hide
Type "VIMOI_DEMO=completion nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
# Complete a data key.
Type `/\.name`
Enter
Type "lcwna"
Sleep 1200ms
Ctrl+Y
Escape
Sleep 600ms
# Complete a template function.
Type "4G0f{wcwquo"
Sleep 1200ms
Ctrl+N
Sleep 500ms
Ctrl+Y
Escape
Sleep 600ms
# Complete a local variable.
Type "/local:"
Enter
Type "f$lcwgree"
Sleep 1200ms
Ctrl+Y
Escape
Sleep 600ms
# Complete a shared-template path inside its string.
Type "/settings.yaml"
Enter
Type `ci"set`
Sleep 1200ms
Ctrl+Y
Escape
Sleep 600ms
# Expand a real block snippet, using Neovim's snippet engine.
Type "Goif"
Sleep 1200ms
Ctrl+Y
Escape
Sleep 1200ms
Screenshot docs/demos/output/completion.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

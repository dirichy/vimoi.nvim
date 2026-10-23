Output docs/demos/output/preview.gif
Output docs/demos/output/preview.mp4

Require nvim
Require chezmoi
Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 22
Set Width 1400
Set Height 760
Set Padding 20
Set Framerate 15
Set Theme "TokyoNightStorm"
Set TypingSpeed 90ms
Env NVIM_LOG_FILE "/tmp/vimoi-demo-preview.log"

Hide
Type "nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 2s
Show
Sleep 1s
Type ":VimoiPreview"
Enter
Sleep 2s

# Static edits appear in the read-only output without saving the source.
Type "/light"
Enter
Type "ciw"
Type "dark"
Escape
Sleep 2s

# Changing a template condition removes its block from the rendered output.
Type "/true"
Enter
Type "ciw"
Type "false"
Escape
Sleep 3s

# Undo restores the block; the real template is never saved or applied.
Type "u"
Sleep 3s
Hide
Type ":qa!"
Enter

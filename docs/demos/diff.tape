Output docs/demos/output/diff.gif
Output docs/demos/output/diff.mp4

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
Env NVIM_LOG_FILE "/tmp/vimoi-demo-diff.log"

Hide
Type "VIMOI_DEMO=diff nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 2s
Show
Sleep 1s
Type ":VimoiDiff"
Enter
Sleep 2s

# Expand native diff folds before scrolling through unequal source/output lengths.
Type "zR"
Sleep 1s
Ctrl+D
Sleep 1s
Ctrl+D
Sleep 2s
Ctrl+W
Type "l"
Type "gg"
Ctrl+D
Sleep 1s
Ctrl+D
Sleep 1s
Type "/logging:"
Enter
Sleep 2s

# Get rendered source into the target; only this hunk is changed.
Type "gg/theme:"
Enter
Sleep 1s
Type "do"
Sleep 2s

# Put an inserted target hunk into source. The empty if has three valid placements.
Type "/search:"
Enter
Sleep 1s
Type "dp"
Sleep 3s
Type "2"
Enter
Sleep 1s
Enter
Sleep 2s

# Both buffers remain unsaved and ordinary undo restores the insertion.
Ctrl+W
Type "h"
Type "u"
Sleep 2s
Hide
Type ":qa!"
Enter

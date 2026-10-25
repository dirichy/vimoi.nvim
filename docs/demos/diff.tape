Output docs/demos/output/diff.mp4
Source docs/demos/common/settings.tape
Set TypingSpeed 45ms
Env NVIM_LOG_FILE "/tmp/vimoi-demo-diff.log"

Hide
Type "VIMOI_DEMO=diff nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 2s
Show
Sleep 600ms
Type ":VimoiDiff"
Enter
Sleep 1200ms

# Open context, then demonstrate scrolling from both sides.
Type "zR"
Source docs/demos/common/scroll.tape

# Get rendered source into the target; only this hunk is changed.
Ctrl+W
Type "l"
Type "gg/theme:"
Enter
Sleep 600ms
Type "do"
Sleep 1200ms

# Put an inserted target hunk into source. The empty if has three valid placements.
Type "/search:"
Enter
Sleep 600ms
Type "dp"
Sleep 1500ms
Type "2"
Enter
Sleep 600ms
Enter
Sleep 1200ms

# Both buffers remain unsaved and ordinary undo restores the insertion.
Ctrl+W
Type "h"
Type "u"
Sleep 1200ms
Screenshot docs/demos/output/diff.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

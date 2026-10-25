Output docs/demos/output/readd.mp4
Source docs/demos/common/settings.tape
Set TypingSpeed 45ms
Env NVIM_LOG_FILE "/tmp/vimoi-demo-readd.log"

Hide
Type "VIMOI_DEMO=readd nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 2s
Show
Sleep 600ms
Type ":VimoiDiff"
Enter
Sleep 1200ms
Type "zR"
Source docs/demos/common/scroll.tape

# Re-add the static change; the dynamic name remains for manual source editing.
Type ":VimoiReAdd"
Enter
Sleep 1800ms
Type "zR"
Sleep 1500ms
Screenshot docs/demos/output/readd.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

Output docs/demos/output/disabled.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-disabled.log"

Hide
Type "VIMOI_DEMO=disabled nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
Type ":VimoiPreview"
Enter
Sleep 1200ms
# Each recording starts with its own highlight mode; setup runs once.
Type "/true"
Enter
Type "ciwfalse"
Escape
Sleep 1500ms
Screenshot docs/demos/output/disabled.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

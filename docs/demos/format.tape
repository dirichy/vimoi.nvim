Output docs/demos/output/format.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-format.log"

Hide
Type "VIMOI_DEMO=format nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 1200ms
Type ":VimoiPreview"
Enter
Sleep 1800ms
Type ":VimoiFormat"
Enter
Sleep 2200ms
Screenshot docs/demos/output/format-formatted.png
Sleep 300ms
Type "u"
Sleep 1800ms
Screenshot docs/demos/output/format-undo.png
Sleep 300ms
Ctrl+r
Sleep 2200ms
Screenshot docs/demos/output/format.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

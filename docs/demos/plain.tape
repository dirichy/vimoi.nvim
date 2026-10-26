Output docs/demos/output/plain.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-plain.log"

Hide
Type "VIMOI_DEMO=plain nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
# Source and target retain their unsaved notes.
Type "Go# unsaved source note"
Escape
Type ":VimoiToggle"
Enter
Sleep 900ms
Type "Go# unsaved target note"
Escape
Type ":VimoiToggle"
Enter
Sleep 900ms
Type ":VimoiDiff"
Enter
Sleep 1200ms
Type "zR/EDITOR"
Enter
# Plain files keep native diffget semantics.
Type "dozR"
Sleep 1200ms
# ReAdd takes the entire target buffer, including unsaved text.
Type ":VimoiReAdd"
Enter
Type "zR"
Sleep 1200ms
Type "uzR"
Sleep 1200ms
Type ":VimoiReAdd"
Enter
Type "zR"
Sleep 1200ms
Screenshot docs/demos/output/plain.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

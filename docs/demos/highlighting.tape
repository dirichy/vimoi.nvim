Output docs/demos/output/highlighting.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-highlighting.log"

Hide
Type "VIMOI_DEMO=highlighting nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
Type ":VimoiPreview"
Enter
Sleep 1200ms
# The disabled branch is rendered as Comment in source.
Type "/true"
Enter
Type "ciwfalse"
Escape
Sleep 1200ms
# Undo restores executed host colors while template actions retain their background.
Type "u"
Sleep 1200ms
Screenshot docs/demos/output/highlighting.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

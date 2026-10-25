Output docs/demos/output/preview.mp4
Source docs/demos/common/settings.tape
Set TypingSpeed 45ms
Env NVIM_LOG_FILE "/tmp/vimoi-demo-preview.log"

Hide
Type "VIMOI_DEMO=preview nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 2s
Show
Sleep 600ms
Type ":VimoiPreview"
Enter
Sleep 1200ms

Source docs/demos/common/scroll.tape

# Static edits appear in the read-only output without saving the source.
Type "/light"
Enter
Type ":s/light/dark/"
Enter
Escape
Sleep 1200ms

# Changing a template condition removes its block from the rendered output.
Type "/true"
Enter
Type ":s/true/false/"
Enter
Escape
Sleep 1500ms

# Undo restores the block; the real template is never saved or applied.
Type "u"
Sleep 1500ms
# A temporary execution error retains the previous render, marked stale.
Type `gg/\.name`
Enter
Type "lcwmissing"
Escape
Sleep 1500ms
Type "u"
Sleep 1200ms
Screenshot docs/demos/output/preview.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

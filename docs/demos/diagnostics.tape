Output docs/demos/output/diagnostics.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-diagnostics.log"

Hide
Type "VIMOI_DEMO=diagnostics nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
# A missing data field produces a template execution diagnostic.
Type `/\.name`
Enter
Type "lcwmissing"
Escape
Sleep 1200ms
Type ":lua vim.diagnostic.open_float()"
Enter
Sleep 1200ms
Type "u"
Sleep 1200ms
# A valid template can generate invalid Lua: project the checker error back.
Type "3G0"
Type `ci")`
Escape
Sleep 1200ms
Type ":lua vim.diagnostic.open_float()"
Enter
Sleep 1500ms
Type "u"
Sleep 1200ms
# An incomplete template block is diagnosed while editing.
Type "Go{{ if }}"
Escape
Sleep 1200ms
Type "u"
Sleep 1200ms
# Also report invalid literal host syntax, then repair it.
Type "Golocal broken = )"
Escape
Sleep 1200ms
Type ":lua vim.diagnostic.open_float()"
Enter
Sleep 1200ms
Type "u"
Sleep 1200ms
Screenshot docs/demos/output/diagnostics.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

Output docs/demos/output/navigation.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-navigation.log"

Hide
Type "VIMOI_DEMO=navigation nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
# Both buffers keep unsaved changes while toggling.
Type "Go# unsaved source note"
Escape
Type ":VimoiToggle"
Enter
Sleep 1200ms
Type "Go# unsaved target note"
Escape
Type ":VimoiToggle"
Enter
Sleep 1200ms
# Shared template and source-relative include.
Type "gg/settings.yaml"
Enter
Type "gf"
Sleep 1200ms
Ctrl+O
Type "/notes.txt"
Enter
Type "gf"
Sleep 1200ms
Ctrl+O
# Managed target path resolves to source, preserving the line number.
Type "/:4"
Enter
Type "gF"
Sleep 1200ms
Hide
Type ":lua assert(vim.api.nvim_win_get_cursor(0)[1] == 4)"
Enter
Show
Ctrl+O
Type ":let g:vimoi_demo_stage = 'Match template blocks with %'"
Enter
Type "/if true"
Enter
Type "%"
Sleep 900ms
Type "%"
Sleep 900ms
Type "%"
Sleep 1200ms
Screenshot docs/demos/output/navigation.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

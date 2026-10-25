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
# Injection also colors host text in unexecuted branches.
Type ":lua require('vimoi').setup({highlight={mode='injection'}})"
Enter
Sleep 1500ms
# Template action syntax remains when host highlighting is disabled.
Type ":lua require('vimoi').setup({highlight={mode='disabled'}})"
Enter
Sleep 1500ms
Type ":lua require('vimoi').setup({highlight={mode='rendered',template_bg='Visual'}})"
Enter
Sleep 1500ms
Screenshot docs/demos/output/highlighting.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

Output docs/demos/output/cancel.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-cancel.log"

Hide
Type "VIMOI_DEMO=cancel nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
# Add real slow work to an unsaved template after normal baseline validation.
Type `ggo{{ output "sleep" "300" }}`
Escape
Sleep 600ms
Type ":VimoiPreview"
Enter
Sleep 1800ms
Screenshot docs/demos/output/cancel.png
Hide
Type ":lua _G.vimoi_demo_cancel_job = require('vimoi.render').get(vim.fn.bufnr(vim.g.vimoi_demo.source)).job"
Enter
Show
Type " cx"
Sleep 1200ms
Hide
Type ":lua assert(require('vimoi.compare').current().preview_error)"
Enter
Show
# Keep editing the same buffer and successfully render again.
Type "2Gdd/light"
Enter
Type "ciwdark"
Escape
Type ":VimoiPreview"
Enter
Sleep 1500ms
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

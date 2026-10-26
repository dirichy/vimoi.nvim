Output docs/demos/output/buffers.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-buffers.log"

Hide
Type "VIMOI_DEMO=buffers nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
# Compare two unnamed scratch buffers using the public API.
Type ":lua require('vimoi.api').diff_buffers(0, vim.g.vimoi_demo.target_buf, {filetype='yaml'})"
Enter
Sleep 1500ms
Type "zR/theme:"
Enter
Type "dozR"
Sleep 1200ms
Type "uzR"
Sleep 1200ms
Type ":VimoiReAdd"
Enter
Type "zR"
Sleep 1200ms
Screenshot docs/demos/output/buffers.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

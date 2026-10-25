Output docs/demos/output/dependencies.mp4
Source docs/demos/common/settings.tape
Env NVIM_LOG_FILE "/tmp/vimoi-demo-dependencies.log"

Hide
Type "VIMOI_DEMO=dependencies nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 3s
Show
Sleep 600ms
Type ":VimoiPreview"
Enter
Sleep 1200ms
# Shared template saves refresh an already-open parent preview.
Type ":leftabove split"
Enter
Type "/settings.yaml"
Enter
Type "gf"
Sleep 600ms
Type "/light"
Enter
Type "ciwdark"
Escape
Type ":write"
Enter
Sleep 1200ms
Type ":close"
Enter
Sleep 1200ms
# Changes to chezmoi data refresh the same preview.
Type ":leftabove split"
Enter
Type ":execute 'edit ' . fnameescape(g:vimoi_demo.config)"
Enter
Type "/workstation"
Enter
Type "ciwlaptop"
Escape
Type ":write"
Enter
Sleep 1200ms
Type ":close"
Enter
Type ":VimoiPreview"
Enter
Sleep 1200ms
# Manual refresh remains available when external events are not detected.
Type " cr"
Sleep 1200ms
Screenshot docs/demos/output/dependencies.png
Sleep 300ms
Hide
Type ":lua dofile('docs/demos/verify.lua')"
Enter
Sleep 1s
Type ":qa!"
Enter

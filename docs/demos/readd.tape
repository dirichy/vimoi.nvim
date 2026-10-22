Output docs/demos/readd.gif
Output docs/demos/readd.mp4

Require nvim
Require chezmoi
Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 22
Set Width 1400
Set Height 760
Set Padding 20
Set Framerate 15
Set Theme "TokyoNightStorm"
Set TypingSpeed 90ms

Hide
Type "VIMOI_DEMO=readd nvim -n -i NONE -u docs/demos/init.lua"
Enter
Sleep 2s
Show
Sleep 1s
Type ":VimoiDiff"
Enter
Sleep 2s
Type "zR"
Sleep 3s

# Re-add the static change; the dynamic name remains for manual source editing.
Type ":VimoiReAdd"
Enter
Sleep 4s
Type "zR"
Sleep 3s
Hide
Type ":qa!"
Enter

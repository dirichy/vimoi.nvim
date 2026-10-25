# Source-side scrolling: the peer follows mapped content, not equal line numbers.
Hide
Type ":let g:vimoi_demo_stage = 'SCROLL SYNC / SOURCE -> OUTPUT'"
Enter
Type ":echo ''"
Enter
Sleep 1100ms
Show
Type "gg"
Ctrl+E
Sleep 120ms
Ctrl+E
Sleep 120ms
Ctrl+E
Sleep 120ms
Ctrl+E
Sleep 120ms
Ctrl+E
Sleep 120ms
Ctrl+E
Sleep 120ms
Ctrl+E
Sleep 120ms
Ctrl+E
Sleep 120ms
Sleep 600ms
Ctrl+D
Sleep 1200ms

# Output-side scrolling crosses the repeated loop output and finds matching source.
Ctrl+W
Type "l"
Hide
Type ":let g:vimoi_demo_stage = 'SCROLL SYNC / OUTPUT -> SOURCE'"
Enter
Type ":echo ''"
Enter
Sleep 1100ms
Show
Type "gg"
Ctrl+D
Sleep 600ms
Ctrl+D
Sleep 1200ms
Type "/logging:"
Enter
Sleep 1200ms

# Restore the source window and its initial viewport for the next demonstration.
Ctrl+W
Type "h"
Type "gg"
Hide
Type ":let g:vimoi_demo_stage = ''"
Enter
Type ":echo ''"
Enter
Sleep 1100ms
Show
Sleep 600ms

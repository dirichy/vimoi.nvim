; extends

; Anchor the opener so "else if/with" remains a middle of the same scope.
; Repeating a capture name combines that clause's two keywords into one delimiter.
(if_action
  . "if" @open.if
  "end" @close.if) @scope.if
(if_action "else" @mid.if.1 . "if" @mid.if.1)
(if_action "else" @mid.if.1 . ["}}" "-}}"])

(with_action
  . "with" @open.with
  "end" @close.with) @scope.with
(with_action "else" @mid.with.1 . "with" @mid.with.1)
(with_action "else" @mid.with.1 . ["}}" "-}}"])

(range_action
  "range" @open.range
  "end" @close.range) @scope.range
(range_action "else" @mid.range.1)

(break_action "break" @mid.range.2)
(continue_action "continue" @mid.range.3)

(define_action
  "define" @open.define
  "end" @close.define) @scope.define

(block_action
  "block" @open.block
  "end" @close.block) @scope.block

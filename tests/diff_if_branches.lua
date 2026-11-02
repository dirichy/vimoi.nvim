vim.opt.swapfile = false
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
local api = require("vimoi.api")
local util = require("vimoi.core.util")
local sessions = require("vimoi.compare")
local native_diff = require("vimoi.compare.native_diff")

-- The line-ending newline comes from after end; the other branches produce
-- no output between the active value and that newline.
for _, active in ipairs({ "first", "second", "third" }) do
  for _, modified_line in ipairs({
    "value = changed",
    "value = " .. active .. " ",
    "value = " .. active .. "!",
    " value = " .. active,
    "value = " .. active:sub(1, 2) .. "!" .. active:sub(3),
    "value = " .. active:sub(1, 2) .. active:sub(4),
  }) do
    vim.cmd("tabnew")
    local source = vim.api.nvim_get_current_buf()
    local target = vim.api.nvim_create_buf(true, false)
    local source_text = table.concat({
      "before",
      "{{- if " .. tostring(active == "first") .. " }}",
      "value = first",
      "{{- else if " .. tostring(active == "second") .. " }}",
      "value = second",
      "{{- else }}",
      "value = third",
      "{{- end }}",
      "after",
      "",
    }, "\n")
    local target_text = "before\n" .. modified_line .. "\nafter\n"
    util.set_buffer_text(source, source_text)
    util.set_buffer_text(target, target_text)
    api.diff_buffers(source, target)
    dofile("tests/helpers/diff.lua")()
    local session = assert(sessions.current())
    local active_line = ({ first = 3, second = 5, third = 7 })[active]
    assert(#session.hunks == 1)
    assert(session.projected_hunks[1].source_start_line == active_line, vim.inspect(session.projected_hunks))
    assert(session.projected_hunks[1].source_line_count == 1, vim.inspect(session.projected_hunks))
    vim.api.nvim_win_call(session.source_win, function()
      vim.cmd("normal! zR")
      for row = 1, 9 do
        local highlight = vim.fn.synIDattr(vim.fn.diff_hlID(row, 1), "name")
        assert((highlight ~= "") == (row == active_line), active .. ": unexpected highlight at " .. row)
        assert((native_diff.hunk_at(session, source, row) ~= nil) == (row == active_line))
      end
    end)
    -- Display anchors do not choose a merge placement: appending at the
    -- branch boundary still offers alternatives. Source-side transfers must
    -- select this hunk without changing the other branches.
    vim.api.nvim_set_current_win(session.source_win)
    vim.api.nvim_win_set_cursor(0, { active_line, 0 })
    if modified_line == "value = " .. active .. " " or modified_line == "value = " .. active .. "!" then
      local plan =
        require("vimoi.merge.plan").plan(assert(require("vimoi.render").snapshot(source)), target_text, session.hunks)
      assert(#plan.choices == 1 and #plan.edits == 0 and #plan.skipped == 0, vim.inspect(plan))
      assert(api.put_hunk())
      assert(util.buffer_text(source) == source_text)
      assert(util.buffer_text(target) == "before\nvalue = " .. active .. "\nafter\n")
    else
      assert(api.get_hunk())
      assert(util.buffer_text(source) == source_text:gsub("value = " .. active, modified_line))
      assert(util.buffer_text(target) == target_text)
    end
    sessions.close(session)
  end
end
print("if branch diff: only the active branch is highlighted, selected and updated")

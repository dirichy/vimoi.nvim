local view_for_buffer = dofile("tests/helpers/view.lua")
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local destination = vim.env.VIMOI_TEST_DESTINATION
local target = destination .. "/.complex_diff"
local source = fixture .. "/source/dot_complex_diff.tmpl"
local wrapper = fixture .. "/chezmoi-wrapper.sh"

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.env.VIMOI_TEST_DESTINATION = destination
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper, render = { validate = false } })

vim.cmd("edit " .. vim.fn.fnameescape(target))
local target_buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
for index, line in ipairs(lines) do
  if line == "timeout = 30" and index > 20 then
    lines[index] = "timeout = 45"
    break
  end
end
vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)
require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()

local source_win = vim.api.nvim_get_current_win()
local target_win = vim.fn.bufwinid(target_buf)
vim.api.nvim_set_current_win(target_win)
local target_fold = vim.api.nvim_win_call(target_win, function()
  for line = 1, vim.api.nvim_buf_line_count(0) do
    local last = vim.fn.foldclosedend(line)
    if last >= line + 6 then
      return { line, last }
    end
  end
end)
assert(target_fold, "test fixture needs a long diff fold")
local target_fold_line, target_fold_end = unpack(target_fold)
vim.api.nvim_win_set_cursor(target_win, { target_fold_line, 0 })
vim.cmd("doautocmd CursorMoved")
vim.wait(30)
local source_fold_line = vim.api.nvim_win_get_cursor(source_win)[1]
require("vimoi.compare").fold("zo")
local function is_open(win, line)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.foldclosed(line) == -1
  end)
end
assert(is_open(target_win, target_fold_line) and is_open(source_win, source_fold_line))

local function refresh_after_target_edit(line, replacement)
  vim.api.nvim_buf_set_lines(target_buf, line - 1, line, false, { replacement })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = target_buf })
  vim.wait(250)
  assert(is_open(target_win, target_fold_line), "target fold closed after refresh")
  assert(is_open(source_win, source_fold_line), "source fold closed after refresh")
end

-- A distant edit leaves this fold's geometry intact. Both windows must keep
-- the explicit zo state instead of resetting it on every diff refresh.
local last_line = vim.api.nvim_buf_line_count(target_buf)
local last_text = vim.api.nvim_buf_get_lines(target_buf, last_line - 1, last_line, false)[1]
refresh_after_target_edit(last_line, last_text .. " ")

-- An edit inside the opened region changes the diff layout as well.
local edit_line = target_fold_line + 3
assert(edit_line < target_fold_end)
local old_line = vim.api.nvim_buf_get_lines(target_buf, edit_line - 1, edit_line, false)[1]
refresh_after_target_edit(edit_line, old_line .. " ")

vim.api.nvim_win_set_cursor(target_win, { edit_line, 0 })
vim.api.nvim_set_current_win(target_win)
assert(require("vimoi.api").put_hunk(), "put of static edit failed")
vim.wait(250)
assert(is_open(target_win, target_fold_line), "put forcibly closed the target fold")
assert(is_open(source_win, source_fold_line), "put forcibly closed the source fold")

require("vimoi.compare").fold("zR")
local target_level, source_level = vim.wo[target_win].foldlevel, vim.wo[source_win].foldlevel
vim.api.nvim_win_set_cursor(target_win, { last_line, 0 })
assert(require("vimoi.api").put_hunk(), "put of distant edit failed")
vim.wait(250)
assert(vim.wo[target_win].foldlevel == target_level and vim.wo[source_win].foldlevel == source_level)
assert(is_open(target_win, target_fold_line) and is_open(source_win, source_fold_line), "put reset zR state")

-- Applying rendered output to target uses the same local writes and preserves
-- an unrelated opened fold and the user's zR setting on both sides.
refresh_after_target_edit(last_line, last_text .. " applied change")
local session = assert(view_for_buffer(target_buf))
local projected = session.projected_hunks[#session.projected_hunks]
vim.api.nvim_set_current_win(source_win)
vim.api.nvim_win_set_cursor(source_win, { math.max(1, projected.source_start_line), 0 })
vim.cmd("normal dp")
vim.wait(250)
assert(vim.wo[target_win].foldlevel == target_level and vim.wo[source_win].foldlevel == source_level)
assert(is_open(target_win, target_fold_line) and is_open(source_win, source_fold_line), "apply reset opened folds")

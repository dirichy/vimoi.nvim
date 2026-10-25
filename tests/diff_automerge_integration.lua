local run_async = dofile("tests/helpers/await.lua")
---@diagnostic disable: duplicate-set-field -- Intentional vim.ui.select test mocks.
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local source_path = fixture .. "/source/dot_automerge.tmpl"
local target_path = vim.fn.tempname()

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
vim.opt.swapfile = false
assert(vim.fn.exists(":VimoiReAdd") == 2)

local source = assert(require("vimoi.core.util").read_file(source_path))
local trace = assert(run_async(require("vimoi.render.source_map").trace, source))
local target = trace.output:gsub("before = 1", "before = 2"):gsub("after = 3", "after = 4")
-- This insertion is exactly between the if body's static node and {{ end }}.
-- Putting it before or after the action has different future semantics.
target = assert(target:gsub("inside = true\n", "inside = true\nboundary = manual\n", 1))
vim.fn.writefile(vim.split(target, "\n", { plain = true }), target_path)

vim.cmd("edit " .. vim.fn.fnameescape(target_path))
vim.cmd(("VimoiDiff %s %s"):format(vim.fn.fnameescape(source_path), vim.fn.fnameescape(target_path)))
dofile("tests/helpers/diff.lua")()

local original_select = vim.ui.select
local offered
vim.ui.select = function(items, _, callback)
  offered = items
  callback(nil)
end
local summary = assert(require("vimoi.api").readd())
vim.ui.select = original_select
assert(summary.merged == 2, vim.inspect(summary))
assert(summary.skipped == 1, vim.inspect(summary))
assert(summary.reasons[1].reason:find("cancelled", 1, true), vim.inspect(summary))
assert(#offered == 2, vim.inspect(offered))

local source_buf = vim.fn.bufnr(source_path)
local merged = require("vimoi.core.util").buffer_text(source_buf)
assert(merged:find("before = 2", 1, true), merged)
assert(merged:find("after = 4", 1, true), merged)
assert(not merged:find("boundary = manual", 1, true), merged)
vim.api.nvim_buf_call(source_buf, function()
  vim.cmd("undo")
  assert(require("vimoi.core.util").buffer_text(source_buf) == source, "one undo must revert all auto-merged hunks")
  vim.cmd("redo")
  assert(require("vimoi.core.util").buffer_text(source_buf) == merged, "one redo must restore all auto-merged hunks")
end)

-- The remaining ambiguous hunk can be placed interactively by the
-- single-hunk path. Pick the position inside the if block.
local target_buf = vim.fn.bufnr(target_path)
local target_win = vim.fn.bufwinid(target_buf)
vim.api.nvim_set_current_win(target_win)
local target_lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
for index, line in ipairs(target_lines) do
  if line == "boundary = manual" then
    vim.api.nvim_win_set_cursor(target_win, { index, 0 })
    break
  end
end
vim.ui.select = function(items, _, callback)
  assert(#items == 2, vim.inspect(items))
  callback(items[1])
end
assert(require("vimoi.api").put_hunk())
vim.ui.select = original_select
merged = require("vimoi.core.util").buffer_text(source_buf)
assert(merged:find("inside = true\nboundary = manual\n{{ end }}", 1, true), merged)

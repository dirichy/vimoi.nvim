local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local source = fixture .. "/source/dot_scroll_boundary.tmpl"
local target = vim.fn.tempname()

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
vim.fn.writefile({ "", "bbb", "aaa", "ccc", "" }, target)

require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()
local source_buf = vim.fn.bufnr(source)
local target_buf = vim.fn.bufnr(target)
local source_win = vim.fn.bufwinid(source_buf)
local target_win = vim.fn.bufwinid(target_buf)

-- A rendered blank line produced by a standalone action belongs to that
-- action, while the next line starts the following static segment. Treating
-- both range endpoints as inclusive used to collapse target lines 1 and 2
-- onto source line 2 and made scroll synchronization drift.
for line = 1, 4 do
  vim.api.nvim_set_current_win(target_win)
  vim.api.nvim_win_set_cursor(target_win, { line, 0 })
  vim.cmd("doautocmd CursorMoved")
  vim.wait(10)
  assert(
    vim.api.nvim_win_get_cursor(source_win)[1] == line,
    ("target line %d mapped to source line %d"):format(line, vim.api.nvim_win_get_cursor(source_win)[1])
  )
end

for line = 1, 4 do
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { line, 0 })
  vim.cmd("doautocmd CursorMoved")
  vim.wait(10)
  assert(
    vim.api.nvim_win_get_cursor(target_win)[1] == line,
    ("source line %d mapped to target line %d"):format(line, vim.api.nvim_win_get_cursor(target_win)[1])
  )
end

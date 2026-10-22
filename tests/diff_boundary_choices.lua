---@diagnostic disable: duplicate-set-field -- Intentional vim.ui.select test mock.
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local source = fixture .. "/source/dot_boundary_insert.tmpl"
local target = vim.fn.tempname()

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
local chezmoi_executable = fixture .. "/chezmoi-wrapper.sh"
require("vimoi").setup({ chezmoi_executable = chezmoi_executable })
vim.fn.writefile({ "xxx", "bbb", "aaa", "ccc", "yyy" }, target)
require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()
local target_buf = vim.fn.bufnr(target)
local target_win = vim.fn.bufwinid(target_buf)

vim.api.nvim_set_current_win(target_win)
local selected
local original_select = vim.ui.select
vim.ui.select = function(items, _, callback)
  selected = items
  callback(nil)
end
vim.api.nvim_win_set_cursor(target_win, { 2, 0 })
require("vimoi.api").put_hunk()
assert(selected and #selected == 2, vim.inspect(selected))
selected = nil
vim.api.nvim_win_set_cursor(target_win, { 4, 0 })
require("vimoi.api").put_hunk()
vim.ui.select = original_select
assert(selected and #selected == 2, vim.inspect(selected))

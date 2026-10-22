---@diagnostic disable: duplicate-set-field -- Intentional selector and sentinel mocks.
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local wrapper = fixture .. "/chezmoi-wrapper.sh"
local source = fixture .. "/source/dot_empty_if.tmpl"
local target = vim.fn.tempname()
local source_map = require("vimoi.gotmpl.source_map")

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper })
vim.fn.writefile({ "before", "new", "after" }, target)
require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()

local target_win = vim.fn.bufwinid(vim.fn.bufnr(target))
vim.api.nvim_set_current_win(target_win)
vim.api.nvim_win_set_cursor(target_win, { 2, 0 })
local original_trace = source_map.trace
local original_select = vim.ui.select
local renders = 0
local offered
source_map.trace = function(...)
  renders = renders + 1
  return original_trace(...)
end
vim.ui.select = function(items, _, callback)
  offered = items
  callback(items[2])
end
assert(require("vimoi.api").put_hunk())
source_map.trace = original_trace
vim.ui.select = original_select
assert(offered and #offered == 3, vim.inspect(offered))
assert(renders == 0, ("empty-if choice called the render entry %d times"):format(renders))
local merged = require("vimoi.util").buffer_text(vim.fn.bufnr(source))
assert(original_trace(merged).output == "before\nnew\nafter\n")

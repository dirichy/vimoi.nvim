local run_async = dofile("tests/helpers/await.lua")
---@diagnostic disable: duplicate-set-field -- Intentional vim.ui.select test mock.
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local source = fixture .. "/source/dot_inline_prefix.tmpl"
local target = vim.fn.tempname()
local wrapper = fixture .. "/chezmoi-wrapper.sh"

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper })
vim.fn.writefile({ "xxx", "bbb", "aaa", "ccc", "yyy", "xaxx = ooowww", "vvv" }, target)
require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()

local source_buf = vim.fn.bufnr(source)
local target_buf = vim.fn.bufnr(target)
local target_win = vim.fn.bufwinid(target_buf)
vim.api.nvim_set_current_win(target_win)
vim.api.nvim_win_set_cursor(target_win, { 6, 0 })
local original_select = vim.ui.select
vim.ui.select = function()
  error("unambiguous inline prefix insertion unexpectedly requested a choice")
end
assert(require("vimoi.api").put_hunk())
vim.ui.select = original_select

local merged = require("vimoi.util").buffer_text(source_buf)
assert(merged:find("xaxx = {{ if true -}} ooowww {{- end }}", 1, true), merged)
local trace = assert(run_async(require("vimoi.gotmpl.source_map").trace, merged))
assert(trace.output == "xxx\naaa\nyyy\nxaxx = ooowww\nvvv\n", vim.inspect(trace.output))

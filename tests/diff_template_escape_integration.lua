local run_async = dofile("tests/helpers/await.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local wrapper = fixture .. "/chezmoi-wrapper.sh"
local source = fixture .. "/source/dot_literal_escape.tmpl"
local target = vim.fn.tempname()
local util = require("vimoi.util")
local source_map = require("vimoi.gotmpl.source_map")

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper })
vim.fn.writefile({ "before", "aaa{{}}" }, target)
require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()

local source_buf = vim.fn.bufnr(source)
local target_win = vim.fn.bufwinid(vim.fn.bufnr(target))
vim.api.nvim_set_current_win(target_win)
vim.api.nvim_win_set_cursor(target_win, { 2, 0 })
require("vimoi.api").put_hunk()
local session = assert(view_for_buffer(source_buf))
assert(not session.pending_merge)
local merged = util.buffer_text(source_buf)
assert(merged:find('aaa{{ "{{" }}}}', 1, true), merged)
assert(assert(run_async(source_map.trace, merged)).output == "before\naaa{{}}\n")

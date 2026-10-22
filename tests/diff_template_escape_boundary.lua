local run_async = dofile("tests/helpers/await.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
local source = vim.fn.tempname() .. ".tmpl"
local target = vim.fn.tempname()
vim.fn.writefile({ "a{" }, source)
vim.fn.writefile({ "a{{" }, target)
vim.opt.swapfile = false

require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()
local target_win = vim.fn.bufwinid(vim.fn.bufnr(target))
vim.api.nvim_set_current_win(target_win)
vim.api.nvim_win_set_cursor(target_win, { 1, 1 })

local choices
local original_select = vim.ui.select
---@diagnostic disable-next-line: duplicate-set-field -- Intentional interactive choice mock.
vim.ui.select = function(items, _, callback)
  choices = items
  callback(items[1])
end
local result = require("vimoi.api").put_hunk()
vim.ui.select = original_select
assert(choices == nil, "a parser text-node boundary must not require a placement choice")
assert(result == true)
local session = assert(view_for_buffer(vim.fn.bufnr(source)))
assert(not session.pending_merge)
local merged = require("vimoi.util").buffer_text(vim.fn.bufnr(source))
assert(assert(run_async(require("vimoi.gotmpl.source_map").trace, merged)).output == "a{{\n")

vim.fn.delete(source)
vim.fn.delete(target)

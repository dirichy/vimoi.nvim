local run_async = dofile("tests/helpers/await.lua")
---@diagnostic disable: duplicate-set-field -- Intentional vim.ui.select test mocks.
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local wrapper = fixture .. "/chezmoi-wrapper.sh"
local source = fixture .. "/source/dot_byte_edits.tmpl"
local target = vim.fn.tempname()
local util = require("vimoi.core.util")
local source_map = require("vimoi.render.source_map")

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper })
vim.fn.writefile({ "left=abXcdmiddle=mnppright=wxy" }, target)
require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()

local source_buf = vim.fn.bufnr(source)
local original_source = util.buffer_text(source_buf)
local namespace = vim.api.nvim_create_namespace("vimoi-put-byte-edits")
local control_column = assert(original_source:find("{{ if", 1, true)) - 1
local control_mark = vim.api.nvim_buf_set_extmark(source_buf, namespace, 0, control_column, {})
local target_win = vim.fn.bufwinid(vim.fn.bufnr(target))
vim.api.nvim_set_current_win(target_win)
vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
local original_select = vim.ui.select
vim.ui.select = function()
  error("independent static byte edits must not request a choice")
end
assert(require("vimoi.api").put_hunk())
vim.ui.select = original_select
local merged = util.buffer_text(source_buf)
assert(merged == "left=abXcd{{ if true }}middle=mnpp{{ end }}right=wxy\n", merged)
assert(run_async(source_map.trace, merged).output == "left=abXcdmiddle=mnppright=wxy\n")
assert(
  vim.deep_equal(vim.api.nvim_buf_get_extmark_by_id(source_buf, namespace, control_mark, {}), { 0, control_column + 1 })
)
vim.api.nvim_buf_call(source_buf, function()
  vim.cmd("undo")
  assert(util.buffer_text(source_buf) == original_source, "one undo must revert all edits in a put")
  vim.cmd("redo")
  assert(util.buffer_text(source_buf) == merged, "one redo must restore the whole put")
end)

util.set_buffer_text(source_buf, "left=abcd{{ if true }}middle=mnop{{ end }}right=wxyz\n")
local summary = assert(require("vimoi.api").readd())
assert(summary.merged == 1 and summary.skipped == 0, vim.inspect(summary))
assert(util.buffer_text(source_buf) == merged)

local choice_source = fixture .. "/source/dot_byte_choice.tmpl"
local choice_target = vim.fn.tempname()
vim.fn.writefile({ "pRefixooousuffix" }, choice_target)
require("vimoi.api").diff_files(choice_source, choice_target)
dofile("tests/helpers/diff.lua")()
local choice_target_win = vim.fn.bufwinid(vim.fn.bufnr(choice_target))
vim.api.nvim_set_current_win(choice_target_win)
vim.api.nvim_win_set_cursor(choice_target_win, { 1, 0 })
local offered
vim.ui.select = function(items, _, callback)
  offered = items
  callback(items[1])
end
assert(require("vimoi.api").put_hunk())
vim.ui.select = original_select
assert(offered and #offered >= 2, vim.inspect(offered))
local choice_merged = util.buffer_text(vim.fn.bufnr(choice_source))
assert(choice_merged:find("pRefix", 1, true), choice_merged)
assert(run_async(source_map.trace, choice_merged).output == "pRefixooousuffix\n")

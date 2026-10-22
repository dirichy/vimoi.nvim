local run_async = dofile("tests/helpers/await.lua")
---@diagnostic disable: duplicate-set-field -- Intentional selector and sentinel mocks.
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local source = fixture .. "/source/dot_inline_suffix.tmpl"
local target = vim.fn.tempname()
local wrapper = fixture .. "/chezmoi-wrapper.sh"

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper })
vim.fn.writefile({ "ooouuu", "vvv" }, target)
require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()

local source_buf = vim.fn.bufnr(source)
local target_buf = vim.fn.bufnr(target)
local target_win = vim.fn.bufwinid(target_buf)
vim.api.nvim_set_current_win(target_win)
vim.api.nvim_win_set_cursor(target_win, { 1, 0 })
local original_select = vim.ui.select
local source_map = require("vimoi.gotmpl.source_map")
local original_trace = source_map.trace
local render_count = 0
source_map.trace = function(...)
  render_count = render_count + 1
  return original_trace(...)
end
local offered
vim.ui.select = function(items, opts, callback)
  offered = items
  assert(#items == 2, vim.inspect(items))
  assert(opts.format_item(items[1]) ~= opts.format_item(items[2]), "inline candidates need distinct labels")
  callback(items[1])
end
assert(require("vimoi.api").put_hunk())
vim.ui.select = original_select
source_map.trace = original_trace
assert(offered and #offered == 2)
assert(render_count == 0, ("choice called the render entry %d times"):format(render_count))

local merged = require("vimoi.util").buffer_text(source_buf)
assert(merged:find("{{- end }}", 1, true), merged)
local trace = assert(run_async(require("vimoi.gotmpl.source_map").trace, merged))
assert(trace.output == "ooouuu\nvvv\n", vim.inspect(trace.output))

-- The reverse edit is a deletion inside one static text node. It should not
-- ask where to place the deletion despite the line hunk crossing {{ end }}.
vim.api.nvim_buf_set_lines(target_buf, 0, 1, false, { "ooo" })
vim.ui.select = function()
  error("unambiguous inline deletion unexpectedly requested a choice")
end
assert(require("vimoi.api").put_hunk())
vim.ui.select = original_select
merged = require("vimoi.util").buffer_text(source_buf)
trace = assert(run_async(require("vimoi.gotmpl.source_map").trace, merged))
assert(trace.output == "ooo\nvvv\n", vim.inspect(trace.output))

-- The same source node also supports a byte replacement across the line hunk.
require("vimoi.util").set_buffer_text(source_buf, merged:gsub("ooo", "ooouuu", 1))
vim.api.nvim_buf_set_lines(target_buf, 0, 1, false, { "ooowww" })
vim.ui.select = function()
  error("unambiguous inline replacement unexpectedly requested a choice")
end
assert(require("vimoi.api").put_hunk())
vim.ui.select = original_select
merged = require("vimoi.util").buffer_text(source_buf)
assert(merged:find("ooowww", 1, true), merged)
trace = assert(run_async(require("vimoi.gotmpl.source_map").trace, merged))
assert(trace.output == "ooowww\nvvv\n", vim.inspect(trace.output))

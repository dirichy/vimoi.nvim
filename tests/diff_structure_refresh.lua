local run_async = dofile("tests/helpers/await.lua")
---@diagnostic disable: duplicate-set-field -- Intentional sentinel test mock.
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local source_path = fixture .. "/source/dot_automerge.tmpl"
local target_path = vim.fn.tempname()
local wrapper = fixture .. "/chezmoi-wrapper.sh"

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper, diff = { validate = false } })

local util = require("vimoi.util")
local original_source = assert(util.read_file(source_path))
local changed_source =
  assert(original_source:gsub("keep_a = true\n", "keep_a = true\n{{ if false }}\nhidden = true\n{{ end }}\n", 1))
local expected = assert(run_async(require("vimoi.gotmpl.source_map").trace, changed_source)).output
vim.fn.writefile(util.text_lines(expected), target_path)
require("vimoi.api").diff_files(source_path, target_path)
dofile("tests/helpers/diff.lua")()

local source_buf = vim.fn.bufnr(source_path)
local target_buf = vim.fn.bufnr(target_path)
local source_win = vim.fn.bufwinid(source_buf)
local source_map = require("vimoi.gotmpl.source_map")
local trace_async = source_map.trace_async
local rendered = false
source_map.trace_async = function(source, opts, callback)
  return trace_async(source, opts, function(trace, trace_error)
    callback(trace, trace_error)
    rendered = true
  end)
end

util.set_buffer_text(source_buf, changed_source)
vim.cmd("doautocmd TextChanged")
assert(
  vim.wait(2000, function()
    return rendered
  end, 10),
  "new control block did not finish an asynchronous render"
)
source_map.trace_async = trace_async

local summary = assert(vim.api.nvim_buf_call(target_buf, function()
  return require("vimoi.api").readd()
end))
assert(summary.merged == 0 and summary.skipped == 0, vim.inspect(summary))
assert(vim.api.nvim_win_call(source_win, function()
  return vim.fn.synIDattr(vim.fn.diff_hlID(4, 1), "name")
end) == "", "new template action was highlighted as static text")

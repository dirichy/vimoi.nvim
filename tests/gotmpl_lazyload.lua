local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
local original = "first=old\nkeep\nlast=old\n"
local changed = "first=new\nkeep\nlast=new\n"
vim.fn.writefile({ "first=old", "keep", "last=old" }, source)
vim.fn.writefile({ "first=new", "keep", "last=new" }, target)
local function assert_merge_unloaded()
  assert(package.loaded["vimoi.gotmpl.merge"] == nil, "opening a view eagerly loaded merge")
  assert(package.loaded["vimoi.gotmpl.merge_plan"] == nil, "opening a view eagerly loaded merge planning")
end
assert_merge_unloaded()
api.preview({ source = source })
local session = assert(view_for_buffer(vim.fn.bufnr(source)))
assert(vim.wait(5000, function()
  return session.trace ~= nil
end))
assert_merge_unloaded()
api.diff_files(source, target)
dofile("tests/helpers/diff.lua")()
assert_merge_unloaded()
session = assert(view_for_buffer(vim.fn.bufnr(source)))
vim.api.nvim_set_current_win(session.target_win)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
assert(api.put_hunk())
assert(package.loaded["vimoi.gotmpl.merge"] ~= nil and package.loaded["vimoi.gotmpl.merge_plan"] ~= nil)
local util = require("vimoi.util")
assert(util.buffer_text(session.source_buf) == "first=new\nkeep\nlast=old\n")
local result = assert(api.readd())
assert(result.merged == 1 and result.skipped == 0)
assert(util.buffer_text(session.source_buf) == changed)
assert(util.read_file(source) == original, "explicit merging must not save source automatically")

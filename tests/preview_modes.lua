local view_for_buffer = dofile("tests/helpers/view.lua")
local api = require("vimoi.api")
local util = require("vimoi.core.util")
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
vim.opt.swapfile = false
local source = fixture .. "/source/dot_diff_target.tmpl"
local target = vim.env.VIMOI_TEST_DESTINATION .. "/.diff_target"
vim.cmd("edit " .. vim.fn.fnameescape(source))
local source_buf = vim.api.nvim_get_current_buf()
local calls = 0
local original_do = function()
  calls = calls + 1
end
vim.keymap.set("n", "do", original_do, { buffer = source_buf, desc = "original do" })
vim.keymap.set("n", "zo", "<Nop>", { buffer = source_buf, desc = "original zo" })
api.diff()
dofile("tests/helpers/diff.lua")()
local target_buf = vim.fn.bufnr(target)
local before = util.buffer_text(target_buf)
assert(vim.fn.maparg("do", "n", false, true).desc == "Get chezmoi target hunk into source template")

-- Diff -> preview reuses the pair and retires temporary diff mappings.
vim.api.nvim_set_current_win(vim.fn.bufwinid(target_buf))
api.preview()
local output = assert(assert(view_for_buffer(source_buf)).target_buf)
assert(#vim.api.nvim_tabpage_list_wins(0) == 2 and not vim.wo.diff)
assert(vim.fn.maparg("do", "n", false, true).desc == "original do")
assert(vim.fn.maparg("zo", "n", false, true).desc == "original zo")
vim.cmd("normal do")
assert(calls == 1)
assert(vim.wait(5000, function()
  return not (view_for_buffer(source_buf) or {}).loading
end))
assert(util.buffer_text(target_buf) == before)

-- Preview -> diff also reuses two windows, including invocation from the readonly result.
vim.api.nvim_set_current_win(vim.fn.bufwinid(output))
api.diff()
dofile("tests/helpers/diff.lua")()
assert(#vim.api.nvim_tabpage_list_wins(0) == 2 and vim.api.nvim_buf_is_valid(output))
assert(assert(view_for_buffer(source_buf)).target_buf == target_buf and not vim.bo[target_buf].readonly)
vim.api.nvim_win_close(vim.fn.bufwinid(target_buf), true)
assert(vim.fn.maparg("do", "n", false, true).desc == "original do")
assert(vim.fn.maparg("zo", "n", false, true).desc == "original zo")

-- Explicit source arguments switch the source without leaving an orphan preview window.
vim.cmd("VimoiPreview")
output = assert(assert(view_for_buffer(source_buf)).target_buf)
local other = vim.fn.tempname() .. ".tmpl"
vim.fn.writefile({ 'other={{ "result" }}' }, other)
vim.cmd("VimoiPreview " .. vim.fn.fnameescape(other))
local other_buf = vim.fn.bufnr(other)
local other_output = assert(assert(view_for_buffer(other_buf)).target_buf)
assert(#vim.api.nvim_tabpage_list_wins(0) == 2 and vim.api.nvim_buf_is_valid(output))
assert(vim.wait(5000, function()
  return util.buffer_text(other_output) == "other=result\n"
end))
vim.api.nvim_win_close(vim.fn.bufwinid(other_output), true)

-- Init templates use the same --init rendering as diff, without opening the real config file.
local init_fixture = root .. "/tests/fixtures/init"
vim.env.VIMOI_TEST_CONFIG = init_fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = init_fixture .. "/source"
require("vimoi.core.cli").invalidate()
local init_source = init_fixture .. "/source/.chezmoi.toml.tmpl"
api.preview({ source = init_source })
local init_buf = vim.fn.bufnr(init_source)
local init_output = assert(assert(view_for_buffer(init_buf)).target_buf)
assert(vim.wait(5000, function()
  return not (view_for_buffer(init_buf) or {}).loading
end))
assert(not (view_for_buffer(init_output) or {}).preview_error)
assert(util.buffer_text(init_output) == "# Deliberately empty.\n", util.buffer_text(init_output))
assert(vim.bo[init_output].filetype == "toml")
print("preview modes: switching, original mappings, target isolation, explicit sources, and init templates verified")

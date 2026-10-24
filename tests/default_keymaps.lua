local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.g.mapleader = " "
vim.opt.swapfile = false
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
assert(package.loaded["vimoi.gotmpl"] == nil, "installing entry maps must preserve lazy loading")
for lhs, name in pairs({
  [" cd"] = "diff",
  [" cp"] = "preview",
  [" ct"] = "toggle",
  [" cr"] = "invalidate_cache",
  [" ca"] = "readd",
  [" cx"] = "cancel_command",
}) do
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  assert(mapping.buffer == 0 and mapping.desc)
  local original, called = api[name], false
  api[name] = function()
    called = true
  end
  mapping.callback()
  api[name] = original
  assert(called, name .. " mapping dispatched to the wrong API")
end

local util = require("vimoi.util")
local sessions = require("vimoi.gotmpl.view")
local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
vim.fn.writefile({ "value=old" }, source)
vim.fn.writefile({ "value=new" }, target)
local source_buf = vim.fn.bufadd(source)
api.diff_files(source, target)
dofile("tests/helpers/diff.lua")()
local session = assert(view_for_buffer(source_buf))
for _, win in ipairs({ session.source_win, session.target_win }) do
  vim.api.nvim_set_current_win(win)
  local mapping = vim.fn.maparg(" ca", "n", false, true)
  assert(mapping.buffer == 0 and mapping.desc == "Re-add target changes to chezmoi source")
end
vim.fn.maparg(" ca", "n", false, true).callback()
assert(util.buffer_text(source_buf) == "value=new\n")
sessions.close(session)
vim.api.nvim_set_current_win(session.source_win)
assert(vim.fn.maparg(" ca", "n", false, true).buffer == 0)

api.preview({ source = source })
local preview = assert(view_for_buffer(source_buf))
assert(preview.preview)
vim.api.nvim_set_current_win(preview.target_win)
assert(vim.fn.maparg(" ca", "n", false, true).buffer == 0)
sessions.close(preview)
vim.fn.delete(source)
vim.fn.delete(target)

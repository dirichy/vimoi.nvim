vim.opt.swapfile = false
local api = require("vimoi.api")
require("vimoi").setup({ diagnostics = { enabled = false } })
local sessions = require("vimoi.gotmpl.view")
local original = vim.o.diffexpr
local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
vim.fn.writefile({ 'value={{ "one" }}' }, source)
vim.fn.writefile({ "value=two" }, target)
api.diff_files(source, target)
local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
dofile("tests/helpers/diff.lua")()
assert(vim.o.diffexpr ~= original)

-- Unrelated plain diff must still respect the user's whitespace options.
vim.cmd("tabnew")
local plain_source, plain_target = vim.fn.tempname(), vim.fn.tempname()
vim.fn.writefile({ "value = one" }, plain_source)
vim.fn.writefile({ "value   = one" }, plain_target)
vim.opt.diffopt = { "internal", "filler", "iwhite" }
api.diff_files(plain_source, plain_target)
vim.cmd("diffupdate")
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  assert(vim.api.nvim_win_call(win, function()
    return vim.fn.diff_hlID(1, 1)
  end) == 0, "template diff changed unrelated iwhite behavior")
end
vim.cmd("tabnew")
api.diff_files(source, target)
local other_session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
dofile("tests/helpers/diff.lua")()
sessions.close(session)
assert(vim.o.diffexpr ~= original, "closing one of two views removed the shared handler")
sessions.close(other_session)
assert(vim.o.diffexpr == original, "closing the last template diff retained its global handler")

-- A later view must reinstall and release the dispatcher again.
local delegated = 0
_G.VimoiTestDiffexpr = function()
  delegated = delegated + 1
  local before = table.concat(vim.fn.readfile(vim.v.fname_in), "\n") .. "\n"
  local after = table.concat(vim.fn.readfile(vim.v.fname_new), "\n") .. "\n"
  local patch = vim.text.diff(before, after, { result_type = "unified", ctxlen = 0 })
  assert(type(patch) == "string")
  vim.fn.writefile(vim.split(patch, "\n", { plain = true }), vim.v.fname_out)
end
local custom_diffexpr = "v:lua.VimoiTestDiffexpr()"
vim.o.diffexpr = custom_diffexpr
vim.cmd("tabnew")
api.diff_files(source, target)
session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
dofile("tests/helpers/diff.lua")()
assert(vim.o.diffexpr ~= original)
sessions.close(session)
assert(vim.o.diffexpr == custom_diffexpr, "reopen lost the user's new diffexpr")
assert(delegated > 0, "native diffexpr protocol checks did not reach the user's handler")
vim.o.diffexpr = original
_G.VimoiTestDiffexpr = nil
print("native diff lifecycle: unrelated options, last-view restoration and reopen verified")

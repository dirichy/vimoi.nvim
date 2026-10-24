local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
local wrapper = fixture .. "/chezmoi-wrapper.sh"
-- Keymaps are configurable and may be disabled without changing the API.
require("vimoi").setup({
  chezmoi_executable = wrapper,
  keymaps = {
    diff = "<leader>xd",
    preview = false,
    invalidate_cache = "",
    readd = "<leader>xa",
    goto_file = "gF",
    goto_file_line = "gL",
    diff_get = "gD",
    diff_put = false,
  },
})
local custom_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, custom_buf)
vim.bo[custom_buf].filetype = "gotmpl"
assert(vim.fn.maparg("gF", "n", false, true).desc == "Open chezmoi path under cursor")
assert(vim.fn.maparg("gL", "n", false, true).desc == "Open chezmoi path and line under cursor")
assert(require("vimoi").config.keymaps.diff_put == false)

assert(vim.fn.maparg("<leader>xd", "n", false, true).desc == "Open chezmoi diff")
for _, lhs in ipairs({ "<leader>cd", "<leader>cp", "<leader>cr", "<leader>ca" }) do
  assert(vim.fn.maparg(lhs, "n") == "", lhs .. " unexpectedly installed globally")
end

local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
vim.fn.writefile({ "old" }, source)
vim.fn.writefile({ "new" }, target)
require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()
local sessions = require("vimoi.gotmpl.view")
local session = assert(view_for_buffer(vim.fn.bufnr(source)))
for _, win in ipairs({ session.source_win, session.target_win }) do
  vim.api.nvim_set_current_win(win)
  assert(vim.fn.maparg("<leader>xa", "n", false, true).desc == "Re-add target changes to chezmoi source")
  assert(vim.fn.maparg("<leader>ca", "n") == "")
  local expected = require("vimoi.api").get_hunk
  assert(vim.fn.maparg("gD", "n", false, true).callback == expected)
  assert(vim.fn.maparg("do", "n") == "" and vim.fn.maparg("dp", "n") == "")
end
assert(vim.fn.maparg("dp", "n") == "", "disabled diff_put was installed")
sessions.close(session)
vim.fn.delete(source)
vim.fn.delete(target)

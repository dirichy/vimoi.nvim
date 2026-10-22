local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh", keymaps = false })
for name, lhs in pairs(require("vimoi").config.keymaps) do
  assert(lhs == false, name .. " stayed enabled")
end
for _, lhs in ipairs({
  "<leader>cd",
  "<leader>cp",
  "<leader>cs",
  "<leader>ct",
  "<leader>cr",
  "<leader>ca",
  "<leader>cx",
}) do
  assert(vim.fn.maparg(lhs, "n") == "")
end
local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
vim.fn.writefile({ "old" }, source)
vim.fn.writefile({ "new" }, target)
api.diff_files(source, target)
dofile("tests/helpers/diff.lua")()
local sessions = require("vimoi.gotmpl.session")
local session = assert(view_for_buffer(vim.fn.bufnr(source)))
assert(#session.keymaps == 0, "keymaps=false installed session mappings")
for _, buf in ipairs({ session.source_buf, session.target_buf }) do
  assert(#vim.api.nvim_buf_get_keymap(buf, "n") == 0, "keymaps=false installed buffer mappings")
end
require("vimoi").setup()
assert(require("vimoi").config.keymaps.readd == false, "repeated setup reset disabled mappings")
sessions.close(session)
vim.fn.delete(source)
vim.fn.delete(target)

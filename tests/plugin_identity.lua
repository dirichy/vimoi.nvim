-- Another chezmoi integration may own the old Lua namespace and commands.
local other_loads, other_calls = 0, 0
package.preload["chezmoi"] = function()
  other_loads = other_loads + 1
  return {}
end
vim.api.nvim_create_user_command("ChezmoiDiff", function()
  other_calls = other_calls + 1
end, {})

local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local api = require("vimoi.api")
assert(type(api.readd) == "function" and rawget(api, "template_readd") == nil)
assert(require("vimoi").config.keymaps.readd == "<leader>ca")
for _, command in ipairs({ "Diff", "DiffPut", "DiffGet", "Preview", "Toggle", "ReAdd", "Cancel" }) do
  assert(vim.fn.exists(":Vimoi" .. command) == 2)
end
assert(vim.fn.exists(":VimoiTmplReAdd") == 0 and vim.fn.exists(":ChezmoiTmplReAdd") == 0)
assert(other_loads == 0 and package.loaded["chezmoi"] == nil)
vim.cmd("ChezmoiDiff")
assert(other_calls == 1, "vimoi replaced another plugin's command")

-- Notifications, injected highlighting, previews and help use vimoi's identity.
local original_notify, message = vim.notify, nil
vim.notify = function(text)
  message = text
end
require("vimoi.core.util").notify("test", "diff")
vim.notify = original_notify
assert(message == "vimoi diff: test")
assert(vim.tbl_contains(vim.treesitter.query.list_directives(), "vimoi-target-language!"))
vim.cmd("help vimoi.nvim@en")
assert(vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "vimoi.txt")
vim.cmd("help vimoi.nvim@cn")
assert(vim.fs.basename(vim.api.nvim_buf_get_name(0)) == "vimoi.cnx")
print("plugin identity: vimoi API, commands, help and coexistence with another chezmoi plugin verified")

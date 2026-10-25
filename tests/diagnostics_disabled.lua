---@diagnostic disable: duplicate-set-field -- Observe that disabled consumers start no command.
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
local cli = require("vimoi.core.cli")
local original = cli.execute_template
local runs = 0
cli.execute_template = function(...)
  runs = runs + 1
  return original(...)
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "gotmpl"
require("vimoi.core.util").set_buffer_text(buf, "{{ invalid . }}")
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
local drained = false
vim.defer_fn(function()
  drained = true
end, 300)
assert(vim.wait(1000, function()
  return drained
end, 5))
assert(runs == 0 and #vim.diagnostic.get(buf) == 0)
cli.execute_template = original
vim.api.nvim_buf_delete(buf, { force = true })

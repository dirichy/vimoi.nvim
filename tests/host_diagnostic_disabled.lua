local checks = 0
package.loaded.lint = {
  linters_by_ft = { lua = { "test" } },
  linters = { test = { stdin = true } },
  lint = function()
    checks = checks + 1
  end,
}
require("vimoi").setup({ diagnostics = { host = false } })
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local util = require("vimoi.core.util")
util.set_buffer_text(buf, 'local value = {{ "1" }}\n')
require("vimoi.editor.highlight").configure_template_buffer(buf, "lua")
local sessions = require("vimoi.render")
assert(vim.wait(5000, function()
  return sessions.snapshot(buf) ~= nil
end, 5))
assert(checks == 0 and #vim.diagnostic.get(buf) == 0)
util.set_buffer_text(buf, "{{ if")
local namespace = vim.api.nvim_create_namespace("vimoi-diagnostics")
assert(vim.wait(5000, function()
  return #vim.diagnostic.get(buf, { namespace = namespace }) > 0
end, 5))
assert(checks == 0, "host=false started a host provider")
vim.api.nvim_buf_delete(buf, { force = true })

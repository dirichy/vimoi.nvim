vim.cmd("syntax on")

local api = require("vimoi.api")
local function background()
  return vim.api.nvim_get_hl(0, { name = "VimoiTemplateAction", link = false }).bg
end

vim.o.background = "dark"
api.setup()
assert(background() == 0x343B52)

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = {{- if .value -}}", "inside", "{{ end }}" })
require("vimoi.highlight").configure_template_buffer(buf, "lua")
assert(vim.fn.synIDattr(vim.fn.synID(1, 14, 1), "name") == "VimoiTemplateAction")
assert(vim.fn.synIDattr(vim.fn.synID(2, 1, 1), "name") == "")
assert(vim.fn.synIDattr(vim.fn.synID(3, 2, 1), "name") == "VimoiTemplateAction")

api.setup({ highlight = { template_bg = "#123456" } })
assert(background() == 0x123456)
vim.o.background = "light"
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
assert(background() == 0x123456)

api.setup()
assert(background() == 0xE4E9F4)
vim.api.nvim_set_hl(0, "VimoiTemplateAction", { bg = "#000000" })
vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test-theme" })
assert(background() == 0xE4E9F4)
vim.o.background = "dark"
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
assert(background() == 0x343B52)

-- Unrelated OptionSet events must preserve a user's highlight override.
vim.api.nvim_set_hl(0, "VimoiTemplateAction", { bg = "#abcdef" })
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "number" })
assert(background() == 0xabcdef)

-- Template text keeps its host-language injection tree.
local injection_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(injection_buf, 0, -1, false, {
  "local value = {{ .value }}",
  "print(value)",
})

require("vimoi.highlight").configure_template_buffer(injection_buf, "lua")
assert(background() == 0xabcdef, "configuring a buffer must preserve highlight overrides")
assert(vim.bo[injection_buf].filetype == "gotmpl")
assert(vim.b[injection_buf].vimoi_template_language == "lua")

local parser = assert(vim.treesitter.get_parser(injection_buf, "gotmpl"))
parser:parse(true)
assert(parser:children().lua, "gotmpl text nodes did not create a Lua injection tree")

vim.api.nvim_buf_delete(injection_buf, { force = true })

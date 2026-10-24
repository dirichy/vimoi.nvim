vim.cmd("syntax on")

local function background()
  return vim.api.nvim_get_hl(0, { name = "VimoiTemplateAction", link = false }).bg
end

vim.o.background = "dark"
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#20242c", fg = "#ff0000", bold = true })
require("vimoi").setup()
assert(background() == 0x20242c)
local action = vim.api.nvim_get_hl(0, { name = "VimoiTemplateAction", link = false })
assert(action.fg == vim.api.nvim_get_hl(0, { name = "Statement", link = false }).fg)
assert(not action.bold, "borrowing a background also borrowed foreground styling")

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = {{- if .value -}}", "inside", "{{ end }}" })
require("vimoi.highlight").configure_template_buffer(buf, "lua")
assert(vim.fn.synIDattr(vim.fn.synID(1, 14, 1), "name") == "VimoiTemplateAction")
assert(vim.fn.synIDattr(vim.fn.synID(2, 1, 1), "name") == "")
assert(vim.fn.synIDattr(vim.fn.synID(3, 2, 1), "name") == "VimoiTemplateAction")

require("vimoi").setup({ highlight = { template_bg = "#123456" } })
assert(background() == 0x123456)
vim.o.background = "light"
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
assert(background() == 0x123456)

-- Theme backgrounds are resolved again after colorscheme/background changes.
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#eeeeee" })
require("vimoi").setup()
assert(background() == 0xeeeeee)
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#dddddd" })
vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test-theme" })
assert(background() == 0xdddddd)
vim.o.background = "dark"
vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#20242c" })
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
assert(background() == 0x20242c)

-- Explicit colors and dark/light overrides remain supported.
require("vimoi").setup({ highlight = { template_bg = { dark = "#123456", light = "#abcdef" } } })
assert(background() == 0x123456)
vim.o.background = "light"
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "background" })
assert(background() == 0xabcdef)

-- Linked and reversed theme groups contribute their visible background only.
vim.api.nvim_set_hl(0, "TestTemplateSurface", { fg = "#112233", bg = "#445566", reverse = true, ctermfg = 1 })
vim.api.nvim_set_hl(0, "TestTemplateLink", { link = "TestTemplateSurface" })
require("vimoi").setup({ highlight = { template_bg = "TestTemplateLink" } })
assert(background() == 0x112233)
assert(vim.api.nvim_get_hl(0, { name = "VimoiTemplateAction", link = false }).ctermbg == 1)
vim.api.nvim_set_hl(0, "TestTemplateSurface", { fg = "#112233" })
vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test-theme" })
assert(background() == nil, "a theme group without a background gained a fixed color")
require("vimoi").setup()

-- Unrelated OptionSet events must preserve a user's highlight override.
require("vimoi").setup({ highlight = { mode = "injection" } })
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

-- A user's FileType autocmd can parse gotmpl before host metadata is available.
local early_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(early_buf, 0, -1, false, { "local value = {{ .value }}", "print(value)" })
vim.api.nvim_create_autocmd("FileType", {
  buffer = early_buf,
  once = true,
  callback = function()
    vim.treesitter.start(early_buf, "gotmpl")
    assert(vim.treesitter.get_parser(early_buf, "gotmpl")):parse(true)
  end,
})
vim.bo[early_buf].filetype = "gotmpl"
local early_parser = assert(vim.treesitter.get_parser(early_buf, "gotmpl"))
assert(not early_parser:children().lua, "host injection should not exist before host detection")
require("vimoi.highlight").configure_template_buffer(early_buf, "lua")
assert(vim.treesitter.get_parser(early_buf, "gotmpl") == early_parser, "host setup replaced the parser")
early_parser:parse(true)
assert(early_parser:children().lua, "early FileType parsing prevented host language injection")
assert(vim.bo[early_buf].filetype == "gotmpl")
assert(vim.bo[early_buf].syntax == "gotmpl")

-- A different target language must also replace cached injection regions.
require("vimoi.highlight").configure_template_buffer(early_buf, "toml")
early_parser:parse(true)
assert(early_parser:children().toml, "host language change did not refresh injections")
assert(not early_parser:children().lua, "old host language injection survived reconfiguration")
vim.api.nvim_buf_delete(early_buf, { force = true })

-- The TUI parses visible ranges. Combined injections must be declared in the
-- query so text beyond that range still completes a multiline host construct.
local yaml_buf = vim.api.nvim_create_buf(false, true)
require("vimoi.util").set_buffer_text(
  yaml_buf,
  'message: "{{ "A" }}\n' .. string.rep("  text\n", 100) .. '  {{ "B" }}"\nnext: true\n'
)
require("vimoi.highlight").configure_template_buffer(yaml_buf, "yaml")
local yaml_parser = assert(vim.treesitter.get_parser(yaml_buf, "gotmpl"))
yaml_parser:parse({ 0, 10 })
local yaml = assert(yaml_parser:children().yaml)
for _, tree in pairs(yaml:trees()) do
  assert(not tree:root():has_error(), "viewport parsing truncated the combined YAML injection")
end
assert(vim.treesitter.query.get("gotmpl", "injections").has_combined_injections)
vim.api.nvim_buf_delete(yaml_buf, { force = true })

-- Disabled removes native host injections even when switching directly from
-- injection mode, while retaining gotmpl parsing and action highlighting.
local disabled_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(disabled_buf, 0, -1, false, { "local x = {{ .value }}" })
require("vimoi.highlight").configure_template_buffer(disabled_buf, "lua")
local disabled_parser = assert(vim.treesitter.get_parser(disabled_buf, "gotmpl"))
disabled_parser:parse(true)
assert(disabled_parser:children().lua)
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
disabled_parser:parse(true)
assert(not disabled_parser:children().lua, "disabled mode retained a host injection")
assert(vim.bo[disabled_buf].filetype == "gotmpl" and vim.bo[disabled_buf].syntax == "gotmpl")
vim.api.nvim_buf_call(disabled_buf, function()
  assert(vim.fn.synIDattr(vim.fn.synID(1, 12, 1), "name") == "VimoiTemplateAction")
end)
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "injection" } })
disabled_parser:parse(true)
assert(disabled_parser:children().lua, "injection did not recover after disabled mode")

-- The Vim syntax fallback must also follow mode changes, including buffers
-- first configured while disabled. This language deliberately has no parser.
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
require("vimoi.highlight").configure_template_buffer(disabled_buf, "vimoi_missing_parser")
assert(vim.bo[disabled_buf].syntax == "gotmpl", "disabled enabled a host syntax fallback")
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "injection" } })
assert(vim.bo[disabled_buf].syntax == "vimoi_missing_parser", "switching modes did not restore fallback syntax")
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
assert(vim.bo[disabled_buf].syntax == "gotmpl", "switching modes did not disable fallback syntax")
vim.api.nvim_buf_delete(disabled_buf, { force = true })

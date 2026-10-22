vim.opt.swapfile = false
vim.cmd("filetype plugin on")
vim.cmd("syntax on")

local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local source_dir = fixture .. "/source"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source_dir
vim.env.VIMOI_TEST_DESTINATION = "/tmp/vimoi-filetype-dest"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })

local cases = {
  [".chezmoiignore"] = "gotmpl",
  [".chezmoiremove"] = "gotmpl",
  [".chezmoiexternal.json"] = "gotmpl",
  [".chezmoiexternal.jsonc"] = "gotmpl",
  [".chezmoiexternal.toml"] = "gotmpl",
  [".chezmoiexternal.yaml"] = "gotmpl",
  [".chezmoiexternal.yml"] = "gotmpl",
  [".chezmoiexternals/packages.toml"] = "gotmpl",
  [".chezmoitemplates/script.sh"] = "gotmpl",
  ["script.sh.tmpl"] = "gotmpl",
  [".chezmoidata.toml"] = "toml",
  [".chezmoiscripts/run_script.sh"] = "sh",
}
for path, expected in pairs(cases) do
  local actual = vim.filetype.match({ filename = source_dir .. "/" .. path })
  assert(actual == expected, ("%s: expected %s, got %s"):format(path, expected, tostring(actual)))
end
for _, path in ipairs({ ".chezmoiignore", ".chezmoiexternal.toml", ".chezmoiexternal.ini", "script.sh.tmpl" }) do
  assert(vim.filetype.match({ filename = "/tmp/vimoi-filetype/" .. path }) ~= "gotmpl", path)
end
assert(vim.filetype.match({ filename = source_dir .. "-other/script.sh.tmpl" }) ~= "gotmpl")
assert(vim.filetype.match({ filename = source_dir .. "/.chezmoiexternal.ini" }) ~= "gotmpl")

local filetype = require("vimoi.filetype")
local host_cases = {
  [".chezmoiignore"] = "gitignore",
  [".chezmoiignore.tmpl"] = "gitignore",
  [".chezmoiremove"] = "gitignore",
  [".chezmoiremove.tmpl"] = "gitignore",
  [".chezmoiexternal.toml"] = "toml",
  [".chezmoiexternal.toml.tmpl"] = "toml",
  [".chezmoiexternal.json"] = "json",
  [".chezmoiexternal.jsonc"] = "jsonc",
  [".chezmoiexternal.yaml"] = "yaml",
  [".chezmoiexternal.yml"] = "yaml",
  [".chezmoiexternals/packages.toml"] = "toml",
  [".chezmoiexternals/nested/packages.jsonc"] = "jsonc",
  [".chezmoiexternals/nested/packages.yml"] = "yaml",
  [".chezmoiexternals/packages.toml.tmpl"] = "toml",
  [".chezmoitemplates/script.sh"] = "sh",
  [".chezmoitemplates/nested/script.sh"] = "sh",
  ["nested/.chezmoiignore"] = "gitignore",
  ["script.sh.tmpl"] = "sh",
  ["init.lua.tmpl"] = "lua",
  [".chezmoi.toml.tmpl"] = "toml",
}
for path, expected in pairs(host_cases) do
  local filename = source_dir .. "/" .. path
  assert(vim.filetype.match({ filename = filename }) == "gotmpl", path .. " was not detected as gotmpl")
  local actual = filetype.host_filetype(filename)
  assert(actual == expected, ("%s: expected host %s, got %s"):format(path, expected, tostring(actual)))
end
assert(filetype.host_filetype("/tmp/vimoi-filetype/.chezmoidata.toml") == "toml")

local zsh_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(zsh_buf)
local zsh_path = source_dir .. "/run_onchange_after_install-packages-macos.sh.tmpl"
vim.api.nvim_buf_set_name(zsh_buf, zsh_path)
vim.api.nvim_buf_set_lines(zsh_buf, 0, -1, false, { "#!/usr/bin/env zsh", "print -r -- hello" })
assert(filetype.host_filetype(zsh_path, zsh_buf) == "zsh")
assert(filetype.host_filetype(source_dir .. "/.chezmoitemplates/install", zsh_buf) == "zsh")
vim.bo[zsh_buf].filetype = "gotmpl"
assert(vim.wait(300, function()
  return vim.b[zsh_buf].vimoi_template_configured == true
end))
assert(vim.b[zsh_buf].vimoi_template_language == "zsh" or vim.bo[zsh_buf].syntax == "zsh")

local external_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(external_buf)
vim.api.nvim_buf_set_name(external_buf, source_dir .. "/.chezmoiexternal.toml")
vim.api.nvim_buf_set_lines(external_buf, 0, -1, false, { '["file"]', 'type = "file"', "url = {{ .url | quote }}" })
vim.bo[external_buf].filetype = "gotmpl"
assert(vim.wait(300, function()
  return vim.b[external_buf].vimoi_template_configured == true
end))
assert(vim.b[external_buf].vimoi_template_language == "toml")
assert(assert(vim.treesitter.get_parser(external_buf, "gotmpl")):parse(true))
assert(assert(vim.treesitter.get_parser(external_buf, "gotmpl")):children().toml)

local ignore_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(ignore_buf)
vim.api.nvim_buf_set_name(ignore_buf, source_dir .. "/.chezmoiignore")
vim.api.nvim_buf_set_lines(ignore_buf, 0, -1, false, { "*.txt", "{{ if .work }}", "work/**", "{{ end }}" })
vim.bo[ignore_buf].filetype = "gotmpl"
assert(vim.wait(300, function()
  return vim.b[ignore_buf].vimoi_template_configured == true
end))
assert(vim.b[ignore_buf].vimoi_template_language == "gitignore")
assert(vim.b[ignore_buf].vimoi_gf == true, "gotmpl FileType did not attach gf")
assert(assert(vim.treesitter.get_parser(ignore_buf, "gotmpl")):parse(true))
assert(assert(vim.treesitter.get_parser(ignore_buf, "gotmpl")):children().gitignore)

local buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, source_dir .. "/script.sh.tmpl")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "if true; then", "echo {{ .chezmoi.os }}", "fi" })
local shell_language = vim.treesitter.language.get_lang("sh") or "sh"
local original_add = vim.treesitter.language.add
---@diagnostic disable-next-line: duplicate-set-field -- Simulate an unavailable parser.
vim.treesitter.language.add = function(language, ...)
  if language == shell_language then
    return nil, "test: shell parser unavailable"
  end
  return original_add(language, ...)
end
vim.bo[buf].filetype = "gotmpl"
assert(
  vim.wait(300, function()
    return vim.b[buf].vimoi_template_configured == true
  end),
  "gotmpl ftplugin did not initialize"
)
vim.treesitter.language.add = original_add
assert(vim.bo[buf].syntax == "sh", "missing sh injection did not fall back to syntax/sh.vim")
assert(vim.b[buf].vimoi_template_language == nil)
local shell_group = vim.fn.synIDattr(vim.fn.synID(1, 1, 1), "name")
assert(shell_group == "shConditional", shell_group)
local action_group = vim.fn.synIDattr(vim.fn.synID(2, 6, 1), "name")
assert(action_group == "VimoiTemplateAction", action_group)
assert(vim.treesitter.get_parser(buf, "gotmpl")):parse(true)

local lua_buf = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(lua_buf)
vim.api.nvim_buf_set_name(lua_buf, source_dir .. "/init.lua.tmpl")
vim.api.nvim_buf_set_lines(lua_buf, 0, -1, false, { "local value = {{ .value }}" })
vim.bo[lua_buf].filetype = "gotmpl"
assert(vim.wait(300, function()
  return vim.b[lua_buf].vimoi_template_configured == true
end))
assert(vim.b[lua_buf].vimoi_template_language == "lua")
assert(vim.bo[lua_buf].syntax == "gotmpl")
local parser = assert(vim.treesitter.get_parser(lua_buf, "gotmpl"))
parser:parse(true)
assert(parser:children().lua)

-- Classification supplies navigation semantics without changing template detection.
for _, name in ipairs({ ".chezmoiignore", ".chezmoiremove", "nested/.chezmoiignore", "nested/.chezmoiremove" }) do
  for _, suffix in ipairs({ "", ".tmpl" }) do
    local path = source_dir .. "/" .. name .. suffix
    assert(filetype.path_kind(path) == "target_patterns", path)
    assert(filetype.host_filetype(path) == "gitignore", path)
  end
end
local symlink_regex = vim.fn.glob2regpat(filetype.symlink_pattern)
for _, name in ipairs({ "symlink_example", "symlink_example.tmpl", "nested/symlink_example" }) do
  local path = source_dir .. "/" .. name
  assert(filetype.path_kind(path) == "symlink_target", path)
  assert(vim.fn.match(vim.fs.basename(path), symlink_regex) >= 0, "registration and navigation disagree")
end
for _, name in ipairs({ ".chezmoiignore.bak", ".chezmoiremove.txt", ".chezmoiignore.tmpl.bak", "not_symlink_example" }) do
  assert(filetype.path_kind(source_dir .. "/" .. name) == nil, name)
end

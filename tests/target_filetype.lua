vim.opt.swapfile = false
vim.cmd("filetype plugin on")
vim.cmd("syntax on")

local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " target filetype"
local source = root .. "/source"
local destination = root .. "/target"
vim.fn.mkdir(source .. "/private_dot_config", "p")
vim.fn.mkdir(source .. "/.chezmoitemplates", "p")
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source
vim.env.VIMOI_TEST_DESTINATION = destination
local log = root .. "/commands"
local wrapper = root .. "/chezmoi"
vim.fn.writefile({
  "#!/bin/sh",
  "printf '%s\\n' \"$1\" >> " .. vim.fn.shellescape(log),
  "exec " .. vim.fn.shellescape(fixture .. "/chezmoi-wrapper.sh") .. ' "$@"',
}, wrapper)
assert(vim.uv.fs_chmod(wrapper, 493))
vim.fn.writefile({ "print -r -- {{ .chezmoi.os }}" }, source .. "/dot_zshrc.tmpl")
vim.fn.writefile({ "echo {{ .chezmoi.os }}" }, source .. "/private_dot_bashrc.tmpl")
vim.fn.writefile({ "local value = {{ 1 }}" }, source .. "/private_dot_config/example.lua.tmpl")
vim.fn.writefile({ "print -r -- plain" }, source .. "/dot_zprofile")
vim.fn.writefile({ "echo plain" }, source .. "/readonly_dot_bash_profile")
vim.fn.writefile({ "return true" }, source .. "/private_dot_config/plain.lua")

local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = wrapper, diagnostics = { enabled = false } })
local filetype = require("vimoi.editor.filetype")
local cli = require("vimoi.core.cli")

for name, expected in pairs({
  ["dot_zshrc.tmpl"] = "zsh",
  ["private_dot_bashrc.tmpl"] = "sh",
  ["private_dot_config/example.lua.tmpl"] = "lua",
  ["dot_zprofile"] = "zsh",
  ["readonly_dot_bash_profile"] = "sh",
  ["private_dot_config/plain.lua"] = "lua",
}) do
  local before = #vim.fn.readfile(log)
  assert(filetype.host_filetype(source .. "/" .. name) == expected, name)
  assert(#vim.fn.readfile(log) == before + 2, "expected target-path and reverse source-path lookup")
  assert(filetype.host_filetype(source .. "/" .. name) == expected, name)
  assert(#vim.fn.readfile(log) == before + 2, "host detection did not reuse the CLI path cache")
end
assert(not vim.uv.fs_stat(destination), "type detection must not create the target")

local before = #vim.fn.readfile(log)
assert(filetype.host_filetype(source .. "/.chezmoiignore") == "gitignore")
assert(filetype.host_filetype(source .. "/.chezmoiexternal.toml.tmpl") == "toml")
assert(filetype.host_filetype(source .. "/.chezmoitemplates/script.sh") == "sh")
assert(filetype.host_filetype(root .. "/outside.lua.tmpl") == "lua")
assert(#vim.fn.readfile(log) == before, "special and outside files must not query a deployment path")
assert(filetype.host_filetype(source .. "/unmanaged.lua.tmpl") == "lua", "failed lookup lost filename fallback")

cli.invalidate("paths")
before = #vim.fn.readfile(log)
assert(filetype.host_filetype(source .. "/dot_zshrc.tmpl") == "zsh")
assert(#vim.fn.readfile(log) == before + 2, "path invalidation did not refresh host detection")

for name, expected in pairs({
  dot_zprofile = "zsh",
  readonly_dot_bash_profile = "sh",
  ["private_dot_config/plain.lua"] = "lua",
}) do
  vim.cmd.edit(vim.fn.fnameescape(source .. "/" .. name))
  assert(vim.bo.filetype == expected, "plain source did not inherit its target filetype: " .. name)
  if name == "readonly_dot_bash_profile" then
    assert(vim.b.is_bash == 1, "target detection did not initialize bash buffer flags")
  end
end
vim.fn.writefile({ "return false" }, root .. "/outside.lua")
before = #vim.fn.readfile(log)
vim.cmd.edit(vim.fn.fnameescape(root .. "/outside.lua"))
assert(vim.bo.filetype == "lua" and #vim.fn.readfile(log) == before, "outside files must retain native detection")

-- Direct editing and preview use the same target-derived host type, without a target buffer.
vim.cmd("edit " .. vim.fn.fnameescape(source .. "/dot_zshrc.tmpl"))
local buf = vim.api.nvim_get_current_buf()
assert(vim.bo[buf].filetype == "gotmpl")
assert(vim.wait(1000, function()
  return vim.b[buf].vimoi_template_configured == true
end))
assert(vim.b[buf].vimoi_template_filetype == "zsh")
assert(vim.bo[buf].syntax == "gotmpl")
api.preview()
local session = assert(dofile("tests/helpers/view.lua")(buf))
assert(vim.bo[session.target_buf].filetype == "zsh", "preview lost target-derived host type")
assert(vim.wait(5000, function()
  return not session.loading
end))
assert(not session.preview_error, session.preview_error)
assert(not vim.uv.fs_stat(destination), "preview must not create the real target")

print("target filetype: attributes, missing target, cache, fallback, direct editing, and preview verified")

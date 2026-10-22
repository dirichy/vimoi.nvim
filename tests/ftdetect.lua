-- Simulate lazy.nvim sourcing ftdetect before it calls the plugin's setup.
assert(package.loaded["vimoi.filetype"] == nil)
vim.cmd("runtime ftdetect/vimoi.lua")
assert(package.loaded["vimoi.filetype"] == nil, "ftdetect loaded the plugin before a template was seen")

local source_root = vim.fn.getcwd() .. "/tests/fixtures/environment/source"
assert(vim.fn.exists(":VimoiDiff") == 0)
assert(vim.filetype.match({ filename = source_root .. "/dot_diff_target.tmpl" }) ~= "gotmpl")
local filetype = require("vimoi.filetype")
assert(package.loaded["vimoi.cli"] == nil, "filename detection must not load the CLI")
assert(filetype.is_template(source_root .. "/dot_diff_target.tmpl"))
assert(filetype.detect(source_root .. "/dot_diff_target.tmpl") == nil)
filetype.setup(source_root)
assert(vim.filetype.match({ filename = source_root .. "/dot_diff_target.tmpl" }) == "gotmpl")
assert(vim.filetype.match({ filename = "/tmp/unmanaged.txt.tmpl" }) ~= "gotmpl")
assert(package.loaded["vimoi.cli"] == nil, "filetype setup must not load the CLI")
assert(vim.fn.exists(":VimoiDiff") == 0)

local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source_root
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
assert(vim.fn.exists(":VimoiDiff") == 2)
assert(vim.filetype.match({ filename = source_root .. "/dot_diff_target.tmpl" }) == "gotmpl")

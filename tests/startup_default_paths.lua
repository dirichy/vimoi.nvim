---@diagnostic disable: duplicate-set-field -- Empty XDG variables must use chezmoi's home defaults without subprocesses.
local system = vim.system
vim.system = function()
  error("setup must not run chezmoi")
end
vim.env.XDG_DATA_HOME = ""
vim.env.XDG_CONFIG_HOME = ""
require("vimoi").setup()
local home = vim.env.HOME or vim.uv.os_homedir()
local cli = require("vimoi.core.cli")
assert(cli.source_root == vim.fs.joinpath(home, ".local", "share", "chezmoi"))
assert(cli.config_path == vim.fs.joinpath(home, ".config", "chezmoi", "chezmoi.toml"))
vim.system = system

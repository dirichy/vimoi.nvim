---@diagnostic disable: duplicate-set-field -- Configuration and filename checks must not run commands.
local system = vim.system
vim.system = function()
  error("startup must not run chezmoi")
end
local data_home = vim.fn.tempname() .. " $literal data"
vim.env.XDG_DATA_HOME = data_home
vim.env.XDG_CONFIG_HOME = data_home .. "/config"
require("vimoi").setup()
assert(require("vimoi").config.chezmoi_source_dir == data_home .. "/chezmoi")
assert(require("vimoi.editor.filetype").detect(data_home .. "/chezmoi/dot_file.tmpl") == "gotmpl")
assert(require("vimoi.editor.filetype").detect(data_home .. "/chezmoi-other/dot_file.tmpl") == nil)
assert(require("vimoi.core.cli").config_path == data_home .. "/config/chezmoi/chezmoi.toml")
vim.system = system

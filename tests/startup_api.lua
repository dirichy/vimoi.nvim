---@diagnostic disable: duplicate-set-field -- Explicit paths must activate without an identity query.
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local source = fixture .. "/source"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = source
local calls = 0
local system = vim.system
vim.system = function(argv, ...)
  calls = calls + 1
  assert(argv[2] == "--config" and argv[3] == fixture .. "/empty.toml")
  assert(argv[4] == "--source" and argv[5] == source)
  assert(argv[6] == "target-path", "explicit configuration must skip identity discovery")
  return system(argv, ...)
end
require("vimoi").setup({
  chezmoi_source_dir = source,
  chezmoi_config_path = fixture .. "/empty.toml",
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})
assert(calls == 0 and package.loaded["vimoi.core.cli"] ~= nil)
local opened = require("vimoi.api").toggle(vim.env.VIMOI_TEST_DESTINATION .. "/.plain")
assert(opened == source .. "/dot_plain" and calls == 1)
vim.system = system

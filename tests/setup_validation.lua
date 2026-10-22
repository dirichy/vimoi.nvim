local plugin = require("vimoi")
local original = vim.deepcopy(plugin.config)
for _, input in ipairs({
  "false",
  '{"keymaps":true}',
  '{"keymaps":{"diff":true}}',
  '{"keymaps":{"unknown":"x"}}',
  '{"completion":false}',
  '{"diagnostics":{"enabled":"yes"}}',
  '{"diff":{"validate":1}}',
  '{"watch":{"buffer_write_fallback":"always"}}',
  '{"chezmoi_executable":false}',
  '{"chezmoi_config_path":false}',
}) do
  local ok = pcall(plugin.setup, vim.json.decode(input))
  assert(not ok, "invalid configuration was accepted: " .. input)
  assert(package.loaded["vimoi.cli"] == nil, "invalid configuration started CLI initialization")
  assert(vim.deep_equal(original, plugin.config), "invalid configuration was published")
end
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
plugin.setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
assert(vim.fn.exists(":VimoiToggle") == 2, "valid setup could not recover after invalid input")
print("setup validation: invalid public settings fail before side effects and valid setup can retry")

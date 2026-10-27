local plugin = require("vimoi")
local original = vim.deepcopy(plugin.config)
for _, input in ipairs({
  "false",
  '{"split":"diagonal"}',
  '{"files":false}',
  '{"files":{"path":"absolute"}}',
  '{"keymaps":true}',
  '{"keymaps":{"diff":true}}',
  '{"keymaps":{"unknown":"x"}}',
  '{"completion":false}',
  '{"completion":{"mask":"yes"}}',
  '{"completion":{"mask":{}}}',
  '{"diagnostics":{"enabled":"yes"}}',
  '{"diagnostics":{"host":"yes"}}',
  '{"highlight":false}',
  '{"highlight":{"mode":true}}',
  '{"highlight":{"mode":"source_map"}}',
  '{"render":false}',
  '{"render":{"validate":null}}',
  '{"render":{"validate":1}}',
  '{"render":{"validate":"sometimes"}}',
  '{"render":{"validate":"once"}}',
  '{"render":{"validate":"never"}}',
  '{"render":{"validate":"always"}}',
  '{"watch":{"buffer_write_fallback":"always"}}',
  '{"chezmoi_executable":false}',
  '{"chezmoi_config_path":false}',
}) do
  local ok = pcall(plugin.setup, vim.json.decode(input))
  assert(not ok, "invalid configuration was accepted: " .. input)
  assert(package.loaded["vimoi.core.cli"] == nil, "invalid configuration started CLI initialization")
  assert(vim.deep_equal(original, plugin.config), "invalid configuration was published")
end
for _, input in ipairs({
  '{"diff":{"validate":false}}',
  '{"diff":{},"render":{"validate":false}}',
  '{"session":{"validate":false}}',
  '{"session":{},"render":{"validate":false}}',
}) do
  local ok, err = pcall(plugin.setup, vim.json.decode(input))
  assert(not ok and tostring(err):find("moved to render", 1, true), "old config did not explain migration")
  assert(package.loaded["vimoi.core.cli"] == nil, "old config started CLI initialization")
  assert(vim.deep_equal(original, plugin.config), "old config was published")
end
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
plugin.setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  completion = {
    mask = function(key)
      return key == "chezmoi.os"
    end,
  },
})
assert(vim.fn.exists(":VimoiToggle") == 2, "valid setup could not recover after invalid input")
print("setup validation: invalid public settings fail before side effects and valid setup can retry")

---@diagnostic disable: duplicate-set-field -- Setup must not launch processes; failed cache misses stay retryable.
local original_system = vim.system
local calls, fail = 0, true
local source = vim.fn.getcwd() .. "/tests/fixtures/environment/source"
vim.system = function(args)
  calls = calls + 1
  assert(args[1] == "fake" and args[2] == "--config" and args[3] == "/tmp/chezmoi.toml")
  assert(args[4] == "--source" and args[5] == source and args[6] == "target-path" and args[7] == "--")
  local result = { code = 1, stdout = "", stderr = "broken chezmoi config" }
  if not fail then
    local targets = {}
    for _, path in ipairs(vim.list_slice(args, 8)) do
      targets[#targets + 1] = "/tmp/" .. assert(vim.fs.relpath(source, path))
    end
    result = { code = 0, stdout = table.concat(targets, "\n") .. "\n", stderr = "" }
  end
  return {
    wait = function()
      return result
    end,
  }
end
require("vimoi").setup({
  chezmoi_executable = "fake",
  chezmoi_source_dir = source,
  chezmoi_config_path = "/tmp/chezmoi.toml",
})
local cli = require("vimoi.core.cli")
assert(calls == 0 and cli.source_root == source and cli.config_path == "/tmp/chezmoi.toml")
assert(vim.fn.exists(":VimoiDiff") == 2)
local path, err = cli.counterpart_path(source .. "/dot_plain")
assert(path == nil and err and err:find("broken chezmoi config", 1, true) and calls == 1)
fail = false
assert(cli.counterpart_path(source .. "/dot_plain") == "/tmp/dot_plain" and calls == 2)
assert(cli.counterpart_path(source .. "/dot_plain") == "/tmp/dot_plain" and calls == 2)
vim.system = original_system

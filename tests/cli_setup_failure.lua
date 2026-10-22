local original_system = vim.system
local result = { code = 1, stdout = "", stderr = "broken chezmoi config" }
local config_result

---@diagnostic disable-next-line: duplicate-set-field -- Simulate chezmoi setup failure.
vim.system = function(args)
  local command_result = args[2] == "execute-template" and config_result or result
  return {
    wait = function()
      return command_result
    end,
  }
end

local chezmoi = require("vimoi")
local cli = require("vimoi.cli")
local ok, err = pcall(chezmoi.setup, { chezmoi_executable = "fake" })
assert(not ok and err:find("broken chezmoi config", 1, true))
assert(cli.source_root == nil)
assert(vim.fn.exists(":VimoiDiff") == 0, "failed setup must not register commands")

result = { code = 0, stdout = "\n", stderr = "" }
ok, err = pcall(chezmoi.setup, { chezmoi_executable = "fake" })
assert(not ok and err:find("empty path", 1, true))
assert(cli.source_root == nil)
assert(vim.fn.exists(":VimoiDiff") == 0)

result = { code = 0, stdout = "/tmp/vimoi-source\n", stderr = "" }
config_result = { code = 1, stdout = "", stderr = "cannot query config path" }
ok, err = pcall(chezmoi.setup, { chezmoi_executable = "fake" })
assert(not ok and err:find("cannot query config path", 1, true))
assert(cli.source_root == nil)
assert(vim.fn.exists(":VimoiDiff") == 0)

config_result = { code = 0, stdout = "/tmp/chezmoi.toml\n", stderr = "" }
chezmoi.setup({ chezmoi_executable = "fake" })
assert(cli.source_root == "/tmp/vimoi-source")
assert(vim.fn.exists(":VimoiDiff") == 2)

vim.system = original_system

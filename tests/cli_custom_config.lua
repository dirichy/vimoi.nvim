local run_async = dofile("tests/helpers/await.lua")
local cli = require("vimoi.cli")
local working_directory = vim.fn.getcwd()
local test_root = vim.fn.tempname() .. " chezmoi config"
local source_root = test_root .. "/source"
local target_root = test_root .. "/target"
local config_path = test_root .. "/custom settings.toml"
local init_source = source_root .. "/.chezmoi.toml.tmpl"
local source_file = source_root .. "/dot_example.tmpl"
local target_file = target_root .. "/.example"
vim.fn.mkdir(source_root, "p")
vim.fn.writefile({ "# Init template" }, init_source)
vim.fn.writefile({ "value = {{ .value }}" }, source_file)
local config_lines = {
  "sourceDir = " .. vim.json.encode(source_root),
  "destDir = " .. vim.json.encode(target_root),
  "[data]",
  'value = "custom"',
}
vim.fn.writefile(config_lines, config_path)

local original_system = vim.system
---@diagnostic disable-next-line: duplicate-set-field -- Check every real CLI invocation uses the config.
vim.system = function(args, ...)
  assert(args[1] == "chezmoi" and args[2] == "--config" and args[3] == config_path)
  assert(not vim.tbl_contains(args, "{{ .chezmoi.configFile }}"), "explicit config paths must not be queried again")
  return original_system(args, ...)
end

vim.api.nvim_set_current_dir(test_root)
require("vimoi").setup({ chezmoi_config_path = "./custom settings.toml" })
vim.api.nvim_set_current_dir(working_directory)
assert(cli.source_root == source_root)
assert(cli.counterpart_path(init_source) == config_path)
assert(cli.counterpart_path(source_file) == target_file)
assert(run_async(cli.run, { "cat", target_file }) == "value = custom\n")
local rendered, render_error = run_async(cli.execute_template, "{{ .chezmoi.configFile }}:{{ .value }}")
assert(rendered == config_path .. ":custom", render_error)
local async_rendered
run_async(cli.execute_template, "{{ .value }}", {
  callback = function(output, err)
    assert(not err and not vim.in_fast_event())
    async_rendered = output
  end,
})
assert(vim.wait(1000, function()
  return async_rendered ~= nil
end))
assert(async_rendered == "custom")

local loaded_data
cli.data_async(function(data, err)
  assert(data and not err)
  loaded_data = data
end)
assert(vim.wait(1000, function()
  return loaded_data ~= nil
end))
assert(loaded_data.chezmoi.configFile == config_path and loaded_data.value == "custom")

config_lines[4] = 'value = "updated"'
vim.fn.writefile(config_lines, config_path)
vim.api.nvim_exec_autocmds("BufWritePost", { pattern = config_path, modeline = false })
assert(
  vim.wait(2000, function()
    return run_async(cli.data).value == "updated"
  end, 20),
  "writing a custom-named config must invalidate cached data"
)
assert(cli.counterpart_path(config_path) == init_source, "init mappings must survive invalidation")

vim.system = original_system
vim.fn.delete(test_root, "rf")

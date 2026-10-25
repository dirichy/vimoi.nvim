local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local cli = require("vimoi.core.cli")
local navigation = require("vimoi.editor.goto")
local target = vim.fn.tempname()
vim.fn.writefile({ "target" }, target)
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, fixture .. "/source/.chezmoiignore")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { target })
local counterpart_path = cli.counterpart_path
---@diagnostic disable-next-line: duplicate-set-field -- Distinguish lookup errors from unmanaged paths.
cli.counterpart_path = function()
  return nil, "source lookup failed"
end
local paths, err = navigation.resolve(buf, 0, 0)
assert(not paths and err == "source lookup failed", "lookup failure silently fell back to target")
---@diagnostic disable-next-line: duplicate-set-field -- Empty success is the CLI's unmanaged-file result.
cli.counterpart_path = function()
  return ""
end
paths, err = navigation.resolve(buf, 0, 0)
assert(paths and paths[1] == target and not err)
cli.counterpart_path = counterpart_path

vim.api.nvim_buf_set_name(buf, vim.fn.tempname())
local data = cli.data
---@diagnostic disable-next-line: duplicate-set-field -- Native paths must not query chezmoi data.
cli.data = function()
  error("unexpected data query")
end
for _, path in ipairs({ target, vim.uri_from_fname(target) }) do
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { path })
  paths, err = navigation.resolve(buf, 0, 0)
  assert(paths and paths[1] == target and not err)
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "ordinary-relative-path" })
assert(navigation.resolve(buf, 0, 0) == nil)
cli.data = data
vim.fn.delete(target)

-- Destination-directory query errors must be reported without falling back to native gf.
vim.api.nvim_buf_set_name(buf, fixture .. "/source/.chezmoiignore")
local run = cli.run
---@diagnostic disable-next-line: duplicate-set-field -- Exercise the dedicated directory query.
cli.run = function(args, opts)
  if args[1] == "target-path" and #args == 1 then
    return nil, "destination lookup failed"
  end
  return run(args, opts)
end
local _, destination_error = navigation.resolve(buf, 0, 0)
assert(destination_error == "destination lookup failed")
---@diagnostic disable-next-line: duplicate-set-field -- Empty output must not resolve against cwd.
cli.run = function()
  return "\n"
end
_, destination_error = navigation.resolve(buf, 0, 0)
assert(destination_error == "chezmoi target-path returned an empty path")
cli.run = run

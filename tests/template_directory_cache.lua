local cli = require("vimoi.core.cli")
local root = vim.fn.getcwd() .. "/tests/fixtures/environment/source"
local find, calls = vim.fs.find, 0
---@diagnostic disable-next-line: duplicate-set-field -- Count real directory traversals.
vim.fs.find = function(...)
  calls = calls + 1
  return find(...)
end
local first = cli.template_directories(root)
assert(#first > 0 and calls == 1)
for _ = 1, 100 do
  assert(cli.template_directories(root .. "/.") == first)
end
assert(calls == 1, "repeated completion/navigation must share discovery")
for _, scope in ipairs({ "paths", "templates", "data", "all" }) do
  local before = calls
  cli.invalidate(scope)
  local directories = cli.template_directories(root)
  assert(vim.deep_equal(directories, first) and directories ~= first)
  assert(calls == before + 1)
end
vim.fs.find = find

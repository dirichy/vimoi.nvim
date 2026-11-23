---@diagnostic disable: duplicate-set-field -- Observe real CLI calls and inject isolated failures.
local cli = require("vimoi.core.cli")
local root = vim.fn.tempname() .. " path cache"
local source, destination = root .. "/source", root .. "/target"
local config = root .. "/chezmoi.toml"
vim.fn.mkdir(source .. "/.git", "p")
vim.fn.mkdir(source .. "/.chezmoitemplates", "p")
vim.fn.writefile({ "metadata" }, source .. "/.git/config")
vim.fn.writefile({ "shared template" }, source .. "/.chezmoitemplates/shared")
vim.fn.writefile({ "alpha" }, source .. "/dot_alpha")
vim.fn.writefile({ "untouched" }, source .. "/untouched")
vim.fn.writefile({ ".alpha" }, source .. "/.chezmoiignore")
vim.fn.writefile({
  '["unrelated"]',
  'type = "archive"',
  'url = "file://' .. root .. '/missing.tar.gz"',
}, source .. "/.chezmoiexternal.toml")
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(source),
  "destDir = " .. vim.json.encode(destination),
}, config)

local original_system = vim.system
local queries, batches = 0, 0
vim.system = function(argv, ...)
  local command = argv[4] -- chezmoi --config <path> <command>
  if command == "source-path" then
    assert(#argv == 4, "path lookup must not load source state")
  elseif command == "target-path" then
    assert(argv[5] == "--")
    queries = queries + 1
    batches = batches + (#argv > 6 and 1 or 0)
    for index = 6, #argv do
      local relative = assert(vim.fs.relpath(source, argv[index]))
      assert(relative:sub(1, 1) ~= "." and not relative:find("/%."), "metadata entered the path index")
    end
  end
  return original_system(argv, ...)
end
cli.setup("chezmoi", config)
assert(queries == 0, "setup must leave the ordinary path cache empty")

-- A forward miss fills the whole index, including files not requested yet.
assert(cli.counterpart_path(source .. "/dot_alpha") == destination .. "/.alpha")
assert(queries == 1 and batches == 1)
assert(cli.counterpart_path(source .. "/untouched") == destination .. "/untouched" and queries == 1)
assert(cli.counterpart_path(destination .. "/untouched") == source .. "/untouched" and queries == 1)
assert(cli.counterpart_path(destination .. "/.alpha") == source .. "/dot_alpha")
assert(queries == 1, "reverse lookup did not reuse the forward result")
assert(cli.counterpart_path(source .. "/.chezmoiignore") == "")
assert(cli.counterpart_path(source .. "/.chezmoitemplates/shared") == "")
assert(queries == 1)

-- Newly created source files are found without a watcher or explicit invalidation.
vim.fn.mkdir(source .. "/private_dot_config", "p")
local nested = source .. "/private_dot_config/notes file.txt.tmpl"
local nested_target = destination .. "/.config/notes file.txt"
vim.fn.writefile({ "notes" }, nested)
assert(cli.counterpart_path(nested_target) == nested)
assert(queries == 2 and batches == 2)
assert(cli.counterpart_path(nested) == nested_target and queries == 2)
vim.fn.writefile({ "gamma" }, source .. "/dot_gamma")
assert(cli.counterpart_path(source .. "/dot_gamma") == destination .. "/.gamma")
assert(queries == 3 and batches == 3)
assert(cli.counterpart_path(destination .. "/.gamma") == source .. "/dot_gamma" and queries == 3)

-- A missing cached source causes a rebuild, which also removes its old target.
assert(vim.uv.fs_rename(source .. "/dot_alpha", source .. "/dot_delta"))
assert(cli.counterpart_path(destination .. "/.alpha") == "")
assert(queries == 4 and batches == 4)
assert(cli.counterpart_path(destination .. "/.delta") == source .. "/dot_delta" and queries == 4)
assert(vim.uv.fs_unlink(nested))
assert(cli.counterpart_path(nested_target) == "" and queries == 5)
assert(cli.counterpart_path(source .. "/dot_alpha") == "" and queries == 5)

-- Absence is not cached: every reverse miss gets exactly one fresh enumeration.
assert(cli.counterpart_path(destination .. "/absent") == "" and queries == 6)
assert(cli.counterpart_path(destination .. "/absent") == "" and queries == 7)
vim.fn.writefile({ "new" }, source .. "/absent")
assert(cli.counterpart_path(destination .. "/absent") == source .. "/absent" and queries == 8)

-- target-path's line output must preserve leading/trailing spaces in filenames.
local spaced = source .. "/ notes .tmpl"
vim.fn.writefile({ "space" }, spaced)
assert(cli.counterpart_path(spaced) == destination .. "/ notes ")
assert(cli.counterpart_path(destination .. "/ notes ") == spaced)

-- Failed or malformed rebuilds must leave unrelated successful mappings usable.
local original_run = cli.run
cli.run = function()
  return nil, "forced query failure"
end
local value, err = cli.counterpart_path(destination .. "/missing")
assert(value == nil and err == "forced query failure")
assert(cli.counterpart_path(destination .. "/.gamma") == source .. "/dot_gamma")
cli.run = function()
  return destination .. "/wrong\n"
end
value, err = cli.counterpart_path(destination .. "/missing")
assert(value == nil and err and err:find("unexpected number", 1, true))
assert(cli.counterpart_path(source .. "/dot_gamma") == destination .. "/.gamma")
cli.run = original_run

-- Never silently choose one of two local sources for a target.
vim.fn.writefile({ "duplicate" }, source .. "/dot_gamma.tmpl")
value, err = cli.counterpart_path(source .. "/dot_gamma.tmpl")
assert(value == nil and err and err:find("multiple source files", 1, true))
assert(cli.counterpart_path(destination .. "/.gamma") == source .. "/dot_gamma")
assert(vim.uv.fs_unlink(source .. "/dot_gamma.tmpl"))
cli.invalidate("paths")
assert(cli.counterpart_path(destination .. "/.gamma") == source .. "/dot_gamma")
assert(not vim.uv.fs_stat(destination), "path discovery must not create destination files")

-- Empty source trees need no CLI query and must drop stale reverse entries.
for _, name in ipairs({ "dot_delta", "dot_gamma", "untouched", "absent", " notes .tmpl" }) do
  assert(vim.uv.fs_unlink(source .. "/" .. name))
end
local before_empty = queries
assert(cli.counterpart_path(destination .. "/.gamma") == "")
assert(queries == before_empty, "an empty index must not invoke target-path without files")

vim.system = original_system
vim.fn.delete(root, "rf")
print(
  "path cache: lazy queries, batches, metadata, externals, creation, rename, deletion, misses, errors and conflicts verified"
)

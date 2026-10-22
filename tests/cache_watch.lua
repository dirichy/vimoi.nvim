local run_async = dofile("tests/helpers/await.lua")
local cli = require("vimoi.cli")
local api = require("vimoi.api")
local test_root = vim.fn.tempname() .. " chezmoi watch"
local source_root = test_root .. "/source"
local data_dir = source_root .. "/dot_config/.chezmoidata"
local config_path = test_root .. "/config/custom.toml"
local template_dir = source_root .. "/.chezmoitemplates/nested"
local template_file = template_dir .. "/value"
local managed_source = source_root .. "/dot_watch_target"
vim.fn.mkdir(data_dir, "p")
vim.fn.mkdir(template_dir, "p")
vim.fn.mkdir(vim.fs.dirname(config_path), "p")
local config = {
  "sourceDir = " .. vim.json.encode(source_root),
  "destDir = " .. vim.json.encode(test_root .. "/target"),
  "[data]",
  'config_value = "before"',
}
vim.fn.writefile(config, config_path)
vim.fn.writefile({ "watch_value = 1" }, data_dir .. "/settings.toml")
vim.fn.writefile({ "included one" }, template_file)
vim.fn.writefile({ "managed" }, managed_source)
-- Force buffer handling too so synthetic BufWritePost events test rule routing.
require("vimoi").setup({ chezmoi_config_path = config_path, watch = { buffer_write_fallback = true } })
assert(run_async(cli.data).watch_value == 1)

local function await_data(key, value)
  assert(
    vim.wait(2000, function()
      local data, err = run_async(cli.data)
      assert(data, err)
      return data[key] == value
    end, 20),
    "cache was not refreshed for " .. key
  )
end

-- External writes, creation and deletion within an existing nested data directory.
vim.fn.writefile({ "watch_value = 2" }, data_dir .. "/settings.toml")
await_data("watch_value", 2)
vim.fn.writefile({ "new_value = 42" }, data_dir .. "/extra.toml")
await_data("new_value", 42)
assert(vim.uv.fs_unlink(data_dir .. "/extra.toml"))
await_data("new_value", nil)

-- Atomic saves replace the file, so watching just its original inode is insufficient.
config[4] = 'config_value = "replaced"'
vim.fn.writefile(config, config_path .. ".new")
assert(vim.uv.fs_rename(config_path .. ".new", config_path))
await_data("config_value", "replaced")
config[4] = 'config_value = "after replacement"'
vim.fn.writefile(config, config_path)
await_data("config_value", "after replacement")

-- Manual invalidation also discovers data in previously unobserved directories.
local new_dir = source_root .. "/new/nested"
vim.fn.mkdir(new_dir, "p")
vim.fn.writefile({ "later_value = 1" }, new_dir .. "/.chezmoidata.toml")
api.invalidate_cache()
assert(run_async(cli.data).later_value == 1)
vim.fn.writefile({ "later_value = 2" }, new_dir .. "/.chezmoidata.toml")
await_data("later_value", 2)

-- Include edits invalidate both CLI results and a sentinel's unchanged-text
-- fast path, without dropping unrelated data. Watch nested template folders.
local source_map = require("vimoi.gotmpl.source_map")
local source = '{{ includeTemplate "nested/value" . }}'
vim.wait(80, function()
  return false
end, 10)
local cached_data = run_async(cli.data)
local trace = assert(run_async(source_map.trace, source))
assert(trace.output == "included one\n")
local function await_template(expected)
  assert(
    vim.wait(2000, function()
      local updated = run_async(source_map.trace, source)
      return updated ~= nil and updated.output == expected
    end, 20),
    "included template output was not refreshed"
  )
  assert(run_async(cli.data) == cached_data, "include edits must not discard data")
end
vim.fn.writefile({ "included two" }, template_file)
await_template("included two\n")
assert(source_map.rebuild(trace, source) == nil, "template-only invalidation must expire derived traces")

-- Atomic replacement, removal, and recreation must keep the directory watch.
vim.fn.writefile({ "replacement" }, template_file .. ".new")
assert(vim.uv.fs_rename(template_file .. ".new", template_file))
await_template("replacement\n")
local generation = cli.context_generation
assert(vim.uv.fs_unlink(template_file))
assert(vim.wait(2000, function()
  return cli.context_generation > generation
end, 20))
assert(run_async(source_map.trace, source) == nil, "deleted includes must not return cached output")
vim.fn.writefile({ "recreated" }, template_file)
await_template("recreated\n")

-- Explicit partial invalidation also rescans newly introduced directories.
local later_templates = source_root .. "/.chezmoitemplates/later/deep"
vim.fn.mkdir(later_templates, "p")
vim.fn.writefile({ "later one" }, later_templates .. "/value")
api.invalidate_cache("templates")
source = '{{ includeTemplate "later/deep/value" . }}'
await_template("later one\n")
vim.fn.writefile({ "later two" }, later_templates .. "/value")
await_template("later two\n")

-- Mixed bursts must not lose a config event behind a template-only event.
vim.fn.writefile({ "later three" }, later_templates .. "/value")
config[4] = 'config_value = "mixed burst"'
vim.fn.writefile(config, config_path)
await_data("config_value", "mixed burst")

-- Buffer saves have the same partial behavior, even without an fs event.
cached_data = run_async(cli.data)
generation = cli.context_generation
vim.api.nvim_exec_autocmds("BufWritePost", { pattern = template_file, modeline = false })
assert(cli.context_generation == generation + 1 and run_async(cli.data) == cached_data)
generation = cli.context_generation
vim.api.nvim_exec_autocmds(
  "BufWritePost",
  { pattern = test_root .. "/outside/.chezmoitemplates/value", modeline = false }
)
assert(cli.context_generation == generation)

-- Rule order keeps special-looking names inside templates template-only.
vim.api.nvim_exec_autocmds("BufWritePost", {
  pattern = template_dir .. "/.chezmoidata.toml",
  modeline = false,
})
assert(cli.context_generation == generation + 1 and run_async(cli.data) == cached_data)
generation = cli.context_generation
for _, path in ipairs({
  source_root .. "/.chezmoitemplates-backup/value",
  source_root .. "/.chezmoidata-backup/value",
  source_root .. "/.chezmoi-backup",
  source_root .. "/.vimoi-test",
  source_root .. "/.chezmoiignore.backup",
  source_root .. "/.chezmoiexternal.toml",
  source_root .. "/.chezmoi.toml.tmpl",
  source_root .. "/ordinary.txt",
}) do
  vim.api.nvim_exec_autocmds("BufWritePost", { pattern = path, modeline = false })
  assert(cli.context_generation == generation, "rule crossed a directory/name boundary: " .. path)
end
-- Exact ignore rules clear cached source/target mappings, not data or renders.
local ignore_path = source_root .. "/.chezmoiignore"
assert(cli.counterpart_path(managed_source) == test_root .. "/target/.watch_target")
vim.fn.writefile({ ".watch_target" }, ignore_path)
assert(
  vim.wait(2000, function()
    return cli.counterpart_path(managed_source) == nil
  end, 20),
  "ignore changes must expire a previously cached path"
)
assert(cli.context_generation == generation and run_async(cli.data) == cached_data)

vim.fn.writefile({}, ignore_path)
vim.api.nvim_exec_autocmds("BufWritePost", { pattern = ignore_path, modeline = false })
assert(cli.counterpart_path(managed_source) == test_root .. "/target/.watch_target")
assert(cli.context_generation == generation and run_async(cli.data) == cached_data)

vim.fn.delete(test_root, "rf")

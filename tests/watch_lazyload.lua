---@diagnostic disable: duplicate-set-field -- Observe real watcher activation and ensure directory-only cache use is covered.
local root = vim.fn.tempname() .. " lazy watch"
local source = root .. "/source"
local config = root .. "/config.toml"
vim.fn.mkdir(source, "p")
vim.fn.writefile({ "# unused by this directory-only lookup" }, config)
local watch = require("vimoi.core.watch")
local refresh, scans = watch.refresh, 0
watch.refresh = function()
  scans = scans + 1
  return refresh()
end
local dir, traversals = vim.fs.dir, 0
vim.fs.dir = function(path, ...)
  if path == source then
    traversals = traversals + 1
  end
  return dir(path, ...)
end
local new_fs_event, handles = vim.uv.new_fs_event, 0
vim.uv.new_fs_event = function(...)
  handles = handles + 1
  return new_fs_event(...)
end
local system = vim.system
vim.system = function()
  error("shared-template discovery must not run chezmoi")
end
require("vimoi").setup({ chezmoi_source_dir = source, chezmoi_config_path = config })
assert(scans == 0 and traversals == 0 and handles == 0, "setup must not traverse the source or allocate watchers")
local template_dir = source .. "/.chezmoitemplates/nested"
vim.fn.mkdir(template_dir, "p")
local part = template_dir .. "/part"
vim.fn.writefile({ "before" }, part)
local cli = require("vimoi.core.cli")
local directories = cli.template_directories(source)
assert(#directories == 1 and scans == 1 and handles >= 4, "first discovery must watch directories created after setup")
local active_handles = handles
assert(cli.template_directories(source) == directories and scans == 1 and handles == active_handles)
local generation = cli.context_generation
vim.fn.writefile({ "after" }, part)
assert(
  vim.wait(2000, function()
    return cli.context_generation > generation
  end),
  "first-use watchers missed an external edit"
)
assert(
  cli.template_directories(source) ~= directories and scans == 1,
  "invalidation must refresh cached discovery without rescanning watchers"
)
require("vimoi.api").invalidate_cache()
assert(scans == 2 and handles > active_handles, "manual invalidation must still rescan watchers")
cli.template_directories(source)
assert(scans == 2, "explicit refresh must count as activation")
watch.refresh = refresh
vim.fs.dir = dir
vim.uv.new_fs_event = new_fs_event
vim.system = system
vim.fn.delete(root, "rf")

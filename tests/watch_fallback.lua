---@diagnostic disable: duplicate-set-field -- Fault injection for watcher allocation/start/runtime failures.
local cli = require("vimoi.cli")
local original_invalidate = cli.invalidate
local original_new_fs_event = vim.uv.new_fs_event
local test_root = vim.fn.tempname() .. " watcher fallback"
local source_root = test_root .. "/source"
local template_dir = source_root .. "/.chezmoitemplates"
local template_file = template_dir .. "/part"
local config_path = test_root .. "/config.toml"
vim.fn.mkdir(template_dir, "p")
vim.fn.writefile({ "part" }, template_file)
vim.fn.writefile({ "# config" }, config_path)

-- A real start failure is observable from libuv's return value.
local missing = assert(original_new_fs_event())
local started, start_error = missing:start(test_root .. "/missing", {}, function() end)
assert(not started and start_error and start_error:find("ENOENT", 1, true))
missing:close()
print("real watcher start failure: " .. start_error)

local invalidations = {}
cli.invalidate = function(scope)
  invalidations[#invalidations + 1] = scope
  return original_invalidate(scope)
end

local function setup_mode(mode, failure)
  local state = { failure = failure, handles = {} }
  invalidations = {}
  vim.uv.new_fs_event = function()
    if state.failure == "allocate" then
      return nil, "ENOMEM"
    end
    local handle = {
      start = function(self, directory, _, callback)
        self.directory, self.callback = directory, callback
        if state.failure == "start" or directory == state.failed_directory then
          return nil, "ENOSYS"
        end
        return 0
      end,
      stop = function(self)
        self.stopped = true
      end,
      close = function(self)
        self.closed = true
      end,
    }
    state.handles[#state.handles + 1] = handle
    return handle
  end
  package.loaded["vimoi.watch"] = nil
  local watch = require("vimoi.watch")
  watch.setup({ source_root = source_root, config_path = config_path, buffer_write_fallback = mode })
  return state, watch
end

local function save(path)
  vim.api.nvim_exec_autocmds("BufWritePost", { pattern = path, modeline = false })
end

-- Auto: successful direct-parent watches suppress buffer fallback.
local state, watch = setup_mode("auto")
save(template_file)
save(config_path)
assert(#invalidations == 0)
save(template_dir .. "/new/subdir/part")
assert(
  #invalidations == 1 and invalidations[1] == "templates",
  "watching an ancestor does not cover a new subdirectory"
)

-- Runtime failure makes only that directory fall back. Refresh can restore it.
invalidations = {}
for _, handle in ipairs(state.handles) do
  if handle.directory == template_dir then
    handle.callback("EIO")
    assert(handle.stopped and handle.closed)
  end
end
save(template_file)
save(config_path)
assert(#invalidations == 1 and invalidations[1] == "templates")
watch.refresh()
save(template_file)
assert(#invalidations == 1, "refresh should restore automatic watcher coverage")

-- Allocation/start failures are detectable, with no manual configuration.
for _, failure in ipairs({ "allocate", "start" }) do
  state, watch = setup_mode("auto", failure)
  save(template_file)
  save(config_path)
  assert(#invalidations == 2 and invalidations[1] == "templates" and invalidations[2] == "all")
  if failure == "start" then
    for _, handle in ipairs(state.handles) do
      assert(handle.closed)
    end
  end
  state.failure = nil
  watch.refresh()
  save(template_file)
  assert(#invalidations == 2)
end

-- Failure in one directory must not enable fallback in healthy directories.
state, watch = setup_mode("auto")
state.failed_directory = template_dir
watch.refresh()
save(template_file)
save(config_path)
assert(#invalidations == 1 and invalidations[1] == "templates")

-- A successful but silent backend cannot be detected from start(). Force the
-- fallback explicitly; false disables it even when no watch could be allocated.
setup_mode(true)
save(template_file)
assert(#invalidations == 1 and invalidations[1] == "templates")
setup_mode(false, "allocate")
save(template_file)
assert(#invalidations == 0)
assert(#vim.api.nvim_get_autocmds({ group = "vimoi-cli-cache", event = "BufWritePost" }) == 0)

vim.uv.new_fs_event = original_new_fs_event
cli.invalidate = original_invalidate
vim.fn.delete(test_root, "rf")
print(
  "watch fallback: allocation/start/runtime failures, partial coverage, refresh, and forced/disabled modes verified"
)

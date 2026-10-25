-- Deleting a shared rendered buffer must retire its map and allow recovery.
vim.opt.swapfile = false
local lint_jobs = {}
package.loaded.lint = {
  linters_by_ft = { lua = { "test" } },
  linters = { test = { stdin = true } },
  lint = function()
    local job = { cancelled = false }
    function job:cancel()
      self.cancelled = true
    end
    lint_jobs[#lint_jobs + 1] = job
    return job
  end,
}
require("vimoi").setup()
local api, util = vim.api, require("vimoi.core.util")
local sessions, views = require("vimoi.render"), require("vimoi.compare")
local actions = require("vimoi.api")
local cli = require("vimoi.core.cli")
local execute, renders = cli.execute_template, 0
---@diagnostic disable-next-line: duplicate-set-field -- Recovery should reuse the executed skeleton.
cli.execute_template = function(...)
  renders = renders + 1
  return execute(...)
end
local function await(predicate)
  assert(vim.wait(5000, predicate, 5), "rendered buffer lifecycle did not settle")
end
local source = api.nvim_create_buf(true, false)
api.nvim_set_current_buf(source)
api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua.tmpl")
util.set_buffer_text(source, 'local value = {{ "1" }}\n')
actions.preview()
local preview = assert(views.by_window[api.nvim_get_current_win()])
local state = sessions.get(source)
await(function()
  return state.map and not preview.loading
end)
local output, map = state.buf, assert(state.map)
local pending_lint = assert(lint_jobs[#lint_jobs])
api.nvim_set_current_win(preview.target_win)
vim.cmd("bdelete")
assert(preview.closed, "deleting the preview did not release its view")
assert(pending_lint.cancelled, "output deletion left its diagnostic job running")
assert(not sessions.is_current(source, map), "deleted output still exposes a current map")
await(function()
  return api.nvim_buf_is_loaded(state.buf) and state.map and sessions.is_current(source, state.map)
end)
assert(state.buf ~= output and state.map ~= map)
assert(util.buffer_text(state.buf) == "local value = 1\n")
local initial_renders = renders
assert(sessions.get(source) == state and state.initialized)

-- A real target view survives deletion of the hidden shared output.
api.nvim_set_current_win(preview.source_win)
local target = api.nvim_create_buf(true, false)
util.set_buffer_text(target, "local value = 2\n")
actions.diff_buffers(source, target, { filetype = "lua" })
local diff = assert(views.by_window[api.nvim_get_current_win()])
await(function()
  return not diff.loading
end)
for _, command in ipairs({ "bdelete", "bwipeout", "bunload" }) do
  output, map = state.buf, assert(state.map)
  vim.cmd(command .. " " .. output)
  assert(not sessions.is_current(source, map))
  await(function()
    return state.map and sessions.is_current(source, state.map) and diff.map == state.map
  end)
  assert(state.buf ~= output and views.is_valid(diff))
  assert(sessions.get(source) == state and state.initialized)
  assert(util.buffer_text(state.buf) == "local value = 1\n")
  assert(util.buffer_text(target) == "local value = 2\n")
end
assert(renders == initial_renders, "output recovery executed an unchanged skeleton again")

-- The recovered output still responds to real source changes.
util.set_buffer_text(source, 'local value = {{ "3" }}\n')
await(function()
  return state.map and state.map.tick == api.nvim_buf_get_changedtick(source) and diff.map == state.map
end)
assert(util.buffer_text(state.buf) == "local value = 3\n")

output = state.buf
api.nvim_buf_delete(source, { force = true })
assert(not api.nvim_buf_is_valid(output), "source teardown leaked the recreated output")
cli.execute_template = execute
print("output deletion: native delete/unload/wipe, automatic recovery, shared diff and skeleton reuse verified")

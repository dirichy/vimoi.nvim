local render_trace = dofile("tests/helpers/trace.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local renderer = require("vimoi.gotmpl.source_map")
local requests = {}
package.loaded["vimoi.gotmpl.source_map"] = setmetatable({
  trace_async = function(source, opts, callback)
    requests[#requests + 1] = { source = source, opts = opts, callback = callback }
  end,
}, { __index = renderer })
local api = require("vimoi.api")
local sessions = require("vimoi.gotmpl.session")
local util = require("vimoi.util")
local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
vim.fn.writefile({ 'value={{ "A" }}' }, source)
vim.fn.writefile({ "value=B" }, target)
local function current()
  return assert(sessions.by_window[vim.api.nvim_get_current_win()])
end
local function request()
  local before = #requests
  assert(vim.wait(1000, function()
    return #requests > before
  end))
  return requests[#requests]
end
local function deliver(job)
  job.callback(render_trace(renderer, job.source, job.opts))
end

api.diff_files(source, target)
local first = current()
local original_request = request()
vim.cmd("tabnew")
vim.api.nvim_win_set_buf(0, first.source_buf)
api.preview()
local preview = current()
local preview_request = request()
assert(first.loading and preview.loading and sessions.is_valid(first))
deliver(preview_request)
assert(first.loading and not preview.loading, "one view cleared the other's loading state")
sessions.close(preview)
assert(first.loading and vim.b[first.source_buf].snacks_scroll == false)
deliver(original_request)
assert(not first.loading and first.trace and not first.closed)

-- Reopening while initial jobs are pending keeps the pair and retires only
-- that window's previous operation. Stale callbacks cannot clear the new state.
vim.api.nvim_set_current_win(first.source_win)
local source_win, target_win = first.source_win, first.target_win
local stale = {}
for index = 1, 6 do
  vim.api.nvim_set_current_win(index % 2 == 0 and source_win or target_win)
  api.diff_files(source, target)
  local session = current()
  stale[#stale + 1] = { session = session, request = request() }
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
  assert(session.source_win == source_win and session.target_win == target_win)
end
local latest = table.remove(stale)
for _, item in ipairs(stale) do
  assert(item.session.closed)
  deliver(item.request)
  assert(latest.session.loading and sessions.by_window[source_win] == latest.session)
end
deliver(latest.request)
assert(not latest.session.loading and sessions.is_valid(latest.session))

-- Closing a different pair of windows displaying the same source leaves this
-- view bound and its mappings active; shared source edits still refresh it.
vim.cmd("tabnew")
vim.api.nvim_win_set_buf(0, first.source_buf)
api.preview()
preview = current()
preview_request = request()
vim.api.nvim_set_current_win(source_win)
vim.api.nvim_win_close(preview.source_win, true)
assert(preview.closed and sessions.is_valid(latest.session))
assert(vim.fn.maparg("do", "n", false, true).callback == api.put_hunk)
deliver(preview_request)
assert(sessions.by_window[source_win] == latest.session)
assert(util.buffer_text(latest.session.target_buf) == "value=B\n")
sessions.close(latest.session)
vim.fn.delete(source)
vim.fn.delete(target)

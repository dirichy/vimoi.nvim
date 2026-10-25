local render_trace = dofile("tests/helpers/trace.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})
local renderer = require("vimoi.render.source_map")
local requests = {}
package.loaded["vimoi.render.source_map"] = setmetatable({
  trace_async = function(source, opts, callback)
    requests[#requests + 1] = { source = source, opts = opts, callback = callback }
  end,
}, { __index = renderer })
local api = require("vimoi.api")
local sessions = require("vimoi.compare")
local util = require("vimoi.core.util")
local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
vim.fn.writefile({ 'value={{ "A" }}' }, source)
vim.fn.writefile({ "value=B" }, target)
local function current()
  return assert(sessions.by_window[vim.api.nvim_get_current_win()])
end
local function request(before)
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
local original_request = request(0)
vim.cmd("tabnew")
vim.api.nvim_win_set_buf(0, first.source_buf)
api.preview()
local preview = current()
assert(first.loading and preview.loading and sessions.is_valid(first))
assert(first.session == preview.session, "views created separate source sessions")
assert(first.session.views[first] and first.session.views[preview])
assert(vim.tbl_count(first.session.subscribers) == 2, "each view should have exactly one subscription")
assert(#requests == 1, "opening another view duplicated the source render")
deliver(original_request)
assert(
  vim.wait(1000, function()
    return not first.loading and not preview.loading
  end),
  "shared rendering did not complete both views"
)
local output = preview.target_buf
assert(output == require("vimoi.render").get(first.source_buf).buf)
sessions.close(preview)
assert(sessions.is_valid(first) and vim.b[first.source_buf].snacks_scroll == false)

-- Reopening pending views shares one current source request. Old view callbacks
-- must not clear or rebind the newest session.
util.set_buffer_text(first.source_buf, 'value={{ "C" }}\n')
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = first.source_buf })
local pending = request(1)
vim.api.nvim_set_current_win(first.source_win)
local source_win, target_win = first.source_win, first.target_win
local stale = {}
for index = 1, 6 do
  vim.api.nvim_set_current_win(index % 2 == 0 and source_win or target_win)
  api.diff_files(source, target)
  stale[#stale + 1] = current()
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2)
  assert(current().source_win == source_win and current().target_win == target_win)
end
local latest = table.remove(stale)
for _, session in ipairs(stale) do
  assert(session.closed)
end
assert(#requests == 2, "reopening restarted the shared request")
deliver(pending)
assert(vim.wait(1000, function()
  return not latest.loading
end))
assert(sessions.is_valid(latest))
assert(assert(require("vimoi.render").snapshot(latest.source_buf)).output == "value=C\n")

-- A second preview borrows the existing output. Closing its source window
-- releases only that view; the active diff and its mappings remain valid.
vim.cmd("tabnew")
vim.api.nvim_win_set_buf(0, first.source_buf)
api.preview()
preview = current()
assert(preview.target_buf == output, "preview replaced the shared output buffer")
assert(vim.wait(1000, function()
  return not preview.loading
end))
vim.api.nvim_set_current_win(source_win)
vim.api.nvim_win_close(preview.source_win, true)
assert(preview.closed and sessions.is_valid(latest))
assert(vim.fn.maparg("do", "n", false, true).callback == api.get_hunk)
assert(util.buffer_text(latest.target_buf) == "value=B\n")
vim.api.nvim_buf_delete(first.source_buf, { force = true })
assert(latest.closed and next(latest.session.views) == nil, "source unload retained window views")
assert(vim.api.nvim_win_is_valid(latest.target_win), "source cleanup closed the target window")
assert(vim.api.nvim_win_get_buf(latest.target_win) == latest.target_buf and not vim.wo[latest.target_win].diff)
assert(not vim.api.nvim_buf_is_valid(output), "unloading source retained its output")
vim.fn.delete(source)
vim.fn.delete(target)

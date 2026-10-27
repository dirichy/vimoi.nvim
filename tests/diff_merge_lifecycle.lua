local waiting = dofile("tests/helpers/waiting.lua")
local render_trace = dofile("tests/helpers/trace.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
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
local requests, hold = {}, false
package.loaded["vimoi.render.source_map"] = setmetatable({
  trace = function()
    error("merge must not render synchronously")
  end,
  trace_async = function(source, opts, callback)
    if hold then
      requests[#requests + 1] = { source = source, opts = opts, callback = callback }
    else
      renderer.trace_async(source, opts, callback)
    end
  end,
}, { __index = renderer })
local api = require("vimoi.api")
local util = require("vimoi.core.util")
local sessions = require("vimoi.compare")
local cli = require("vimoi.core.cli")
local function open(source_text, target_text)
  for _, session in pairs(sessions.by_window) do
    sessions.close(session)
  end
  hold = false
  vim.cmd("tabnew")
  local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
  vim.fn.writefile(util.text_lines(source_text), source)
  vim.fn.writefile(util.text_lines(target_text), target)
  api.diff_files(source, target)
  dofile("tests/helpers/diff.lua")()
  return view_for_buffer(vim.fn.bufnr(source))
end
local function deliver(request)
  local trace, err = render_trace(renderer, request.source, request.opts)
  request.callback(trace, err)
end

-- A deferred picker cannot write into an edited, renamed, closed, or replaced pair.
local select = vim.ui.select
for _, change in ipairs({ "source", "target", "rename", "close", "reopen", "context" }) do
  local original = "before\n{{- if true }}\n{{- end }}\nafter\n"
  local session = open(original, "before\nnew\nafter\n")
  vim.api.nvim_set_current_win(session.target_win)
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local finish, item
  ---@diagnostic disable-next-line: duplicate-set-field -- Hold the actual UI continuation.
  vim.ui.select = function(items, _, callback)
    item, finish = items[2], callback
  end
  api.put_hunk()
  vim.ui.select = select
  assert(finish, "expected ambiguous placement")
  if change == "source" then
    util.set_buffer_text(session.source_buf, original .. "manual\n")
  elseif change == "target" then
    util.set_buffer_text(session.target_buf, "manual\n")
  elseif change == "rename" then
    vim.api.nvim_buf_set_name(session.source_buf, vim.api.nvim_buf_get_name(session.source_buf) .. ".renamed")
  elseif change == "context" then
    cli.invalidate("templates")
  elseif change == "close" then
    sessions.close(session)
  else
    sessions.close(session)
    vim.api.nvim_set_current_win(session.source_win)
    api.diff_files(vim.api.nvim_buf_get_name(session.source_buf), vim.api.nvim_buf_get_name(session.target_buf))
    dofile("tests/helpers/diff.lua")()
  end
  local expected = util.buffer_text(session.source_buf)
  finish(item)
  assert(util.buffer_text(session.source_buf) == expected, change .. " allowed a stale choice to write")
end

-- A stale mapping renders asynchronously and remains cancellable before planning.
for _, change in ipairs({ "none", "cancel", "source", "target", "context", "close", "failure" }) do
  local session = open('{{ "before" }}\n', "before\n{{ literal }}\n")
  util.set_buffer_text(session.source_buf, '{{ print "before" }}\n')
  hold = true
  local before = #requests
  api.readd()
  assert(waiting())
  assert(vim.wait(2000, function()
    return #requests == before + 1
  end))
  local request = requests[#requests]
  local win = vim.api.nvim_get_current_win()
  assert(not vim.bo.modifiable and vim.api.nvim_win_get_config(win).relative == "editor")
  if change == "cancel" then
    vim.fn.maparg("q", "n", false, true).callback()
  elseif change == "source" then
    util.set_buffer_text(session.source_buf, "manual\n")
  elseif change == "target" then
    util.set_buffer_text(session.target_buf, "manual\n")
  elseif change == "context" then
    cli.invalidate("templates")
  elseif change == "close" then
    sessions.close(session)
  end
  local expected = util.buffer_text(session.source_buf)
  if change == "failure" then
    request.callback(nil, "mapping render failed")
  else
    deliver(request)
  end
  if change == "none" then
    assert(assert(render_trace(renderer, util.buffer_text(session.source_buf))).output == "before\n{{ literal }}\n")
  else
    assert(util.buffer_text(session.source_buf) == expected, change .. " allowed a stale write")
  end
  if waiting() then
    local before_retry = #requests
    assert(vim.wait(1000, function()
      return not waiting() or #requests > before_retry
    end))
    if waiting() then
      deliver(requests[#requests])
    end
  end
  assert(not waiting(), change .. " left a pending merge")
  assert(vim.wait(1000, function()
    return not vim.api.nvim_win_is_valid(win)
  end))
end

-- Structural source edits require a fresh mapping before planning; cancellation
-- must also cover that stage, rather than blocking inside a synchronous refresh.
for _, cancel in ipairs({ false, true }) do
  local session = open('value={{ "A" }}\n', "value=B\n")
  util.set_buffer_text(session.source_buf, 'value={{ "C" }}\n')
  hold = true
  local before = #requests
  api.readd()
  assert(waiting())
  assert(vim.wait(1000, function()
    return #requests == before + 1
  end))
  local request = requests[#requests]
  if cancel then
    vim.fn.maparg("q", "n", false, true).callback()
  end
  deliver(request)
  assert(util.buffer_text(session.source_buf) == 'value={{ "C" }}\n', "dynamic content must stay manual")
  assert(not waiting())
end

-- A static merge, including brace escaping, never launches another renderer.
local slow = [[{{ output "sh" "-c" "sleep 0.25; printf A" }}]]
local session = open(slow .. "\nold\n", "A\n{{ literal }}\n")
hold = true
local before = #requests
local result = api.readd()
assert(result and result.merged == 1)
assert(#requests == before and not waiting(), "static merge started a renderer")
assert(assert(require("vimoi.render").snapshot(session.source_buf)).output == "A\n{{ literal }}\n")

-- A genuinely stale dynamic source still renders without blocking the event loop.
hold = false
util.set_buffer_text(session.source_buf, slow:gsub("printf A", "printf B") .. "\nold\n")
local beats = 0
local timer = assert(vim.uv.new_timer())
timer:start(
  5,
  5,
  vim.schedule_wrap(function()
    beats = beats + 1
  end)
)
api.readd()
assert(waiting())
assert(vim.wait(5000, function()
  return not waiting()
end, 10))
timer:stop()
timer:close()
assert(beats > 3, "mapping rendering blocked the event loop")
assert(assert(require("vimoi.render").snapshot(session.source_buf)).output == "B\n{{ literal }}\n")

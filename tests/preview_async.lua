local render_trace = dofile("tests/helpers/trace.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
local api = require("vimoi.api")
local util = require("vimoi.core.util")
local cli = require("vimoi.core.cli")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
vim.opt.swapfile = false

-- A test-only module facade holds async requests; production receives no injected callbacks.
local real_renderer = require("vimoi.render.source_map")
local requests, hold_requests = {}, true
-- Invalidation refreshes older tabs too; each assertion follows its own buffer.
local requests_by_buffer = {}
local renderer = setmetatable({
  trace = function(source, opts)
    assert(not hold_requests, "preview must never render synchronously")
    return render_trace(real_renderer, source, opts)
  end,
  trace_async = function(source, opts, callback)
    if hold_requests then
      local pending = requests_by_buffer[opts.buf]
      pending[#pending + 1] = { source = source, opts = opts, callback = callback }
    else
      return real_renderer.trace_async(source, opts, callback)
    end
  end,
}, { __index = real_renderer })
package.loaded["vimoi.render.source_map"] = renderer
local root = vim.fn.tempname() .. " preview async"
vim.fn.mkdir(root, "p")
local function await(predicate)
  assert(vim.wait(5000, predicate, 10), "async preview did not reach the expected state")
end
local function open(name)
  vim.cmd("tabnew")
  local source = root .. "/" .. name .. ".tmpl"
  vim.fn.writefile({ '{{ $fixture := "' .. name .. '" }}value={{ "A" }}' }, source)
  vim.cmd("edit " .. vim.fn.fnameescape(source))
  requests = {}
  requests_by_buffer[vim.api.nvim_get_current_buf()] = requests
  local before = #requests
  api.preview()
  local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local output = assert(assert(view_for_buffer(source_buf)).target_buf)
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2 and #requests == before)
  assert((view_for_buffer(source_buf) or {}).loading and not vim.bo[output].modifiable)
  await(function()
    return #requests == before + 1
  end)
  return {
    source_buf = source_buf,
    source_win = source_win,
    output = output,
    output_win = vim.fn.bufwinid(output),
    request = requests[#requests],
  }
end
local function deliver(request)
  local trace, err = render_trace(real_renderer, request.source, { init = request.opts.init })
  assert(trace, err)
  request.callback(trace)
end
local function change(pair, value)
  util.set_buffer_text(pair.source_buf, 'value={{ "' .. value .. '" }}\n')
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = pair.source_buf })
end

-- Initial source/context changes retry before displaying stale output.
local pair = open("source-edit")
change(pair, "B")
local before = #requests
deliver(pair.request)
await(function()
  return #requests == before + 1
end)
deliver(requests[#requests])
assert(util.buffer_text(pair.output) == "value=B\n")
pair = open("context-change")
local old_trace = assert(render_trace(real_renderer, pair.request.source))
cli.invalidate("templates")
before = #requests
pair.request.callback(old_trace)
await(function()
  return #requests == before + 1
end)
deliver(requests[#requests])
assert(util.buffer_text(pair.output) == "value=A\n")

-- An EOL option change during rendering has the same changedtick, but its
-- stale input must not become the current output. Reuse the decoded skeleton.
pair = open("eol-edit")
local source_tick = vim.api.nvim_buf_get_changedtick(pair.source_buf)
vim.bo[pair.source_buf].endofline = false
vim.api.nvim_exec_autocmds("OptionSet", { pattern = "endofline" })
deliver(pair.request)
await(function()
  return not (view_for_buffer(pair.source_buf) or {}).loading and util.buffer_text(pair.output) == "value=A"
end)
assert(vim.api.nvim_buf_get_changedtick(pair.source_buf) == source_tick and #requests == 1)

-- Completion while another tab is active must not take focus.
pair = open("focus")
vim.cmd("tabnew")
local user_tab, user_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
deliver(pair.request)
assert(util.buffer_text(pair.output) == "value=A\n")
assert(vim.api.nvim_get_current_tabpage() == user_tab and vim.api.nvim_get_current_win() == user_win)

-- Debounced refreshes discard earlier jobs even when their callbacks arrive last.
pair = open("out-of-order")
deliver(pair.request)
before = #requests
change(pair, "B")
await(function()
  return #requests == before + 1
end)
local stale = requests[#requests]
change(pair, "C")
await(function()
  return #requests == before + 2
end)
local latest = requests[#requests]
deliver(latest)
deliver(stale)
assert(util.buffer_text(pair.output) == "value=C\n")
change(pair, "D")
await(function()
  return #requests == before + 3
end)
stale = requests[#requests]
old_trace = assert(render_trace(real_renderer, stale.source))
cli.invalidate("templates")
stale.callback(old_trace)
await(function()
  return #requests == before + 4
end)
deliver(requests[#requests])
assert(util.buffer_text(pair.output) == "value=D\n")

-- Closing/replacing either side immediately invalidates pending work.
pair = open("source-closed")
vim.api.nvim_win_close(pair.source_win, true)
deliver(pair.request)
assert(vim.api.nvim_buf_is_valid(pair.output) and util.buffer_text(pair.output) == "value=A\n")
assert(not (view_for_buffer(pair.output) or {}).loading and vim.bo[pair.output].readonly)
pair = open("output-closed")
vim.api.nvim_win_close(pair.output_win, true)
deliver(pair.request)
assert(vim.api.nvim_buf_is_valid(pair.output) and not (view_for_buffer(pair.source_buf) or {}).loading)
pair = open("output-replaced")
local replacement = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(pair.output_win, replacement)
deliver(pair.request)
assert(
  vim.api.nvim_win_get_buf(pair.output_win) == replacement and not (view_for_buffer(pair.source_buf) or {}).loading
)
pair = open("source-wiped")
vim.api.nvim_buf_delete(pair.source_buf, { force = true })
deliver(pair.request)
assert(not (view_for_buffer(pair.output) or {}).loading)
pair = open("refresh-closed")
deliver(pair.request)
before = #requests
change(pair, "B")
await(function()
  return #requests == before + 1
end)
vim.api.nvim_win_close(pair.output_win, true)
deliver(requests[#requests])
assert(vim.api.nvim_buf_is_valid(pair.output))

-- Restore real execution through the facade and verify event-loop responsiveness with a slow process.
hold_requests = false
vim.cmd("tabnew")
local slow_source = root .. "/slow.tmpl"
vim.fn.writefile({ [[value={{ output "sh" "-c" "sleep 0.25; printf A" }}]] }, slow_source)
api.preview({ source = slow_source })
local slow_buf = vim.fn.bufnr(slow_source)
local slow_output = assert(assert(view_for_buffer(slow_buf)).target_buf)
assert((view_for_buffer(slow_buf) or {}).loading)
vim.cmd("tabnew")
user_tab, user_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
local beats = 0
local timer = assert(vim.uv.new_timer())
timer:start(
  5,
  5,
  vim.schedule_wrap(function()
    beats = beats + 1
  end)
)
await(function()
  return not (view_for_buffer(slow_buf) or {}).loading
end)
timer:stop()
timer:close()
assert(beats > 3 and util.buffer_text(slow_output) == "value=A\n", "rendering blocked the editor")
assert(vim.api.nvim_get_current_tabpage() == user_tab and vim.api.nvim_get_current_win() == user_win)
print("preview async: stale jobs, context changes, focus, close/replace/wipe, and real slow process verified")

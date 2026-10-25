-- Construction validates a fixed disk baseline; edits never cancel/restart it.
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
assert(require("vimoi").config.render.validate == true)
local api, util = vim.api, require("vimoi.core.util")
local renderer = require("vimoi.render.source_map")
local sessions, cli = require("vimoi.render"), require("vimoi.core.cli")
local run, cats, baselines = cli.run, {}, {}
local render_trace = dofile("tests/helpers/trace.lua")
package.loaded["vimoi.render.source_map"] = setmetatable({
  trace_async = function(source, opts, callback)
    if opts.prefix ~= nil then
      local command = { cancelled = false }
      function command.cancel()
        command.cancelled = true
      end
      baselines[#baselines + 1] = { source = source, opts = opts, finish = callback, command = command }
      return command
    end
    return renderer.trace_async(source, opts, callback)
  end,
}, { __index = renderer })
---@diagnostic disable-next-line: duplicate-set-field -- Hold cat independently of baseline rendering.
cli.run = function(args, opts)
  if args[1] ~= "cat" then
    return run(args, opts)
  end
  local command = { cancelled = false }
  function command.cancel()
    command.cancelled = true
  end
  cats[#cats + 1] = { finish = opts.callback, command = command }
  return command
end
local function await(predicate)
  assert(vim.wait(3000, predicate, 5), "construction did not settle")
end
local function baseline(count)
  await(function()
    return #baselines == count
  end)
  local request = baselines[count]
  request.finish(render_trace(renderer, request.source, request.opts))
end
local function cat(count)
  await(function()
    return #cats == count
  end)
  return cats[count]
end
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local disk = 'value={{ "disk" }}\n'
local function open(name, text)
  local path = root .. "/" .. name .. ".tmpl"
  if not vim.uv.fs_stat(path) then
    vim.fn.writefile(util.text_lines(disk), path)
  end
  local source = api.nvim_create_buf(true, false)
  api.nvim_buf_set_name(source, path)
  util.set_buffer_text(source, text or disk)
  return source
end

-- Already modified buffers also validate the disk baseline, not unsaved text.
local source = open("editing", 'value={{ "before" }}\n')
local events = {}
local stop = sessions.register(source, function(state, err)
  events[#events + 1] = { state = state, error = err }
end, { validate = true, target = "/validation/target" })
local state = sessions.get(source)
local empty = util.buffer_text(state.buf)
await(function()
  return #baselines == 1
end)
assert(baselines[1].source == disk)
assert(#cats == 1, "cat must start before baseline rendering completes")
local discarded = state.buf
api.nvim_buf_delete(discarded, { force = true })
await(function()
  return state.buf ~= discarded
end)
assert(not baselines[1].command.cancelled and not cats[1].command.cancelled)
assert(#baselines == 1 and #cats == 1, "output deletion restarted session construction")
util.set_buffer_text(source, 'value={{ "during baseline" }}\n')
assert(not baselines[1].command.cancelled and state.initialized == nil)
baseline(1)
local pending = cat(1)
util.set_buffer_text(source, "{{ if")
assert(not vim.wait(160, function()
  return pending.command.cancelled or #cats > 1 or #baselines > 1
end, 5))
assert(#events == 0 and state.map == nil and util.buffer_text(state.buf) == empty)
util.set_buffer_text(source, 'value={{ "latest" }}\n')
pending.finish("value=disk\n")
await(function()
  return #events == 1
end)
assert(state.initialized and util.buffer_text(state.buf) == "value=latest\n")
assert(sessions.is_current(source, state.map) and #cats == 1 and #baselines == 1)
util.set_buffer_text(source, 'changed={{ "latest" }}\n')
await(function()
  return #events == 2
end)
cli.invalidate("templates")
await(function()
  return #events == 3
end)
api.nvim_buf_set_name(source, root .. "/renamed.tmpl")
await(function()
  return #events == 4
end)
assert(#cats == 1 and #baselines == 1)
stop()
api.nvim_buf_delete(source, { force = true })

-- Construction failure is latched; buffer edits/saves cannot publish or retry it.
source = open("failed")
local failures = 0
sessions.register(source, function(_, err)
  assert(err)
  failures = failures + 1
end, { validate = true, target = "/validation/target" })
state = sessions.get(source)
baseline(2)
cat(2).finish("mismatch\n")
await(function()
  return failures == 1
end)
assert(state.initialized == false and failures == 1 and state.map == nil)
-- Construction failures have no source AST, but still belong in diagnostics.
require("vimoi.editor.diagnostic").update(source)
local diagnostic_namespace = api.nvim_create_namespace("vimoi-diagnostics")
local construction_errors = vim.diagnostic.get(source, { namespace = diagnostic_namespace })
assert(#construction_errors == 1 and construction_errors[1].lnum == 0)
assert(construction_errors[1].message:find(state.error, 1, true))
util.set_buffer_text(source, 'new={{ "buffer" }}\n')
await(function()
  return failures == 2
end)
api.nvim_exec_autocmds("BufWritePost", { buffer = source })
await(function()
  return failures == 3
end)
assert(#cats == 2 and #baselines == 2 and state.map == nil)
api.nvim_buf_delete(source, { force = true })

-- Reopening creates a fresh construction; explicit cancellation still stops its process.
source = open("failed")
state = sessions.get(source)
local received = false
sessions.register(source, function(_, err)
  assert(not err)
  received = true
end, { validate = true, target = "/validation/target" })
baseline(3)
cat(3).finish("value=disk\n")
assert(received and state.initialized and util.buffer_text(state.buf) == "value=disk\n")
api.nvim_buf_delete(source, { force = true })
source = open("cancelled")
state = sessions.get(source)
stop = sessions.register(source, function()
  error("cancelled wait delivered")
end, { validate = true, target = "/validation/target" })
baseline(4)
pending = cat(4)
stop(true)
assert(pending.command.cancelled)
pending.finish("value=disk\n")
assert(state.initialized == nil and state.map == nil)
api.nvim_buf_delete(source, { force = true })

-- A valid construction can still report current-buffer syntax errors, then recover without cat.
source = open("invalid-live", "{{ if")
state = sessions.get(source)
local publications, last_error = 0, nil
sessions.register(source, function(_, err)
  publications, last_error = publications + 1, err
end, { validate = true, target = "/validation/target" })
baseline(5)
cat(5).finish("value=disk\n")
await(function()
  return publications == 1
end)
assert(state.initialized == true and last_error and state.map == nil)
util.set_buffer_text(source, 'fixed={{ "live" }}\n')
await(function()
  return publications == 2
end)
assert(not last_error and util.buffer_text(state.buf) == "fixed=live\n" and #cats == 5)
api.nvim_buf_delete(source, { force = true })

-- false bypasses construction validation; managed sources inherit true without a view.
source = api.nvim_create_buf(true, false)
util.set_buffer_text(source, "plain\n")
received = false
sessions.register(source, function(_, err)
  assert(not err)
  received = true
end, { once = true, validate = false, target = "/validation/target" })
await(function()
  return received
end)
assert(#cats == 5 and #baselines == 5)
api.nvim_buf_delete(source, { force = true })
source = api.nvim_create_buf(true, false)
local path = cli.source_root .. "/dot_plain"
api.nvim_buf_set_name(source, path)
local text = assert(util.read_file(path))
util.set_buffer_text(source, text)
received = false
sessions.register(source, function(_, err)
  assert(not err)
  received = true
end, { once = true })
baseline(6)
assert(not received)
local joined = false
sessions.register(source, function(_, err)
  assert(not err)
  joined = true
end, { once = true, validate = true, target = sessions.get(source).target_path })
assert(not cat(6).command.cancelled and #baselines == 6)
cat(6).finish(text)
assert(joined)
assert(received and sessions.get(source).initialized)
api.nvim_buf_delete(source, { force = true })

-- Cat can finish first; publication still waits for the matching baseline.
source = open("cat-first")
received = false
sessions.register(source, function(_, err)
  assert(not err)
  received = true
end, { once = true, validate = true, target = "/validation/target" })
cat(7).finish("value=disk\n")
assert(not received and sessions.get(source).initialized == nil)
baseline(7)
assert(received and sessions.get(source).initialized)
api.nvim_buf_delete(source, { force = true })

-- A single cancellation owns both processes, including late completions.
source = open("cancel-both")
state = sessions.get(source)
stop = sessions.register(source, function()
  error("cancelled construction delivered")
end, { validate = true, target = "/validation/target" })
pending = cat(8)
assert(#baselines == 8)
stop(true)
assert(pending.command.cancelled and baselines[8].command.cancelled)
baseline(8)
pending.finish("value=disk\n")
assert(state.initialized == nil and state.map == nil)
api.nvim_buf_delete(source, { force = true })

-- Cancelling either process through its native command UI also stops its peer.
for index, side in ipairs({ "cat", "baseline" }) do
  local count = 8 + index
  source = open("cancel-" .. side)
  local cancellation
  sessions.register(source, function(_, err)
    cancellation = err
  end, { once = true, validate = true, target = "/validation/target" })
  pending = cat(count)
  local request = baselines[count]
  if side == "cat" then
    pending.command.cancel()
    pending.finish(nil, "command cancelled")
  else
    request.command.cancel()
    request.finish(nil, "command cancelled")
  end
  await(function()
    return cancellation ~= nil
  end)
  assert(cancellation == "command cancelled")
  assert(pending.command.cancelled and request.command.cancelled)
  assert(sessions.get(source).initialized == nil)
  api.nvim_buf_delete(source, { force = true })
end

-- Errors retire the peer immediately instead of waiting for a password helper.
for index, side in ipairs({ "cat", "baseline" }) do
  local count = 10 + index
  source = open("error-" .. side)
  local failure
  sessions.register(source, function(_, err)
    failure = err
  end, { once = true, validate = true, target = "/validation/target" })
  pending = cat(count)
  local request = baselines[count]
  if side == "cat" then
    pending.finish(nil, "cat failed")
  else
    request.finish(nil, "baseline failed")
  end
  await(function()
    return failure ~= nil
  end)
  assert(failure == side .. " failed" and sessions.get(source).initialized == false)
  assert(pending.command.cancelled and request.command.cancelled)
  -- A cancelled peer may still report an already queued successful result.
  pending.finish("value=disk\n")
  baseline(count)
  assert(sessions.get(source).initialized == false)
  api.nvim_buf_delete(source, { force = true })
end
cli.run = run
vim.fn.delete(root, "rf")
print(
  "construction: fixed disk baseline, uninterrupted edits, failure latch, reopen, cancellation and true/false verified"
)

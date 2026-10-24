-- One registry serves live consumers and one-shot render waits.
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
local api, util = vim.api, require("vimoi.util")
local renderer = require("vimoi.gotmpl.source_map")
local sessions = require("vimoi.gotmpl.session")
local await = dofile("tests/helpers/await.lua")
local requests = {}
package.loaded["vimoi.gotmpl.source_map"] = setmetatable({
  trace_async = function(source, opts, callback)
    local request = { source = source, opts = opts, callback = callback, cancelled = false }
    requests[#requests + 1] = request
    return {
      cancel = function()
        request.cancelled = true
      end,
    }
  end,
}, { __index = renderer })
local function wait_for(predicate)
  assert(vim.wait(3000, predicate, 5), "output registration did not settle")
end
local function deliver(request)
  request.callback(assert(await(renderer.trace, request.source, { init = request.opts.init })))
end
local source = api.nvim_create_buf(true, false)
util.set_buffer_text(source, 'value={{ "A" }}\n')
local live, once = 0, 0
local stop = sessions.register(source, function(state)
  assert(state)
  live = live + 1
end)
sessions.register(source, function(state)
  assert(state)
  once = once + 1
end, { once = true })
wait_for(function()
  return #requests == 1
end)
deliver(requests[1])
assert(live == 1 and once == 1)
local state = sessions.get(source)
assert(vim.tbl_count(state.subscribers) == 1)

-- Cached callbacks remain asynchronous and can be unregistered before delivery.
local cached = 0
local stop_cached = sessions.register(source, function()
  cached = cached + 1
end, { once = true })
stop_cached()
local drained = false
vim.schedule(function()
  drained = true
end)
wait_for(function()
  return drained
end)
assert(cached == 0)

local other, cancelled = 0, false
local stop_other = sessions.register(source, function(rendered, err)
  if rendered then
    other = other + 1
  else
    cancelled = err == "command cancelled"
  end
end, { initial = false })
util.set_buffer_text(source, 'value={{ "B" }}\n')
wait_for(function()
  return #requests == 2
end)
stop()
assert(not requests[2].cancelled, "one consumer stopped another consumer's render")
deliver(requests[2])
assert(live == 1 and once == 1 and other == 1)

-- Errors use the same callback. One-shot consumers leave the live registry.
local failure
sessions.register(source, function(_, err)
  failure = err
end, { once = true, initial = false })
util.set_buffer_text(source, "{{ if")
wait_for(function()
  return failure ~= nil
end)
assert(vim.tbl_count(state.subscribers) == 1 and util.buffer_text(state.buf) == "value=B\n")

util.set_buffer_text(source, 'value={{ "C" }}\n')
wait_for(function()
  return #requests == 3
end)
local stop_wait = sessions.register(source, function(rendered, err)
  assert(not rendered and err == "command cancelled")
end, { once = true })
stop_wait(true)
wait_for(function()
  return cancelled
end)
assert(requests[3].cancelled)
deliver(requests[3])
assert(util.buffer_text(state.buf) == "value=B\n", "late cancelled output replaced the last good render")
stop_other()

-- Cancelling before debounce expires must not start a password-helper-like
-- command even while another live consumer remains subscribed.
local queued = api.nvim_create_buf(true, false)
util.set_buffer_text(queued, 'queued={{ "yes" }}\n')
local before = #requests
local notified = false
local stop_live = sessions.register(queued, function(_, err)
  notified = err ~= nil
end)
local stop_queued = sessions.register(queued, function()
  error("cancelled registration was called")
end, { once = true })
stop_queued(true)
wait_for(function()
  return notified
end)
assert(not vim.wait(200, function()
  return #requests > before
end, 5), "cancelled debounce still started a render")
util.set_buffer_text(queued, 'queued={{ "edited" }}\n')
wait_for(function()
  return #requests == before + 1
end)
stop_live()
wait_for(function()
  return requests[#requests].cancelled
end)
api.nvim_buf_delete(queued, { force = true })
api.nvim_buf_delete(source, { force = true })
assert(not api.nvim_buf_is_valid(state.buf))
print(
  "session register: live/once/cached callbacks, errors, independent unsubscribe, cancellation and cleanup verified"
)

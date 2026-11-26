-- Delayed completions exercise the shared execution key through rebuild/check.
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
local api, util = vim.api, require("vimoi.core.util")
local renderer = require("vimoi.render.source_map")
local sessions = require("vimoi.render")
local cli = require("vimoi.core.cli")
local await = dofile("tests/helpers/await.lua")
local requests = {}
package.loaded["vimoi.render.source_map"] = setmetatable({
  trace_async = function(source, opts, callback)
    local request = { trace = assert(await(renderer.trace, source, opts)), callback = callback }
    requests[#requests + 1] = request
    return {
      cancel = function()
        request.cancelled = true
      end,
    }
  end,
}, { __index = renderer })
local function wait_for(predicate)
  assert(vim.wait(3000, predicate, 5), "render cache lifecycle did not settle")
end
local source = api.nvim_create_buf(true, false)
util.set_buffer_text(source, 'value={{ "A" }}\n')
local published = 0
local stop = sessions.register(source, function(state, err)
  assert(state, err)
  published = published + 1
end)
wait_for(function()
  return #requests == 1
end)
requests[1].callback(requests[1].trace)
wait_for(function()
  return published == 1
end)
local state = sessions.get(source)
local previous = state.map

util.set_buffer_text(source, 'value={{ "B" }}\n')
wait_for(function()
  return #requests == 2
end)
assert(state.map == previous and util.buffer_text(state.buf) == "value=A\n")
-- A literal edit keeps the in-flight execution and restores the newest source.
util.set_buffer_text(source, 'new={{ "B" }}\n')
sessions.rebuild(source)
assert(not requests[2].cancelled and #requests == 2)
requests[2].callback(requests[2].trace)
wait_for(function()
  return published == 2
end)
assert(util.buffer_text(state.buf) == "new=B\n")

previous = state.map
util.set_buffer_text(source, 'new={{ "C" }}\n')
wait_for(function()
  return #requests == 3
end)
util.set_buffer_text(source, 'new={{ "D" }}\n')
local _, schedule = sessions.rebuild(source)
assert(requests[3].cancelled and state.map == previous)
assert(schedule)
state.check(true)
wait_for(function()
  return #requests == 4
end)
local pending = state.request
requests[3].callback(requests[3].trace)
assert(state.request == pending and state.map == previous, "stale completion changed the current request")
requests[4].callback(requests[4].trace)
wait_for(function()
  return published == 3
end)
assert(util.buffer_text(state.buf) == "new=D\n")

-- Context changes invalidate even an identical skeleton; retain the old map.
previous = state.map
cli.invalidate()
wait_for(function()
  return #requests == 5
end)
assert(state.map == previous and state.rendered_skeleton == nil)
requests[5].callback(requests[5].trace)
wait_for(function()
  return published == 4
end)
assert(sessions.is_current(source, state.map) and state.map.context_generation == cli.context_generation)
stop()
api.nvim_buf_delete(source, { force = true })
print("render cache: literal reuse, structural cancellation, stale completions and context invalidation verified")

local run_async = dofile("tests/helpers/await.lua")
---@diagnostic disable: duplicate-set-field -- Isolated process mock and delayed async completions.
local cli = require("vimoi.core.cli")
local original_system = vim.system
local executions, pending = 0, {}
local forced_result

vim.system = function(args, opts, callback)
  assert(args[2] == "execute-template")
  assert(opts.text == false, "template results must preserve bytes")
  executions = executions + 1
  local result = forced_result
    or { code = 0, stdout = (args[3] == "--init" and "init:" or "") .. opts.stdin, stderr = "" }
  if callback then
    if vim.bo.filetype == "vimoi-progress" then
      vim.schedule(function()
        callback(result)
      end)
    else
      pending[#pending + 1] = function()
        callback(result)
      end
    end
    return {}
  end
  return {
    wait = function()
      return result
    end,
  }
end

local function complete_requests()
  local completions = pending
  pending = {}
  for _, complete in ipairs(completions) do
    complete()
  end
end

-- Caching is opt-in, byte-exact, and shared between sync/async callers.
assert(run_async(cli.execute_template, "plain\r\n") == "plain\r\n")
assert(run_async(cli.execute_template, "plain\r\n") == "plain\r\n")
assert(executions == 2)
assert(run_async(cli.execute_template, "plain\r\n", { cache = true }) == "plain\r\n")
assert(run_async(cli.execute_template, "plain\r\n", { cache = true, timeout = 1 }) == "plain\r\n")
assert(executions == 3)
assert(run_async(cli.execute_template, "plain\n", { cache = true }) == "plain\n")
assert(executions == 4, "CRLF and LF inputs must not share a cache key")
assert(run_async(cli.execute_template, "plain\r\n") == "plain\r\n")
assert(executions == 5, "ordinary execution must bypass an existing cached result")

local received = false
run_async(cli.execute_template, "plain\r\n", {
  cache = true,
  callback = function(output, err)
    assert(output == "plain\r\n" and not err and not vim.in_fast_event())
    received = true
  end,
})
assert(not received and executions == 5, "async cache hits must be scheduled without a process")
assert(vim.wait(1000, function()
  return received
end))

-- Empty successful output is cached. Init and normal execution stay separate.
assert(run_async(cli.execute_template, "", { cache = true }) == "")
local before = executions
assert(run_async(cli.execute_template, "", { cache = true, init = false }) == "")
assert(executions == before)
assert(run_async(cli.execute_template, "", { cache = true, init = true }) == "init:")
assert(executions == before + 1)

-- Failures never enter the cache; a corrected context can be retried.
forced_result = { code = 1, stdout = "", stderr = "invalid template" }
before = executions
for _ = 1, 2 do
  local output, err = run_async(cli.execute_template, "bad", { cache = true })
  assert(output == nil and err and err:find("invalid template", 1, true))
end
assert(executions == before + 2)
forced_result = nil
assert(run_async(cli.execute_template, "bad", { cache = true }) == "bad")
assert(executions == before + 3)

local async_error
forced_result = { code = 1, stdout = "", stderr = "async failure" }
run_async(cli.execute_template, "async failure", {
  cache = true,
  callback = function(output, err)
    assert(output == nil and not vim.in_fast_event())
    async_error = err
  end,
})
complete_requests()
assert(vim.wait(1000, function()
  return async_error ~= nil
end))
assert(async_error:find("async failure", 1, true))
forced_result = nil
before = executions
assert(run_async(cli.execute_template, "async failure", { cache = true }) == "async failure")
assert(executions == before + 1, "async failures must not be cached")

-- Async misses fill the same cache used by synchronous execution.
received = false
run_async(cli.execute_template, "async", {
  cache = true,
  callback = function(output, err)
    assert(output == "async" and not err and not vim.in_fast_event())
    received = true
  end,
})
before = executions
assert(not received)
complete_requests()
assert(vim.wait(1000, function()
  return received
end))
assert(run_async(cli.execute_template, "async", { cache = true }) == "async")
assert(executions == before)

-- An invalidation updates the shared version without loading source_map.
assert(package.loaded["vimoi.render.source_map"] == nil)
local generation = cli.context_generation
cli.invalidate()
assert(cli.context_generation == generation + 1)
assert(package.loaded["vimoi.render.source_map"] == nil)

-- Capture an old request, invalidate, and populate the same key with new data.
forced_result = { code = 0, stdout = "old", stderr = "" }
received = false
run_async(cli.execute_template, "race", {
  cache = true,
  callback = function(output, err)
    assert(output == "old" and not err)
    received = true
  end,
})
cli.invalidate()
forced_result = { code = 0, stdout = "fresh", stderr = "" }
assert(run_async(cli.execute_template, "race", { cache = true }) == "fresh")
before = executions
complete_requests()
assert(vim.wait(1000, function()
  return received
end))
assert(run_async(cli.execute_template, "race", { cache = true }) == "fresh")
assert(executions == before, "old async completion must not overwrite a fresh result")

-- Already scheduled cache hits retain their snapshot, but cannot revive it.
received = false
run_async(cli.execute_template, "race", {
  cache = true,
  callback = function(output, err)
    assert(output == "fresh" and not err)
    received = true
  end,
})
cli.invalidate()
assert(vim.wait(1000, function()
  return received
end))
forced_result = nil
assert(run_async(cli.execute_template, "race", { cache = true }) == "race")
assert(executions == before + 1)

-- Two concurrent completions for one input must occupy only one FIFO entry.
cli.invalidate()
local received_count = 0
for _ = 1, 2 do
  run_async(cli.execute_template, "first", {
    cache = true,
    callback = function(output, err)
      assert(output == "first" and not err)
      received_count = received_count + 1
    end,
  })
end
complete_requests()
assert(vim.wait(1000, function()
  return received_count == 2
end))
for index = 2, 32 do
  assert(run_async(cli.execute_template, tostring(index), { cache = true }) == tostring(index))
end
before = executions
assert(run_async(cli.execute_template, "first", { cache = true }) == "first")
assert(executions == before, "duplicate completions must not cause early eviction")
assert(run_async(cli.execute_template, "33", { cache = true }) == "33")
assert(run_async(cli.execute_template, "2", { cache = true }) == "2")
assert(executions == before + 1)
assert(run_async(cli.execute_template, "first", { cache = true }) == "first")
assert(executions == before + 2, "oldest template should be evicted at 32 entries")

vim.system = original_system
print("CLI template cache: opt-in, sync/async, invalidation, init, errors, and capacity verified")

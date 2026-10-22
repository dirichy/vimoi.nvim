local util = require("vimoi.util")
local function wait_for(predicate)
  assert(vim.wait(1500, predicate, 2), "guard did not finish")
end

-- Debounce preserves the latest arguments, including nils, and validates at start.
local starts, valid = {}, true
local delayed = util.guard(function(...)
  starts[#starts + 1] = vim.F.pack_len(...)
end, {
  delay = 10,
  is_valid = function()
    return valid
  end,
})
delayed("old")
delayed("new", nil, 3, nil)
wait_for(function()
  return #starts == 1
end)
assert(starts[1].n == 4 and starts[1][1] == "new" and starts[1][3] == 3)
delayed("invalid")
valid = false
vim.wait(30, function()
  return false
end, 2)
assert(#starts == 1)

-- Default serialization coalesces calls while the coroutine is suspended.
local done, published = {}, {}
local serial = util.guard(function(value)
  return util.await(function(finish)
    done[#done + 1] = { finish = finish, value = value }
  end)
end, {
  delay = 10,
  is_valid = function()
    return true
  end,
  on_result = function(value)
    published[#published + 1] = value
  end,
})
serial("first")
wait_for(function()
  return #done == 1
end)
serial("middle")
serial("last")
vim.wait(30, function()
  return false
end, 2)
assert(#done == 1)
done[1].finish("first result")
wait_for(function()
  return #done == 2
end)
assert(done[2].value == "last")
done[2].finish("last result")
assert(vim.deep_equal(published, { "first result", "last result" }))

-- Parallel tasks may overlap, but their not-yet-started calls still debounce.
local parallel_done = {}
local parallel = util.guard(function(value)
  return util.await(function(finish)
    parallel_done[#parallel_done + 1] = { finish = finish, value = value }
  end)
end, {
  delay = 10,
  allow_parallel = true,
  is_valid = function()
    return true
  end,
  on_result = function() end,
})
parallel(1)
wait_for(function()
  return #parallel_done == 1
end)
parallel(2)
parallel(3)
wait_for(function()
  return #parallel_done == 2
end)
assert(parallel_done[2].value == 3)
parallel_done[2].finish()
parallel_done[1].finish()

-- Retry stale results explicitly, independently of call validity.
local retry_done, retry_published, version = {}, {}, 1
local retry = util.guard(function(value)
  local snapshot = version
  util.await(function(finish)
    retry_done[#retry_done + 1] = finish
  end)
  return snapshot, value
end, {
  delay = 10,
  is_valid = function()
    return true
  end,
  should_retry = function(snapshot)
    return snapshot ~= version
  end,
  on_result = function(snapshot, value)
    retry_published[#retry_published + 1] = { snapshot, value }
  end,
})
retry()
wait_for(function()
  return #retry_done == 1
end)
version = 2
retry_done[1]()
assert(#retry_published == 0)
wait_for(function()
  return #retry_done == 2
end)
retry_done[2]()
assert(#retry_published == 1 and retry_published[1][1] == 2)

-- Undebounced calls still defer stale retries, including immediately completed
-- parallel computations. Publication return values never request another run.
for _, allow_parallel in ipairs({ false, true }) do
  local attempts, publications, heartbeat = 0, 0, false
  local task = util.guard(function()
    attempts = attempts + 1
    return attempts
  end, {
    allow_parallel = allow_parallel,
    is_valid = function()
      return true
    end,
    should_retry = function(value)
      return value == 1
    end,
    on_result = function()
      assert(heartbeat, "retry must return to the editor before starting")
      publications = publications + 1
      return true
    end,
  })
  task()
  assert(attempts == 1 and publications == 0, "retry must not recurse synchronously")
  vim.schedule(function()
    heartbeat = true
  end)
  wait_for(function()
    return publications == 1
  end)
  vim.wait(120, function()
    return false
  end, 2)
  assert(attempts == 2 and publications == 1, "on_result return value must not trigger retries")
end

-- Call checks always receive original arguments; result checks receive results.
-- Retiring the owner while suspended drops the call without retrying stale work.
local owner_alive, owner_finish, owner_starts, owner_failures, owner_results = true, nil, 0, 0, 0
local owner_task = util.guard(function()
  owner_starts = owner_starts + 1
  util.await(function(finish)
    owner_finish = finish
  end)
  return "computed", nil, 42
end, {
  delay = 10,
  is_valid = function(...)
    local args = vim.F.pack_len(...)
    assert(args.n == 3 and args[1] == "input" and args[2] == nil and args[3] == 7)
    return owner_alive
  end,
  on_fail = function(...)
    local args = vim.F.pack_len(...)
    assert(args.n == 3 and args[1] == "input" and args[3] == 7)
    owner_failures = owner_failures + 1
    return true -- No implicit retry from this return value.
  end,
  should_retry = function(...)
    local values = vim.F.pack_len(...)
    assert(values.n == 3 and values[1] == "computed" and values[3] == 42)
    return false
  end,
  on_result = function(...)
    local values = vim.F.pack_len(...)
    assert(values.n == 3 and values[1] == "computed" and values[3] == 42)
    owner_results = owner_results + 1
  end,
})
owner_task("input", nil, 7)
wait_for(function()
  return owner_starts == 1
end)
assert(owner_finish)()
assert(owner_results == 1)
owner_task("input", nil, 7)
wait_for(function()
  return owner_starts == 2
end)
owner_alive = false
assert(owner_finish)()
vim.wait(30, function()
  return false
end, 2)
assert(owner_starts == 2 and owner_failures == 1 and owner_results == 1)

-- Inspection and consumption may share should_retry, without on_result.
-- A rejected item causes a retry before any partially computed result is published.
local combined_attempts, combined_publications = 0, {}
local combined = util.guard(function()
  combined_attempts = combined_attempts + 1
  if combined_attempts == 1 then
    return { 2, false }
  end
  return { 2, 3 }
end, {
  is_valid = function()
    return true
  end,
  should_retry = function(items)
    local values = {}
    for _, item in ipairs(items) do
      if item == false then
        return true
      end
      values[#values + 1] = item * 2
    end
    combined_publications[#combined_publications + 1] = values
    return false
  end,
})
combined()
assert(combined_attempts == 1 and #combined_publications == 0)
wait_for(function()
  return #combined_publications == 1
end)
assert(combined_attempts == 2 and vim.deep_equal(combined_publications[1], { 4, 6 }))

-- Omitting on_result preserves the final computation's return arity.
local final_values = vim.F.pack_len(util.guard(function()
  return "final", nil, 7, nil
end, {
  is_valid = function()
    return true
  end,
  should_retry = function(...)
    return select("#", ...) ~= 4
  end,
})())
assert(final_values.n == 4 and final_values[1] == "final" and final_values[3] == 7)

-- Failure during computing, validation or publishing must release the serial slot.
for _, failure in ipairs({ "compute", "validate", "publish" }) do
  local finish, broken, count = nil, true, 0
  local task = util.guard(function()
    util.await(function(callback)
      finish = callback
    end)
    if broken and failure == "compute" then
      error("compute")
    end
    return "result"
  end, {
    is_valid = function()
      return true
    end,
    should_retry = function()
      if broken and failure == "validate" then
        error("validate")
      end
      return false
    end,
    on_result = function()
      if broken and failure == "publish" then
        error("publish")
      end
      count = count + 1
    end,
  })
  task()
  assert(not pcall(assert(finish)), "task error must propagate")
  broken = false
  task()
  assert(finish)()
  assert(count == 1, "failed task must not block later calls")
end
print("guard: debounce, serialization, parallelism, retry, nil arguments and error cleanup verified")

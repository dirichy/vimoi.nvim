---@diagnostic disable: duplicate-set-field -- Hold shared process completions to test callback failures.
local cli = require("vimoi.cli")
local original_run = cli.run
local pending
local processes = 0
cli.run = function(_, opts)
  processes = processes + 1
  pending = assert(opts.callback)
  return { finished = false, cancelled = false, cancel = function() end }
end

for _, command in ipairs({ "data", "template" }) do
  cli.invalidate()
  local received = 0
  local subscriptions = {}
  local before = processes
  for index = 1, 3 do
    local function callback(value, err)
      assert(value ~= nil and err == nil)
      if index == 1 then
        error("first subscriber failed")
      end
      received = received + 1
    end
    if command == "data" then
      cli.data_async(callback)
    else
      subscriptions[index] = cli.execute_template("shared", { cache = true, callback = callback })
    end
  end
  assert(processes == before + 1, "subscribers must share one process")
  local ok, err = pcall(assert(pending), command == "data" and { chezmoi = {} } or "output")
  assert(not ok and tostring(err):find("first subscriber failed", 1, true), "callback error must propagate")
  assert(received == 2, "a failed subscriber must not strand the remaining subscribers")
  for _, subscription in ipairs(subscriptions) do
    assert(subscription.finished, "all subscriptions must finish even when a callback fails")
  end
end
-- Lua errors may carry nil; error detection must not depend on a truthy payload.
cli.invalidate()
local delivered = false
cli.data_async(function()
  error(nil, 0)
end)
cli.data_async(function()
  delivered = true
end)
local ok = pcall(assert(pending), { chezmoi = {} })
assert(not ok and delivered)
cli.run = original_run
print("shared callbacks: subscriber errors propagate after all waiters receive the result")

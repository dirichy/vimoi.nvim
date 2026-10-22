local run_async = dofile("tests/helpers/await.lua")
---@diagnostic disable: duplicate-set-field -- Isolated CLI results and async completions.
local cli = require("vimoi.cli")
local original_run = cli.run
local source_root = vim.fn.getcwd() .. "/tests/fixtures/environment/source"
local source_file = source_root .. "/dot_diff_target.tmpl"
local calls, pending = {}, {}
cli.source_root = source_root
cli.run = function(args, opts)
  opts = opts or {}
  local command = args[1]
  calls[command] = (calls[command] or 0) + 1
  local output
  if command == "data" then
    output = { chezmoi = { sourceDir = source_root, destDir = "/tmp" }, revision = calls.data }
  elseif command == "execute-template" then
    output = tostring(calls[command])
  elseif command == "target-path" then
    output = "/tmp/vimoi-partial-target"
  elseif command == "source-path" then
    output = source_file
  else
    error("unexpected command: " .. command)
  end
  if opts.callback then
    if opts.mode == "modal" then
      vim.schedule(function()
        opts.callback(output)
      end)
    else
      pending[#pending + 1] = function()
        opts.callback(output)
      end
    end
    return {}
  end
  return output
end

local function complete_requests()
  local completions = pending
  pending = {}
  for _, callback in ipairs(completions) do
    callback()
  end
end

local data = assert(run_async(cli.data))
assert(cli.counterpart_path(source_file) == "/tmp/vimoi-partial-target")
local output = assert(run_async(cli.execute_template, "source", { cache = true }))
local generation = cli.context_generation
cli.invalidate("paths")
assert(cli.context_generation == generation)
assert(run_async(cli.data) == data and calls.data == 1)
assert(run_async(cli.execute_template, "source", { cache = true }) == output)
assert(calls["execute-template"] == 1)
assert(cli.counterpart_path(source_file) == "/tmp/vimoi-partial-target")
assert(calls["target-path"] == 2)

cli.invalidate("templates")
assert(cli.context_generation == generation + 1)
assert(run_async(cli.data) == data and calls.data == 1)
assert(cli.counterpart_path(source_file) == "/tmp/vimoi-partial-target")
assert(calls["target-path"] == 2)
assert(run_async(cli.execute_template, "source", { cache = true }) ~= output)

cli.invalidate("data")
assert(cli.context_generation == generation + 2)
assert(run_async(cli.data) ~= data and calls.data == 2)
assert(cli.counterpart_path(source_file) == "/tmp/vimoi-partial-target")
assert(calls["target-path"] == 2)
assert(
  run_async(cli.execute_template, "source", { cache = true }) == "3",
  "data invalidation must clear dependent templates"
)

-- Template/path invalidation must not cancel or duplicate an in-flight data query.
cli.invalidate("data")
local received = 0
local async_data
cli.data_async(function(value, err)
  assert(value and not err)
  async_data = value
  received = received + 1
end)
cli.invalidate("templates")
cli.invalidate("paths")
cli.data_async(function(value, err)
  assert(value and not err)
  received = received + 1
end)
assert(calls.data == 3, "unrelated invalidation must preserve request coalescing")
complete_requests()
assert(received == 2 and run_async(cli.data) == async_data)

-- A data-only invalidation must reject old data completions independently.
cli.invalidate("data")
local stale_received = false
cli.data_async(function(value, err)
  assert(value == nil and err and err:find("invalidated", 1, true))
  stale_received = true
end)
cli.invalidate("data")
local fresh_data
cli.data_async(function(value, err)
  assert(not err)
  fresh_data = value
end)
complete_requests()
assert(stale_received and run_async(cli.data) == fresh_data)

-- Path invalidation leaves in-flight template requests valid; data invalidation
-- prevents their completion from refilling the dependent template cache.
local async_template
run_async(cli.execute_template, "async", {
  cache = true,
  callback = function(value)
    async_template = value
  end,
})
cli.invalidate("paths")
complete_requests()
assert(run_async(cli.execute_template, "async", { cache = true }) == async_template)
run_async(cli.execute_template, "stale", { cache = true, callback = function() end })
cli.invalidate("data")
complete_requests()
local before = calls["execute-template"]
run_async(cli.execute_template, "stale", { cache = true })
assert(calls["execute-template"] == before + 1)

generation = cli.context_generation
local valid = pcall(cli.invalidate, "typo")
assert(not valid and cli.context_generation == generation)
cli.invalidate("all")
assert(cli.context_generation == generation + 1)
cli.run = original_run
print("partial invalidation: scopes, dependencies, and async isolation verified")

---@diagnostic disable: duplicate-set-field -- Hold asynchronous template results to exercise lifecycle races.
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local cli, util = require("vimoi.cli"), require("vimoi.util")
local original_execute = cli.execute_template
local namespace = vim.api.nvim_create_namespace("vimoi-diagnostics")
local requests = {}
cli.execute_template = function(source, opts)
  local job = { finished = false, cancelled = false }
  function job.cancel()
    job.cancelled = true
  end
  requests[#requests + 1] = { source = source, opts = opts, job = job }
  return job
end
local function wait_for(test)
  assert(vim.wait(2000, test, 5), "diagnostic request did not arrive")
end
local function change(buf, source)
  util.set_buffer_text(buf, source)
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
end
local function open(source)
  local buf = vim.api.nvim_create_buf(false, true)
  util.set_buffer_text(buf, source)
  vim.bo[buf].filetype = "gotmpl"
  return buf
end
local function deliver(request, name)
  request.job.finished = true
  request.opts.callback(nil, 'fake failed (1): chezmoi: template: stdin:1: function "' .. name .. '" not defined')
end

-- Fast structural edits are debounced; only the final skeleton starts a job.
local buf = open("{{ initial . }}")
change(buf, "{{ intermediate . }}")
change(buf, "{{ final . }}")
wait_for(function()
  return #requests == 1
end)
assert(requests[1].source:find("final", 1, true) and not requests[1].source:find("intermediate", 1, true))

-- A static edit while rendering retains the request, and its result uses the
-- newest source positions instead of the snapshot that launched the process.
change(buf, "header\n\n{{ final . }}")
local drained = false
vim.defer_fn(function()
  drained = true
end, 400)
wait_for(function()
  return drained
end)
assert(#requests == 1 and not requests[1].job.cancelled)
deliver(requests[1], "final")
local diagnostics = vim.diagnostic.get(buf, { namespace = namespace })
assert(#diagnostics == 1 and diagnostics[1].lnum == 2)

-- A result arriving before the static edit's debounce must be cached, then
-- published at the new position without launching another rendering process.
change(buf, "{{ early . }}")
wait_for(function()
  return #requests == 2
end)
change(buf, "header\n{{ early . }}")
deliver(requests[2], "early")
assert(vim.diagnostic.get(buf, { namespace = namespace })[1].message:find('"final"', 1, true))
wait_for(function()
  local found = vim.diagnostic.get(buf, { namespace = namespace })
  return #found == 1 and found[1].message:find('"early"', 1, true) ~= nil
end)
assert(#requests == 2 and vim.diagnostic.get(buf, { namespace = namespace })[1].lnum == 1)
table.remove(requests, 2)

-- Changed structure invalidates a request; its late error cannot overwrite the next one.
change(buf, "{{ old . }}")
wait_for(function()
  return #requests == 2
end)
change(buf, "{{ new . }}")
wait_for(function()
  return #requests == 3
end)
assert(requests[2].job.cancelled)
deliver(requests[2], "old")
assert(vim.diagnostic.get(buf, { namespace = namespace })[1].message:find('"early"', 1, true))
deliver(requests[3], "new")
assert(vim.diagnostic.get(buf, { namespace = namespace })[1].message:find('"new"', 1, true))

-- Dependency changes discard pending results and re-run the same structure.
change(buf, "{{ dependency . }}")
wait_for(function()
  return #requests == 4
end)
cli.invalidate("data")
deliver(requests[4], "dependency")
assert(vim.diagnostic.get(buf, { namespace = namespace })[1].message:find('"new"', 1, true))
wait_for(function()
  return #requests == 5
end)
deliver(requests[5], "dependency")
assert(#vim.diagnostic.get(buf, { namespace = namespace }) == 1)

-- Cancellation is not a template diagnostic and does not populate the failure cache.
change(buf, "{{ cancelled . }}")
wait_for(function()
  return #requests == 6
end)
requests[6].job.cancel()
requests[6].opts.callback(nil, "command cancelled")
assert(vim.diagnostic.get(buf, { namespace = namespace })[1].message:find('"dependency"', 1, true))
change(buf, "static\n{{ cancelled . }}")
wait_for(function()
  return #requests == 7
end)

-- Disable, unload and filetype changes retire in-flight requests and clear only
-- chezmoi's diagnostics; unrelated diagnostics remain owned by their provider.
local other = vim.api.nvim_create_namespace("another-provider")
vim.diagnostic.set(other, buf, { { lnum = 0, col = 0, message = "other" } })
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
assert(vim.wait(1000, function()
  return requests[7].job.cancelled
end))
deliver(requests[7], "cancelled")
assert(
  #vim.diagnostic.get(buf, { namespace = namespace }) == 0 and #vim.diagnostic.get(buf, { namespace = other }) == 1
)
require("vimoi").setup({ diagnostics = { enabled = true } })
wait_for(function()
  return #requests == 8
end)
vim.bo[buf].filetype = "yaml"
assert(vim.wait(1000, function()
  return requests[8].job.cancelled
end))
deliver(requests[8], "cancelled")
assert(#vim.diagnostic.get(buf, { namespace = namespace }) == 0)
vim.api.nvim_buf_delete(buf, { force = true })

buf = open("{{ unloaded . }}")
wait_for(function()
  return #requests == 9
end)
vim.api.nvim_buf_delete(buf, { force = true })
assert(requests[9].job.cancelled)
deliver(requests[9], "unloaded")
cli.execute_template = original_execute
print(
  "async diagnostics: debounce, static edits, stale results, invalidation, cancellation, disable and detach verified"
)

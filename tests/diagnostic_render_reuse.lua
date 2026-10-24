---@diagnostic disable: duplicate-set-field -- Count underlying processes and concurrent consumers.
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local cli = require("vimoi.cli")
local sessions = require("vimoi.gotmpl.session")
local namespace = vim.api.nvim_create_namespace("vimoi-diagnostics")
local original_run, original_execute, original_set = cli.run, cli.execute_template, vim.diagnostic.set
local jobs, requests, publications = {}, 0, 0
cli.run = function(args, opts)
  local job = original_run(args, opts)
  if args[1] == "execute-template" then
    jobs[#jobs + 1] = job
  end
  return job
end
cli.execute_template = function(source, opts)
  requests = requests + 1
  return original_execute(source, opts)
end
vim.diagnostic.set = function(ns, ...)
  if ns == namespace then
    publications = publications + 1
  end
  return original_set(ns, ...)
end
local function wait_for(test)
  assert(vim.wait(5000, test, 5), "shared render did not complete")
end
local files = {}
local function open(value, duration)
  vim.cmd("tabnew")
  local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
  files[#files + 1], files[#files + 2] = source, target
  vim.fn.writefile({ '{{ output "sh" "-c" "sleep ' .. duration .. "; printf " .. value .. '" }}' }, source)
  vim.fn.writefile({ "different" }, target)
  local before = requests
  api.diff_files(source, target)
  local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
  wait_for(function()
    return requests >= before + 2
  end)
  return session
end

-- Disable diagnostics during a shared render: the view must still finish.
local session = open("A", "0.8")
assert(#jobs == 1, "view and diagnostics launched duplicate processes")
require("vimoi").setup({ diagnostics = { enabled = false } })
wait_for(function()
  return session.trace ~= nil
end)
assert(not jobs[1].cancelled and session.trace.output == "A\n")
sessions.close(session)

-- Closing the view must not cancel a render still needed by diagnostics.
require("vimoi").setup({ diagnostics = { enabled = true } })
local before = publications
session = open("B", "0.8")
assert(#jobs == 2)
sessions.close(session)
wait_for(function()
  return jobs[2].finished
end)
wait_for(function()
  return publications > before
end)
assert(not jobs[2].cancelled and session.closed)
assert(#vim.diagnostic.get(session.source_buf, { namespace = namespace }) == 0)

-- Rendered highlighting remains a consumer after diagnostics and the view
-- release the process. Disabling that final consumer must terminate it.
session = open("C", "30")
assert(#jobs == 3)
require("vimoi").setup({ diagnostics = { enabled = false } })
sessions.close(session)
assert(not jobs[3].cancelled, "view/diagnostic cancellation interrupted rendered highlighting")
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
wait_for(function()
  return jobs[3].finished
end)
assert(jobs[3].cancelled)
-- Explicit modal cancellation still kills the command, even if automatic
-- diagnostics have subscribed; it must not leave a password helper running.
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "gotmpl" then
    vim.bo[buf].filetype = "text"
  end
end
require("vimoi").setup({ diagnostics = { enabled = true } })
session = open("D", "30")
assert(#jobs == 4)
api.readd()
assert(session.pending_merge and vim.bo.filetype == "vimoi-progress")
vim.fn.maparg("q", "n", false, true).callback()
wait_for(function()
  return jobs[4].finished
end)
assert(jobs[4].cancelled and session.closed)
assert(#vim.diagnostic.get(session.source_buf, { namespace = namespace }) == 0)

cli.run, cli.execute_template, vim.diagnostic.set = original_run, original_execute, original_set
for _, path in ipairs(files) do
  vim.fn.delete(path)
end
print("shared rendering: one process, independent view/diagnostic cancellation and final process cleanup verified")

local run_async = dofile("tests/helpers/await.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
---@diagnostic disable: duplicate-set-field -- Hold render/validation callbacks to exercise races.
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})

local diff = require("vimoi.gotmpl")
local diff_hunks = require("vimoi.gotmpl.diff_hunks")
local sessions = require("vimoi.gotmpl.view")
local source_map = require("vimoi.gotmpl.source_map")
local cli = require("vimoi.cli")
local util = require("vimoi.util")
local trace, trace_async, run, compute, notify =
  source_map.trace, source_map.trace_async, cli.run, diff_hunks.compute, vim.notify
local requests, validations, validation_jobs, computed, messages = {}, {}, {}, {}, {}
local root = vim.fn.tempname() .. " async diff"
vim.fn.mkdir(root, "p")

source_map.trace = function()
  error("initial open must not render synchronously")
end
source_map.trace_async = function(source, opts, callback)
  requests[#requests + 1] = { source = source, opts = opts, callback = callback }
end
cli.run = function(args, opts)
  if args[1] == "cat" then
    assert(opts and opts.callback, "initial validation must not block")
    local job = { cancelled = false }
    function job.cancel()
      job.cancelled = true
    end
    validations[#validations + 1] = opts.callback
    validation_jobs[#validation_jobs + 1] = job
    return job
  end
  return run(args, opts)
end
diff_hunks.compute = function(modified, source_trace)
  computed[#computed + 1] = { modified = modified, source = source_trace.source }
  return compute(modified, source_trace)
end
vim.notify = function(message, level)
  messages[#messages + 1] = { message = message, level = level }
end

local function open(label, validate)
  -- Each fixture owns the mocked request queue. Redraws can otherwise deliver
  -- a previous tab's debounced refresh while the next fixture waits to open.
  for _, previous in ipairs(vim.tbl_values(sessions.by_window)) do
    sessions.close(previous)
  end
  vim.cmd("tabnew")
  local source_path, target_path = root .. "/" .. label .. ".tmpl", root .. "/" .. label
  vim.fn.writefile({ 'value={{ "A" }}' }, source_path)
  vim.fn.writefile({ "value=B" }, target_path)
  local before = #requests
  diff.open({ source = source_path, target = target_path, validate = validate == true })
  local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local target_buf = vim.fn.bufnr(target_path)
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2, "windows must open before the renderer starts")
  assert((view_for_buffer(source_buf) or {}).loading and (view_for_buffer(target_buf) or {}).loading)
  assert(not vim.wo[source_win].diff and #requests == before)
  assert(vim.wait(1000, function()
    return #requests == before + 1
  end))
  return {
    source_buf = source_buf,
    target_buf = target_buf,
    source_win = source_win,
    target_win = vim.fn.bufwinid(target_buf),
    request = requests[#requests],
    source_path = source_path,
    target_path = target_path,
  }
end

local function deliver(request)
  local result, err = run_async(trace, request.source, { init = request.opts.init })
  assert(result, err)
  request.callback(result)
end

-- Closing/replacing a buffer before the queued initial job even starts is safe.
do
  local source_path, target_path = root .. "/early.tmpl", root .. "/early"
  vim.fn.writefile({ "early" }, source_path)
  vim.fn.writefile({ "early" }, target_path)
  local before = #requests
  diff.open({ source = source_path, target = target_path })
  local target_buf = vim.fn.bufnr(target_path)
  vim.api.nvim_buf_delete(vim.api.nvim_get_current_buf(), { force = true })
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  assert(vim.wait(1000, function()
    return drained
  end))
  assert(#requests == before and not (view_for_buffer(target_buf) or {}).loading)
end

-- Pending operations do not fall back to a blocking render. Completion uses
-- target edits made while waiting and does not steal another tab's focus.
local pair = open("target-edit")
assert(require("vimoi.api").put_hunk() == nil)
assert(require("vimoi.api").readd() == nil)
diff.fold("zo")
util.set_buffer_text(pair.target_buf, "value=C\n")
vim.cmd("tabnew")
local user_tab, user_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
deliver(pair.request)
assert(vim.api.nvim_get_current_tabpage() == user_tab and vim.api.nvim_get_current_win() == user_win)
assert(not vim.wo[pair.source_win].diff and not vim.wo[pair.target_win].diff)
assert(not view_for_buffer(pair.source_buf), "leaving the modal must cancel initial rendering")

-- Source edits and context invalidation retry instead of applying an old trace.
pair = open("source-edit")
util.set_buffer_text(pair.source_buf, 'value={{ "C" }}\n')
local before = #requests
deliver(pair.request)
assert((view_for_buffer(pair.source_buf) or {}).loading)
assert(vim.wait(1000, function()
  return #requests == before + 1
end))
deliver(requests[#requests])
assert(computed[#computed].source == 'value={{ "C" }}\n')
pair = open("context-change")
cli.invalidate("templates")
before = #requests
deliver(pair.request)
assert(vim.wait(1000, function()
  return #requests == before + 1
end))
deliver(requests[#requests])
assert(vim.wo[pair.source_win].diff)

-- Target edits do not obsolete the render: initialize against the latest target.
pair = open("latest-target")
util.set_buffer_text(pair.target_buf, "value=latest\n")
deliver(pair.request)
assert(computed[#computed].modified == "value=latest\n")
assert(not (view_for_buffer(pair.source_buf) or {}).loading)

-- An obsolete render retries before starting cat validation.
pair = open("edit-before-validation", true)
util.set_buffer_text(pair.source_buf, 'value={{ "E" }}\n')
local validations_before = #validations
before = #requests
deliver(pair.request)
assert(#validations == validations_before)
assert(vim.wait(1000, function()
  return #requests == before + 1
end))
deliver(requests[#requests])
assert(#validations == validations_before + 1)
validations[#validations]("value=E\n")
assert(vim.wo[pair.source_win].diff)

-- Closing during cat validation cancels that process and rejects its late result.
pair = open("closed-during-validation", true)
deliver(pair.request)
local validation_job = validation_jobs[#validation_jobs]
assert(assert(view_for_buffer(pair.source_buf)).render_job == validation_job)
vim.api.nvim_win_close(pair.source_win, true)
assert(vim.wait(1000, function()
  return validation_job.cancelled
end))
before = #computed
validations[#validations]("value=A\n")
assert(#computed == before and not view_for_buffer(pair.target_buf))

-- A retry queued by stale output must not restart a session closed before it runs.
pair = open("closed-before-retry")
util.set_buffer_text(pair.source_buf, 'value={{ "F" }}\n')
before = #requests
deliver(pair.request)
vim.api.nvim_win_close(pair.source_win, true)
local drained = false
vim.defer_fn(function()
  drained = true
end, 20)
assert(vim.wait(1000, function()
  return drained
end))
assert(#requests == before and not view_for_buffer(pair.target_buf))

-- Closed/replaced windows must not be revived by a late completion.
pair = open("closed")
vim.api.nvim_win_close(pair.source_win, true)
before = #computed
deliver(pair.request)
assert(#computed == before and not vim.wo[pair.target_win].diff)
assert(not (view_for_buffer(pair.target_buf) or {}).loading and vim.b[pair.target_buf].snacks_scroll == nil)
pair = open("replaced")
local replacement_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(pair.source_win, replacement_buf)
assert(not (view_for_buffer(pair.target_buf) or {}).loading, "buffer replacement must immediately cancel loading")
before = #computed
deliver(pair.request)
assert(#computed == before and vim.api.nvim_win_get_buf(pair.source_win) == replacement_buf)
assert(not (view_for_buffer(pair.target_buf) or {}).loading)
pair = open("wiped")
vim.api.nvim_buf_delete(pair.source_buf, { force = true })
before = #computed
deliver(pair.request)
assert(#computed == before and not (view_for_buffer(pair.target_buf) or {}).loading)

-- Renaming keeps the view; a source rename refreshes the source-owned cache.
for _, field in ipairs({ "source_buf", "target_buf" }) do
  pair = open("renamed-" .. field)
  local view = assert(view_for_buffer(pair.source_buf))
  vim.api.nvim_buf_set_name(pair[field], root .. "/renamed-" .. field .. "-new")
  deliver(pair.request)
  assert(vim.wait(1000, function()
    return not view.loading
  end))
  assert(not view.loading and sessions.is_valid(view))
  assert(vim.wo[pair.source_win].diff and vim.wo[pair.target_win].diff)
end

-- Replacing a view borrows the same in-flight source render. Its old view
-- callback cannot rebind the new session or clear its loading state.
pair = open("reopened")
local request_count = #requests
diff.open({ source = pair.source_path, target = pair.target_path })
deliver(pair.request)
assert(vim.wait(1000, function()
  return not (view_for_buffer(pair.source_buf) or {}).loading
end))
assert(#requests == request_count, "reopening duplicated the shared render")

-- A cached reopen from target still suppresses inherited native diff until
-- the asynchronous initialization callback adopts the existing source map.
vim.api.nvim_set_current_win(vim.fn.bufwinid(pair.target_buf))
diff.open({ source = pair.source_path, target = pair.target_path })
local reopened_source_win = vim.api.nvim_get_current_win()
assert(not vim.wo[reopened_source_win].diff and (view_for_buffer(pair.source_buf) or {}).loading)
assert(vim.wait(1000, function()
  return not (view_for_buffer(pair.source_buf) or {}).loading
end))
assert(vim.wo[reopened_source_win].diff and #requests == request_count)

-- Merge owns its wait while the view only reports readiness/closure.
for _, outcome in ipairs({ "success", "cancel", "close", "failure" }) do
  pair = open("merge-during-validation-" .. outcome, true)
  deliver(pair.request)
  local view = assert(view_for_buffer(pair.source_buf))
  local validation = validation_jobs[#validation_jobs]
  local waiting = dofile("tests/helpers/waiting.lua")
  assert(require("vimoi.api").put_hunk() == nil and waiting())
  assert(util.buffer_text(pair.target_buf) == "value=B\n", "merge skipped initial cat validation")
  if outcome == "cancel" then
    vim.fn.maparg("q", "n", false, true).callback()
  elseif outcome == "close" then
    sessions.close(view)
    assert(vim.wait(1000, function()
      return validation.cancelled
    end))
  end
  if outcome == "failure" then
    validations[#validations](nil, "validation failed while merging")
  else
    validations[#validations]("value=A\n")
  end
  assert(vim.wait(1000, function()
    return not waiting()
  end))
  assert(util.buffer_text(pair.target_buf) == (outcome == "success" and "value=A\n" or "value=B\n"))
  if outcome == "cancel" or outcome == "close" then
    assert(
      vim.wait(1000, function()
        return validation.cancelled
      end),
      "abandoned merge retained its validation process"
    )
  end
end

-- Strict cat validation is asynchronous too, including edits while it waits.
pair = open("validation", true)
deliver(pair.request)
assert((view_for_buffer(pair.source_buf) or {}).loading)
util.set_buffer_text(pair.source_buf, 'value={{ "D" }}\n')
before = #requests
validations[#validations]("value=A\n")
assert(vim.wait(1000, function()
  return #requests == before + 1
end))
deliver(requests[#requests])
vim.cmd("tabnew")
user_tab, user_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
validations[#validations]("value=D\n")
assert(vim.wo[pair.source_win].diff and computed[#computed].source == 'value={{ "D" }}\n')
assert(vim.api.nvim_get_current_tabpage() == user_tab and vim.api.nvim_get_current_win() == user_win)
assert(sessions.last_profile.validation_ms > 0)

-- Render/validation errors leave editable windows intact and restore settings.
pair = open("render-error")
pair.request.callback(nil, "test rendering failure")
assert(not (view_for_buffer(pair.source_buf) or {}).loading and vim.b[pair.target_buf].snacks_scroll == nil)
assert(util.buffer_text(pair.target_buf) == "value=B\n" and vim.api.nvim_win_is_valid(pair.source_win))
assert(messages[#messages].message:find("test rendering failure", 1, true))
pair = open("validation-error", true)
deliver(pair.request)
validations[#validations](nil, "test validation failure")
assert(vim.wait(1000, function()
  return not (view_for_buffer(pair.source_buf) or {}).loading
end))
assert(not (view_for_buffer(pair.source_buf) or {}).loading and not vim.wo[pair.source_win].diff)
pair = open("validation-mismatch", true)
deliver(pair.request)
validations[#validations]("different output")
assert(vim.wait(1000, function()
  return not (view_for_buffer(pair.source_buf) or {}).loading
end))
assert(not (view_for_buffer(pair.source_buf) or {}).loading and not vim.wo[pair.target_win].diff)

source_map.trace, source_map.trace_async, cli.run, diff_hunks.compute, vim.notify =
  trace, trace_async, run, compute, notify

-- A real slow subprocess must leave the event loop responsive, not merely hide
-- a synchronous render behind a schedule(). No wall-clock speed threshold.
local slow_source, slow_target = root .. "/slow.tmpl", root .. "/slow"
vim.fn.writefile({ [[value={{ output "sh" "-c" "sleep 0.25; printf A" }}]] }, slow_source)
vim.fn.writefile({ "value=B" }, slow_target)
vim.cmd("tabnew")
local started_at = vim.uv.hrtime()
diff.open({ source = slow_source, target = slow_target })
local open_ms = (vim.uv.hrtime() - started_at) / 1e6
local slow_buf = vim.fn.bufnr(slow_source)
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
assert(vim.wait(5000, function()
  return not (view_for_buffer(slow_buf) or {}).loading
end, 10))
timer:stop()
timer:close()
assert(beats > 3, "the real renderer blocked the editor event loop")
assert(vim.api.nvim_get_current_tabpage() == user_tab and vim.api.nvim_get_current_win() == user_win)
assert(sessions.last_profile and sessions.last_profile.render_ms > 0)
print(
  ("async initial diff: race/error cases passed; slow render %.1fms, UI opened %.1fms, %d heartbeat ticks"):format(
    sessions.last_profile.render_ms,
    open_ms,
    beats
  )
)
vim.fn.delete(root, "rf")

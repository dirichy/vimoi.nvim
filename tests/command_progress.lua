local job = require("vimoi.core.job")
local util = require("vimoi.core.util")
local original_win = vim.api.nvim_get_current_win()
local original_buf = vim.api.nvim_get_current_buf()
local function wait_for(test)
  assert(vim.wait(3000, test, 5), "command did not finish")
end
local function float_count()
  return #vim.tbl_filter(function(win)
    return vim.api.nvim_win_get_config(win).relative ~= ""
  end, vim.api.nvim_list_wins())
end

-- Cheap queries run directly, without entering a modal workflow.
assert(job.run({ "printf", "quick" }, { label = "quick", text = true }).stdout == "quick")
assert(float_count() == 0 and vim.api.nvim_get_current_win() == original_win)

-- Fast background work must finish without ever opening a progress window.
local opened = 0
local window_group = vim.api.nvim_create_augroup("vimoi-test-progress", { clear = true })
vim.api.nvim_create_autocmd("WinNew", {
  group = window_group,
  callback = function()
    opened = opened + 1
  end,
})
local quick = job.run({ "printf", "quick" }, {
  label = "quick background",
  mode = "notify",
  callback = function(value)
    assert(value.code == 0 and value.stdout == "quick")
  end,
})
wait_for(function()
  return quick.finished
end)
assert(opened == 0, "fast background command flashed a window")
vim.api.nvim_del_augroup_by_id(window_group)

-- Pending notifications can finish, cancel, or become modal before the delay.
local pending = job.progress("finished early", "notify", function()
  error("finished work was cancelled")
end)
assert(float_count() == 0)
assert(pending.finish())
local cancelled = 0
local retired = job.progress("cancelled early", "notify", function()
  cancelled = cancelled + 1
end)
retired.cancel()
retired.cancel()
assert(cancelled == 1 and not retired.finish())
local promoted = job.progress("focus early", "notify", function()
  error("promoted work was cancelled")
end)
promoted.focus()
assert(float_count() == 1 and vim.api.nvim_get_current_win() == promoted.win)
assert(promoted.finish())
local elapsed = false
vim.defer_fn(function()
  elapsed = true
end, 1100)
wait_for(function()
  return elapsed
end)
assert(float_count() == 0, "retired notification appeared after its delay")

-- Waiting for an existing shared result owns only a modal UI and its subscription.
for _, mode in ipairs({ "inline", "complete", "cancel", "detach" }) do
  local finish, cancel_wait, stopped, completed, value
  util.async(function()
    completed, value = job.wait("shared render", function(done, cancel)
      finish, cancel_wait = done, cancel
      if mode == "inline" then
        done("ready")
      end
      return function(cancel_work)
        assert(stopped == nil, "wait cleaned up twice")
        stopped = cancel_work
      end
    end)
  end)
  if mode == "complete" then
    assert(completed == nil and vim.bo.filetype == "vimoi-progress")
    finish("ready")
  elseif mode == "cancel" then
    vim.fn.maparg("q", "n", false, true).callback()
  elseif mode == "detach" then
    cancel_wait(false)
  end
  assert(completed == (mode == "inline" or mode == "complete"))
  assert(stopped == (mode == "cancel"))
  assert(value == (completed and "ready" or nil))
  finish("late")
  assert(value == (completed and "ready" or nil), "late result resumed a retired wait")
  wait_for(function()
    return float_count() == 0
  end)
  assert(vim.api.nvim_get_current_win() == original_win)
end

-- An imperative caller suspends immediately; events keep running and completion
-- resumes in its original editing window, preserving all returned values.
---@type vim.SystemCompleted|VimoiCommand?
local result
local heartbeat
util.async(function()
  result = job.run({ "sh", "-c", "sleep 0.1; printf done" }, { label = "render", mode = "modal" })
  assert(vim.api.nvim_get_current_win() == original_win)
  assert(vim.api.nvim_get_current_buf() == original_buf)
end)
assert(not result and vim.bo.filetype == "vimoi-progress")
vim.schedule(function()
  heartbeat = true
end)
wait_for(function()
  return result ~= nil
end)
assert(result)
assert(heartbeat and result.code == 0 and result.stdout == "done")
assert(float_count() == 0)

-- Every way of abandoning a modal wait cancels its command. A cancelled result
-- cannot look successful even if a process races cancellation with completion.
for _, change in ipairs({ "q", "<Esc>", "<C-c>", "close", "leave", "tab", "replace" }) do
  result = nil
  util.async(function()
    result = job.run({ "sleep", "30" }, { label = "waiting", mode = "modal" })
  end)
  local win = vim.api.nvim_get_current_win()
  if change == "close" then
    vim.api.nvim_win_close(win, true)
  elseif change == "leave" then
    vim.api.nvim_set_current_win(original_win)
  elseif change == "tab" then
    vim.cmd("tabnew")
  elseif change == "replace" then
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
  else
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(change, true, false, true), "xt", false)
  end
  wait_for(function()
    return result ~= nil
  end)
  assert(result)
  assert(result.code == 130 and result.stdout == "", change)
  assert(float_count() == 0, change .. " leaked a window")
  vim.api.nvim_set_current_win(original_win)
end

-- Background work never steals focus. Global cancellation kills the process
-- group, including a password-helper-like child, and invokes its callback once.
local pid_file = vim.fn.tempname()
local completions = 0
local command = job.run({ "sh", "-c", 'sleep 30 & echo $! > "$1"; wait', "test", pid_file }, {
  label = "background render",
  mode = "notify",
  callback = function(value)
    completions = completions + 1
    result = value
  end,
})
assert(vim.api.nvim_get_current_win() == original_win and float_count() == 0)
wait_for(function()
  return float_count() == 1
end)
assert(vim.api.nvim_get_current_win() == original_win)
wait_for(function()
  return vim.uv.fs_stat(pid_file) ~= nil
end)
local child_pid = tonumber(vim.fn.readfile(pid_file)[1])
assert(child_pid and vim.uv.kill(child_pid, 0))
job.cancel()
wait_for(function()
  return completions == 1
end)
assert(result)
assert(command.cancelled and command.finished and result.code == 130)
wait_for(function()
  local stat = util.read_file("/proc/" .. child_pid .. "/stat")
  return not stat or stat:match("%) Z") ~= nil
end)
command.cancel()
assert(completions == 1 and float_count() == 0)
vim.fn.delete(pid_file)

-- Detached background jobs also terminate when Neovim exits.
local exit_job = job.run({ "sleep", "30" }, {
  label = "exit cleanup",
  mode = "notify",
  callback = function(value)
    assert(value.code == 130)
  end,
})
vim.api.nvim_exec_autocmds("VimLeavePre", { modeline = false })
wait_for(function()
  return exit_job.finished
end)
assert(exit_job.cancelled and float_count() == 0)

-- A missing executable closes its progress UI and reports a normal failure.
result = nil
util.async(function()
  result = job.run({ "/nonexistent/vimoi-test-command" }, { label = "missing", mode = "modal" })
end)
wait_for(function()
  return result ~= nil
end)
assert(result)
assert(result.code == 127 and float_count() == 0)
print("command progress: event loop, focus, cancellation, process groups and spawn failure verified")

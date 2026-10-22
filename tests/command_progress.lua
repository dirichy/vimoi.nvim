local job = require("vimoi.job")
local util = require("vimoi.util")
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
assert(vim.api.nvim_get_current_win() == original_win and float_count() == 1)
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

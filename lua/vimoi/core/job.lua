-- Process lifecycle and progress UI shared by CLI calls and render waits.
local M = {}
local util = require("vimoi.core.util")

---@class VimoiProgress
---@field win? integer Present once the progress window is shown.
---@field buf? integer
---@field active boolean
---@field mode "notify"|"modal"
---@field finish fun(): boolean Close and report whether a modal wait kept focus.
---@field cancel fun() Cancel once, then close.
---@field focus fun() Promote a notification to a focused modal wait.

---@type VimoiProgress[]
local notifications = {}

local function arrange_notifications()
  local index = 0
  for _, progress in ipairs(notifications) do
    if progress.active and progress.mode == "notify" and progress.win then
      vim.api.nvim_win_set_config(progress.win, {
        relative = "editor",
        row = 1 + index * 5,
        col = math.max(0, vim.o.columns - vim.api.nvim_win_get_width(progress.win) - 2),
      })
      index = index + 1
    end
  end
end

---Show cancellable work without exposing command input or rendered output.
---@param message string
---@param mode "notify"|"modal"
---@param on_cancel function
---@return VimoiProgress
function M.progress(message, mode, on_cancel)
  local buf, win, group, timer
  local progress = { active = true, mode = mode }
  local width = math.max(1, math.min(54, vim.o.columns - 4))
  local accepted = false
  local function close()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    if group then
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end
    for index, item in ipairs(notifications) do
      if item == progress then
        table.remove(notifications, index)
        break
      end
    end
    -- WinLeave/BufLeave callbacks run before the window transition finishes.
    vim.schedule(function()
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      arrange_notifications()
    end)
  end
  function progress.finish()
    if progress.active then
      accepted = progress.mode == "notify"
        or (win ~= nil and vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_buf(win) == buf)
      progress.active = false
      -- Successful continuation must run back in the original editing window.
      if group then
        pcall(vim.api.nvim_del_augroup_by_id, group)
      end
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      close()
    end
    return accepted
  end
  function progress.cancel()
    if not progress.active then
      return
    end
    progress.active = false
    close()
    on_cancel()
  end
  local function show()
    if not progress.active or win then
      return
    end
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "vimoi-progress"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { message, "", "q / Esc / Ctrl-C: cancel" })
    vim.bo[buf].modifiable = false
    win = vim.api.nvim_open_win(buf, progress.mode == "modal", {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      title = " vimoi ",
      width = width,
      height = 3,
      row = progress.mode == "modal" and math.max(0, math.floor((vim.o.lines - 5) / 2)) or 1,
      col = progress.mode == "modal" and math.max(0, math.floor((vim.o.columns - width) / 2))
        or math.max(0, vim.o.columns - width - 2),
    })
    progress.win, progress.buf = win, buf
    group = vim.api.nvim_create_augroup("vimoi-progress-" .. buf, { clear = true })
    for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
      vim.keymap.set("n", key, progress.cancel, { buffer = buf, desc = "Cancel chezmoi command" })
    end
    vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
      group = group,
      buffer = buf,
      callback = function()
        if progress.mode == "modal" then
          progress.cancel()
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinClosed", { group = group, pattern = tostring(win), callback = progress.cancel })
    arrange_notifications()
  end
  function progress.focus()
    if not progress.active then
      return
    end
    progress.mode = "modal"
    show()
    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - 5) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    })
    vim.api.nvim_set_current_win(win)
    arrange_notifications()
  end
  if mode == "notify" then
    notifications[#notifications + 1] = progress
    timer = vim.defer_fn(function()
      timer = nil
      show()
    end, 1000)
  else
    show()
  end
  return progress
end

---Await shared work with the same modal UI as a command, without starting a process.
---@param message string
---@param start fun(finish: function, cancel: fun(cancel_work?: boolean)): fun(cancel_work: boolean)
---@return boolean completed
---@return any ... Shared work results, absent after cancellation.
function M.wait(message, start)
  return util.await(function(done)
    local stop
    local cancel_work = true
    local progress = M.progress(message, "modal", function()
      if stop then
        stop(cancel_work)
      end
      done(false)
    end)
    stop = start(function(...)
      if not progress.active then
        return
      end
      if stop then
        stop(false)
      end
      cancel_work = false
      done(progress.finish(), ...)
    end, function(cancel)
      cancel_work = cancel ~= false
      progress.cancel()
    end)
    -- Inline completion can finish before start returns its cleanup function.
    if not progress.active then
      stop(cancel_work)
    end
  end)
end

---@class VimoiCommand
---@field label string Command purpose shown in the cancellation picker; excludes input/output.
---@field process? vim.SystemObj
---@field progress? VimoiProgress
---@field finished boolean
---@field cancelled boolean
---@field cancel fun() Cancel this caller; shared processes stop when their last caller cancels.

---@type VimoiCommand[]
local running_commands = {}

-- Slow jobs use independent process groups; explicitly stop them on editor exit.
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("vimoi-commands", { clear = true }),
  callback = function()
    for _, command in ipairs(running_commands) do
      command.cancel()
    end
  end,
})

---Cancel the only running command, or let the user select one.
function M.cancel()
  local commands = vim.tbl_filter(function(command)
    return not command.finished and not command.cancelled
  end, running_commands)
  if #commands == 1 then
    commands[1].cancel()
  elseif #commands > 1 then
    vim.ui.select(commands, {
      prompt = "Cancel chezmoi command:",
      format_item = function(command)
        return command.process and ("%s (PID %d)"):format(command.label, command.process.pid) or command.label
      end,
    }, function(command)
      if command then
        command.cancel()
      end
    end)
  end
end

---Quick commands use normal execution. Expected slow commands run asynchronously;
---a modal caller awaits in a coroutine, while callbacks use non-focused notifications.
---@overload fun(argv: string[], opts: { label: string, mode?: "notify"|"modal", stdin?: string, text?: boolean, timeout?: integer, callback: fun(result: vim.SystemCompleted) }): VimoiCommand
---@param argv string[]
---@param opts { label: string, mode?: "notify"|"modal", stdin?: string, text?: boolean, timeout?: integer, callback?: fun(result: vim.SystemCompleted) }
---@return vim.SystemCompleted|VimoiCommand
function M.run(argv, opts)
  if not opts.callback and opts.mode then
    return util.await(function(done)
      M.run(argv, vim.tbl_extend("force", opts, { callback = done }))
    end)
  end
  local system_opts = { stdin = opts.stdin, text = opts.text, timeout = opts.timeout }
  if not opts.callback then
    return vim.system(argv, system_opts):wait()
  end
  local command = { label = opts.label, finished = false, cancelled = false }
  local function kill()
    if command.process then
      if not opts.mode or vim.fn.has("win32") == 1 then
        command.process:kill(9)
      else
        -- Detached jobs own a process group: stop chezmoi, gopass and pinentry
        -- together rather than leave a child holding stdout or a password prompt.
        vim.uv.kill(-command.process.pid, 9)
      end
    end
  end
  function command.cancel()
    if command.finished or command.cancelled then
      return
    end
    command.cancelled = true
    kill()
    if command.progress then
      command.progress.cancel()
    end
  end
  if opts.mode then
    system_opts.detach = true
    command.progress = M.progress(opts.label, opts.mode, command.cancel)
    running_commands[#running_commands + 1] = command
  end
  local function finish(result)
    if command.finished then
      return
    end
    command.finished = true
    if command.progress then
      if not command.progress.finish() then
        command.cancelled = true
      end
    end
    for index, item in ipairs(running_commands) do
      if item == command then
        table.remove(running_commands, index)
        break
      end
    end
    if command.cancelled then
      result = { code = 130, signal = 0, stdout = "", stderr = "command cancelled" }
    end
    opts.callback(result)
  end
  local ok, process = pcall(vim.system, argv, system_opts, function(result)
    vim.schedule(function()
      finish(result)
    end)
  end)
  if not ok then
    vim.schedule(function()
      finish({ code = 127, signal = 0, stdout = "", stderr = tostring(process) })
    end)
  else
    command.process = process
    if command.cancelled then
      kill()
    end
  end
  return command
end

return M

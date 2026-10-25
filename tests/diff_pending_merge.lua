local waiting = dofile("tests/helpers/waiting.lua")
local render_trace = dofile("tests/helpers/trace.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})

local real_renderer = require("vimoi.render.source_map")
local requests, synchronous_renders = {}, 0
-- Hold only initial asynchronous completions; candidate validation uses the real renderer.
package.loaded["vimoi.render.source_map"] = setmetatable({
  trace_async = function(source, opts, callback)
    requests[#requests + 1] = { source = source, opts = opts, callback = callback }
  end,
  trace = function(source, opts)
    synchronous_renders = synchronous_renders + 1
    return render_trace(real_renderer, source, opts)
  end,
}, { __index = real_renderer })

local api = require("vimoi.api")
local views = require("vimoi.compare")
local cli = require("vimoi.core.cli")
local util = require("vimoi.core.util")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local original = "first=old\nkeep\nlast=old\n"
local changed = "first=new\nkeep\nlast=new\n"
local count = 0

local function open()
  for _, session in pairs(require("vimoi.compare").by_window) do
    require("vimoi.compare").close(session)
  end
  count = count + 1
  local source_path, target_path = root .. "/" .. count .. ".tmpl", root .. "/" .. count
  vim.fn.writefile(util.text_lines(original), source_path)
  vim.fn.writefile(util.text_lines(changed), target_path)
  vim.cmd("tabnew")
  local before = #requests
  views.open({ source = source_path, target = target_path })
  local source_buf = vim.api.nvim_get_current_buf()
  assert(vim.wait(1000, function()
    return #requests == before + 1
  end))
  return view_for_buffer(source_buf), requests[#requests]
end

local function deliver(request)
  local trace, err = render_trace(real_renderer, request.source, { init = request.opts.init })
  assert(trace, err)
  request.callback(trace)
end

local function assert_no_save(session)
  assert(util.read_file(vim.api.nvim_buf_get_name(session.source_buf)) == original)
  assert(util.read_file(vim.api.nvim_buf_get_name(session.target_buf)) == changed)
end

-- A source transfer holds focus in a read-only wait window, then resumes at the requested hunk.
for _, side in ipairs({ "source", "target" }) do
  local session, request = open()
  local win = session[side .. "_win"]
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { 3, 0 })
  local before = synchronous_renders
  local transfer = side == "source" and api.get_hunk or api.put_hunk
  assert(transfer() == nil and waiting())
  local waiting_win = vim.api.nvim_get_current_win()
  assert(waiting_win ~= win and vim.api.nvim_win_get_config(waiting_win).relative == "editor")
  assert(not vim.bo[vim.api.nvim_win_get_buf(waiting_win)].modifiable)
  assert(synchronous_renders == before and not session.map)
  assert(util.buffer_text(session.source_buf) == original)
  deliver(request)
  assert(not vim.api.nvim_win_is_valid(waiting_win) and vim.api.nvim_get_current_win() == win)
  assert(util.buffer_text(session.source_buf) == "first=old\nkeep\nlast=new\n")
  assert(util.buffer_text(session.target_buf) == changed)
  assert(not waiting() and synchronous_renders == before)
  assert_no_save(session)
end

-- Auto merge also waits, closes the window, and validates the changed literals locally.
do
  local session, request = open()
  local before = synchronous_renders
  api.readd()
  local waiting_win = vim.api.nvim_get_current_win()
  assert(waiting() and synchronous_renders == before)
  deliver(request)
  assert(util.buffer_text(session.source_buf) == changed)
  assert(not vim.api.nvim_win_is_valid(waiting_win))
  assert(synchronous_renders == before and not waiting())
  assert_no_save(session)
end

-- Closing, cancelling, or leaving the wait window cancels the write immediately.
for _, change in ipairs({ "q", "escape", "interrupt", "close", "leave", "tab", "replace" }) do
  local session, request = open()
  local before = synchronous_renders
  api.readd()
  local waiting_win = vim.api.nvim_get_current_win()
  if change == "q" or change == "escape" or change == "interrupt" then
    local key = change == "q" and "q"
      or vim.api.nvim_replace_termcodes(change == "escape" and "<Esc>" or "<C-c>", true, false, true)
    vim.api.nvim_feedkeys(key, "xt", false)
  elseif change == "close" then
    vim.api.nvim_win_close(waiting_win, true)
  elseif change == "leave" then
    vim.api.nvim_set_current_win(session.target_win)
  elseif change == "replace" then
    vim.api.nvim_win_set_buf(waiting_win, vim.api.nvim_create_buf(false, true))
  else
    vim.cmd("tabnew")
  end
  assert(vim.wait(1000, function()
    return not vim.api.nvim_win_is_valid(waiting_win)
  end))
  assert(not waiting())
  local active_win = vim.api.nvim_get_current_win()
  deliver(request)
  assert(util.buffer_text(session.source_buf) == original and synchronous_renders == before)
  assert(vim.api.nvim_get_current_win() == active_win)
  assert_no_save(session)
end

-- Source/target edits and context invalidation cancel the pending command.
for _, change in ipairs({ "source", "target", "context" }) do
  local session, request = open()
  api.readd()
  local before = synchronous_renders
  if change == "source" then
    util.set_buffer_text(session.source_buf, "first=manual\nkeep\nlast=old\n")
  elseif change == "target" then
    util.set_buffer_text(session.target_buf, "first=manual\nkeep\nlast=new\n")
  else
    cli.invalidate("templates")
  end
  local expected_source = util.buffer_text(session.source_buf)
  local previous_requests = #requests
  deliver(request)
  if change ~= "target" then
    assert(
      vim.wait(1000, function()
        return not waiting() or #requests == previous_requests + 1
      end),
      "initial rendering did not retry"
    )
    if waiting() then
      deliver(requests[#requests])
    end
  end
  assert(util.buffer_text(session.source_buf) == expected_source)
  assert(not waiting() and synchronous_renders == before)
  assert_no_save(session)
end

-- Closing/reopening or replacing either buffer cannot transfer a queued merge.
for _, change in ipairs({ "close", "reopen", "replace", "failure" }) do
  local session, request = open()
  api.readd()
  local waiting_win = vim.api.nvim_get_current_win()
  local before = synchronous_renders
  if change == "close" then
    vim.api.nvim_win_close(session.target_win, true)
  elseif change == "reopen" then
    vim.api.nvim_set_current_win(session.source_win)
    local previous_requests = #requests
    views.open({
      source = vim.api.nvim_buf_get_name(session.source_buf),
      target = vim.api.nvim_buf_get_name(session.target_buf),
    })
    assert(not waiting() and #requests == previous_requests)
  elseif change == "replace" then
    vim.api.nvim_win_set_buf(session.target_win, vim.api.nvim_create_buf(false, true))
  end
  if change == "failure" then
    request.callback(nil, "test rendering failure")
  else
    deliver(request)
  end
  assert(session.closed and not waiting())
  assert(
    vim.wait(1000, function()
      return not vim.api.nvim_win_is_valid(waiting_win)
    end),
    "session cleanup left the wait window open"
  )
  assert(util.buffer_text(session.source_buf) == original and synchronous_renders == before)
  assert_no_save(session)
end

vim.fn.delete(root, "rf")
print(
  "pending merge: wait window, success, key/close/leave cancellation, external changes, cleanup, and no disk writes verified"
)

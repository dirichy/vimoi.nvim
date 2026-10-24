local waiting = dofile("tests/helpers/waiting.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local sessions = require("vimoi.gotmpl.view")
local util = require("vimoi.util")

-- A real pending render is killed when re-add's focused wait is abandoned.
local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
local original = 'static=old\n{{ output "sh" "-c" "sleep 30; printf dynamic" }}\n'
vim.fn.writefile(util.text_lines(original), source)
vim.fn.writefile({ "static=new", "dynamic" }, target)
api.diff_files(source, target)
local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
assert(vim.wait(2000, function()
  return require("vimoi.gotmpl.session").get(session.source_buf).job ~= nil
end, 5))
local job = assert(require("vimoi.gotmpl.session").get(session.source_buf).job)
assert(not job.finished)
api.readd()
assert(waiting() and vim.bo.filetype == "vimoi-progress")
vim.fn.maparg("q", "n", false, true).callback()
assert(vim.wait(2000, function()
  return job.finished
end, 5))
assert(job.cancelled and session.closed and not waiting())
assert(util.buffer_text(session.source_buf) == original)
assert(util.read_file(source) == original)
assert(util.buffer_text(session.target_buf) == "static=new\ndynamic\n")
assert(not sessions.by_window[session.source_win])
vim.fn.delete(source)
vim.fn.delete(target)

-- The old 10-second deadline must not truncate a password-helper-like wait.
local result, render_error
local ticks = 0
local timer = assert(vim.uv.new_timer())
timer:start(0, 100, function()
  ticks = ticks + 1
end)
util.async(function()
  result, render_error = require("vimoi.cli").execute_template('{{ output "sh" "-c" "sleep 10.1; printf ready" }}')
end)
assert(result == nil and vim.bo.filetype == "vimoi-progress")
assert(vim.wait(15000, function()
  return result ~= nil or render_error ~= nil
end, 10))
timer:stop()
timer:close()
assert(result == "ready", render_error)
assert(ticks >= 90, "the event loop stopped while awaiting a long command")
print("real renders: cancelled re-add cannot write, waits over 10 seconds remain responsive")

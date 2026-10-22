local run_async = dofile("tests/helpers/await.lua")
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local destination = vim.env.VIMOI_TEST_DESTINATION
local wrapper = fixture .. "/chezmoi-wrapper.sh"

vim.opt.swapfile = false
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.env.VIMOI_TEST_DESTINATION = destination
require("vimoi").setup({ chezmoi_executable = wrapper })
require("vimoi.cli").invalidate()

local mapped_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, mapped_buf)
vim.bo[mapped_buf].filetype = "gotmpl"
vim.api.nvim_buf_set_lines(mapped_buf, 0, -1, false, { '{{ include "payload.txt" }}' })
vim.api.nvim_win_set_cursor(0, { 1, 13 })
assert(package.loaded["vimoi.goto"] == nil)
vim.cmd("normal gf")
assert(package.loaded["vimoi.goto"] ~= nil, "the first gf should load goto")
assert(vim.wait(2000, function()
  return vim.api.nvim_buf_get_name(0) == fixture .. "/source/payload.txt"
end))

local goto_file = require("vimoi.goto")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, buf)
vim.bo[buf].filetype = "gotmpl"
vim.treesitter.start(buf, "gotmpl")

local function resolve(line, needle)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  local col = assert(line:find(needle, 1, true)) - 1
  local paths, err = run_async(goto_file.resolve, buf, 0, col)
  assert(paths, err or line)
  return paths
end

local included = resolve('{{ include "payload.txt" }}', "payload.txt")
assert(included[1] == fixture .. "/source/payload.txt", included[1])
local parent_path = resolve('{{ include "../source/payload.txt" }}', "../source/payload.txt")
assert(parent_path[1] == included[1], parent_path[1])

local included_template = resolve('{{ includeTemplate "snippet" . }}', "snippet")
assert(included_template[1] == fixture .. "/source/.chezmoitemplates/snippet", included_template[1])

local template_action = resolve('{{ template "snippet" . }}', "snippet")
assert(template_action[1] == fixture .. "/source/.chezmoitemplates/snippet", template_action[1])

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '{{ includeTemplate "snippet" "not-a-path" }}' })
local data_col = assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]:find("not%-a%-path")) - 1
assert(run_async(goto_file.resolve, buf, 0, data_col) == nil)

local globbed = resolve('{{ glob ".plain" }}', ".plain")
assert(globbed[1] == fixture .. "/source/dot_plain", globbed[1])

local ignore_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, ignore_buf)
for _, name in ipairs({ ".chezmoiignore", ".chezmoiignore.tmpl", ".chezmoiremove", ".chezmoiremove.tmpl" }) do
  vim.api.nvim_buf_set_name(ignore_buf, "/tmp/" .. name)
  vim.api.nvim_buf_set_lines(ignore_buf, 0, -1, false, { ".plain" })
  vim.api.nvim_win_set_cursor(0, { 1, 1 })
  local ignored = assert(run_async(goto_file.resolve, ignore_buf))
  assert(ignored[1] == fixture .. "/source/dot_plain", ignored[1])
end

vim.bo[ignore_buf].filetype = "gotmpl"
assert(vim.fn.maparg("gf", "n", false, true).desc == "Open chezmoi path under cursor")

-- Native gf raises E447 when there is no filename under the cursor. The
-- enhanced mapping turns that failure into a non-disruptive warning.
local notification
local original_notify = vim.notify
---@diagnostic disable-next-line: duplicate-set-field -- Intentional notification mock.
vim.notify = function(message, level)
  notification = { message = message, level = level }
end
vim.api.nvim_buf_set_name(ignore_buf, "/tmp/ordinary-file")
vim.api.nvim_buf_set_lines(ignore_buf, 0, -1, false, { "nothing here" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
run_async(goto_file.open)
vim.notify = original_notify
assert(notification and notification.level == vim.log.levels.WARN)
assert(notification.message:find("E447", 1, true), notification.message)

assert(run_async(goto_file.resolve, buf, 0, 0) == nil)

local location_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(0, location_buf)
vim.api.nvim_buf_set_lines(location_buf, 0, -1, false, { fixture .. "/source/payload.txt:1:3" })
vim.api.nvim_win_set_cursor(0, { 1, 1 })
require("vimoi.api").goto_file({ line = true })
assert(vim.api.nvim_buf_get_name(0) == fixture .. "/source/payload.txt")
assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
assert(vim.api.nvim_win_get_cursor(0)[2] == 2)

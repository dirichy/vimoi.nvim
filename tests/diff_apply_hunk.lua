local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
local api = require("vimoi.api")
api.setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local util = require("vimoi.util")
local sessions = require("vimoi.gotmpl.session")

local function check(source_text, target_text, expected, side)
  vim.cmd("tabnew")
  local source, target = vim.fn.tempname() .. ".yaml.tmpl", vim.fn.tempname() .. ".yaml"
  vim.fn.writefile(vim.split(source_text, "\n", { plain = true }), source, "b")
  vim.fn.writefile(vim.split(target_text, "\n", { plain = true }), target, "b")
  api.diff_files(source, target)
  dofile("tests/helpers/diff.lua")()
  local session = assert(view_for_buffer(vim.fn.bufnr(source)))
  local win = session[side .. "_win"]
  vim.api.nvim_set_current_win(win)
  local hunk = side == "source" and session.projected_hunks[1] or session.hunks[1]
  local line = side == "source" and hunk.source_start_line or hunk.target_start_line
  vim.api.nvim_win_set_cursor(win, { math.max(1, line), 0 })
  -- Exercise the actual mappings, including source dp and target do.
  vim.cmd("normal " .. (side == "source" and "dp" or "do"))
  assert(
    util.buffer_text(session.target_buf) == expected,
    vim.inspect({ source_text, target_text, expected, util.buffer_text(session.target_buf) })
  )
  assert(util.buffer_text(session.source_buf) == source_text, "applying to target changed the template")
  assert(util.read_file(source) == source_text and util.read_file(target) == target_text, "apply saved a file")
  vim.api.nvim_buf_call(session.target_buf, function()
    vim.cmd("silent undo")
    -- Neovim undo restores lines; endofline is a buffer option.
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), util.text_lines(target_text)))
    vim.cmd("silent redo")
    assert(util.buffer_text(0) == expected)
  end)
  sessions.close(session)
  assert(vim.fn.maparg(side == "source" and "dp" or "do", "n") == "", "apply mapping leaked after close")
  vim.fn.delete(source)
  vim.fn.delete(target)
end

for _, side in ipairs({ "source", "target" }) do
  check('name: {{ "alice" }}\ntimeout: 10\n', "name: bob\ntimeout: 10\n", "name: alice\ntimeout: 10\n", side)
  check('name: {{ "alice" }}; timeout: 10\n', "name: alice; timeout: 20\n", "name: alice; timeout: 10\n", side)
  check('head\n{{ "new\\nline\\n" }}tail\n', "head\nold\ntail\n", "head\nnew\nline\ntail\n", side)
  check("head\n{{ if false }}hidden\n{{ end }}tail\n", "head\nextra\ntail\n", "head\ntail\n", side)
  check('head\n{{ "inserted\\n" }}tail\n', "head\ntail\n", "head\ninserted\ntail\n", side)
  check('{{ "line\\n" }}', "", "line\n", side)
  check('{{ "" }}', "extra\n", "", side)
  check('{{ "last" }}', "changed\n", "last", side)
  check('{{ "last\\n" }}', "changed", "last\n", side)
  check('{{ range (list "a" "b") }}item={{ . }}\n{{ end }}', "item=a\nitem=x\n", "item=a\nitem=b\n", side)
  check('head \n{{- " trimmed\\n" -}} \ntail\n', "head changed\ntail\n", "head trimmed\ntail\n", side)
  -- Applying one hunk must preserve a separate target modification.
  check('{{ "alice" }}\nkeep\nkeep\nold\n', "bob\nkeep\nkeep\nnew\n", "alice\nkeep\nkeep\nnew\n", side)
end

-- The narrowed write preserves extmarks on the unchanged suffix of the same line.
local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
vim.fn.writefile({ 'name={{ "alice" }}; keep=unchanged' }, source)
vim.fn.writefile({ "name=bob; keep=unchanged" }, target)
vim.cmd("tabnew")
api.diff_files(source, target)
dofile("tests/helpers/diff.lua")()
local session = assert(view_for_buffer(vim.fn.bufnr(source)))
local ns = vim.api.nvim_create_namespace("vimoi-apply-extmark")
local mark = vim.api.nvim_buf_set_extmark(session.target_buf, ns, 0, 10, {})
vim.api.nvim_set_current_win(session.target_win)
assert(api.apply_hunk())
assert(vim.deep_equal(vim.api.nvim_buf_get_extmark_by_id(session.target_buf, ns, mark, {}), { 0, 12 }))
sessions.close(session)
vim.fn.delete(source)
vim.fn.delete(target)

-- All four session maps restore pre-existing user maps on both buffers.
source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
vim.fn.writefile({ '{{ "A" }}' }, source)
vim.fn.writefile({ "B" }, target)
vim.cmd("tabnew")
local source_buf, target_buf = vim.fn.bufadd(source), vim.fn.bufadd(target)
local original_source, original_target = function() end, function() end
vim.keymap.set("n", "dp", original_source, { buffer = source_buf })
vim.keymap.set("n", "do", original_target, { buffer = target_buf })
api.diff_files(source, target)
dofile("tests/helpers/diff.lua")()
session = assert(view_for_buffer(source_buf))
sessions.close(session)
vim.api.nvim_buf_call(source_buf, function()
  assert(vim.fn.maparg("dp", "n", false, true).callback == original_source)
end)
vim.api.nvim_buf_call(target_buf, function()
  assert(vim.fn.maparg("do", "n", false, true).callback == original_target)
end)
vim.fn.delete(source)
vim.fn.delete(target)

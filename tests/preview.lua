local run_async = dofile("tests/helpers/await.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
local api = require("vimoi.api")
local util = require("vimoi.util")
local cli = require("vimoi.cli")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
local root = vim.fn.tempname() .. " chezmoi preview"
vim.fn.mkdir(root, "p")
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
local log = root .. "/commands"
local wrapper = root .. "/chezmoi"
vim.fn.writefile({
  "#!/bin/sh",
  "printf '%s\\n' \"$1\" >> " .. vim.fn.shellescape(log),
  "exec " .. vim.fn.shellescape(fixture .. "/chezmoi-wrapper.sh") .. ' "$@"',
}, wrapper)
assert(vim.uv.fs_chmod(wrapper, 493))
require("vimoi").setup({ chezmoi_executable = wrapper, diff = { validate = true } })
vim.opt.swapfile = false
local function executions()
  return #vim.tbl_filter(function(command)
    return command == "execute-template"
  end, vim.fn.readfile(log))
end
local function await(predicate)
  assert(vim.wait(5000, predicate, 10), "preview did not reach the expected state")
end
local function change(buf, text)
  util.set_buffer_text(buf, text)
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
end
local function line_number(buf, text)
  for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line == text then
      return row
    end
  end
  error("missing line: " .. text)
end

local source = root .. "/preview.lua.tmpl"
local original =
  '-- header\n{{ if true }}\nvalue = "one"\n{{ range (list 1 2) }}\nrepeat_{{ . }} = true\n{{ end }}\n{{ end }}\n-- tail\n'
vim.fn.writefile(util.text_lines(original), source)
vim.cmd("edit " .. vim.fn.fnameescape(source))
local source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local unsaved = original:gsub('"one"', '"unsaved"')
util.set_buffer_text(source_buf, unsaved)
local expected = assert(run_async(cli.execute_template, unsaved))
vim.b[source_buf].snacks_scroll = "original"
vim.cmd("VimoiPreview")
local output_buf = assert(assert(view_for_buffer(source_buf)).target_buf)
local output_win = vim.fn.bufwinid(output_buf)
assert(vim.api.nvim_get_current_win() == source_win and #vim.api.nvim_tabpage_list_wins(0) == 2)
assert((view_for_buffer(source_buf) or {}).loading and (view_for_buffer(output_buf) or {}).loading)
assert(not vim.bo[output_buf].modifiable and vim.bo[output_buf].readonly and vim.bo[output_buf].buftype == "nofile")
assert(vim.fn.maparg("do", "n", false, true).desc ~= "Get chezmoi target hunk into source template")
await(function()
  return not (view_for_buffer(source_buf) or {}).loading and util.buffer_text(output_buf) == expected
end)
assert(vim.bo[output_buf].filetype == "lua" and not vim.bo[output_buf].modified)
assert(
  not vim.wo[source_win].diff and not vim.wo[output_win].diff,
  "preview must not compare template tags as differences"
)
assert(not pcall(vim.api.nvim_buf_set_lines, output_buf, 0, 1, false, { "cannot edit" }))
assert(api.put_hunk() == nil and api.readd() == nil)
assert(util.buffer_text(source_buf) == unsaved and util.read_file(source) == original)
assert(vim.bo[source_buf].modified, "preview cleared the source's unsaved changes")
assert(
  not vim.tbl_contains(vim.fn.readfile(log), "cat"),
  "preview must not validate unsaved text against a real target"
)

-- The shared source map synchronizes source/output rows through conditions and loop expansion.
local source_line = line_number(source_buf, 'value = "unsaved"')
local output_line = line_number(output_buf, 'value = "unsaved"')
vim.api.nvim_win_set_cursor(source_win, { source_line, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
await(function()
  return vim.api.nvim_win_get_cursor(output_win)[1] == output_line
end)
vim.api.nvim_set_current_win(output_win)
vim.api.nvim_win_set_cursor(output_win, { line_number(output_buf, "repeat_2 = true"), 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = output_buf })
await(function()
  return vim.api.nvim_win_get_cursor(source_win)[1] == line_number(source_buf, "repeat_{{ . }} = true")
end)
vim.api.nvim_set_current_win(source_win)

-- Literal edits reuse the rendered structure without any process, even with diff.validate enabled.
local before = executions()
local changed = unsaved:gsub('"unsaved"', '"changed"')
change(source_buf, changed)
expected = expected:gsub('"unsaved"', '"changed"')
await(function()
  return util.buffer_text(output_buf) == expected
end)
assert(executions() == before, "a literal preview edit started an external process")
local structural = changed:gsub("if true", "if false")
expected = assert(run_async(cli.execute_template, structural))
before = executions()
change(source_buf, structural)
await(function()
  return util.buffer_text(output_buf) == expected
end)
assert(executions() == before + 1)

-- Parse and execution errors preserve the last good result, visibly stale, and remain recoverable.
for _, broken in ipairs({ "{{ if", "{{ index (list) 3 }}" }) do
  change(source_buf, broken)
  await(function()
    return (view_for_buffer(output_buf) or {}).preview_error ~= nil
  end)
  assert(util.buffer_text(output_buf) == expected and not vim.bo[output_buf].modifiable)
  change(source_buf, structural)
  await(function()
    return (view_for_buffer(output_buf) or {}).preview_error == nil
  end)
  assert(util.buffer_text(output_buf) == expected)
end

for _, case in ipairs({
  { '{{ "" }}', "" },
  { '{{ "no-eol" }}', "no-eol" },
  { '{{ "no-eol" }}\n', "no-eol\n" },
  { '{{ printf "你好\\r\\n" }}', "你好\r\n" },
  { 'before \n{{- "中" -}}\n after', "before中after" },
}) do
  change(source_buf, case[1])
  await(function()
    return util.buffer_text(output_buf) == case[2]
  end)
  assert(vim.bo[output_buf].readonly and not vim.bo[output_buf].modifiable and not vim.bo[output_buf].modified)
end

-- Repeated invocation from either side, with or without an explicit path, reuses the same pair.
vim.api.nvim_set_current_win(output_win)
api.preview({ source = source })
assert(assert(view_for_buffer(source_buf)).target_buf == output_buf and #vim.api.nvim_tabpage_list_wins(0) == 2)
vim.api.nvim_set_current_win(output_win)
api.preview()
assert(vim.api.nvim_get_current_win() == source_win and #vim.api.nvim_tabpage_list_wins(0) == 2)
vim.api.nvim_win_close(output_win, true)
assert(not vim.api.nvim_buf_is_valid(output_buf) and view_for_buffer(source_buf) == nil)
assert(vim.b[source_buf].snacks_scroll == "original")
assert(vim.fn.exists("#vimoi-diff-" .. source_buf .. "-" .. output_buf) == 0)
assert(util.read_file(source) == original)

-- Initial syntax errors can recover on edit; unnamed buffers need no managed target or source path.
vim.cmd("enew")
local unnamed = vim.api.nvim_get_current_buf()
util.set_buffer_text(unnamed, "{{ if")
api.preview()
local unnamed_output = assert(assert(view_for_buffer(unnamed)).target_buf)
await(function()
  return (view_for_buffer(unnamed_output) or {}).preview_error ~= nil and not (view_for_buffer(unnamed) or {}).loading
end)
change(unnamed, 'hello {{ "world" }}')
await(function()
  return util.buffer_text(unnamed_output) == "hello world"
    and (view_for_buffer(unnamed_output) or {}).preview_error == nil
end)
print("preview: read-only output, unsaved edits, cache reuse, mapping, errors/recovery, reuse, and cleanup verified")

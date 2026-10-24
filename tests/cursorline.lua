vim.opt.swapfile = false
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
local api, util = vim.api, require("vimoi.util")
local views, sessions = require("vimoi.api"), require("vimoi.gotmpl.session")
local source_map = require("vimoi.gotmpl.source_map")
local sync = require("vimoi.gotmpl.sync_scroll")
local await = dofile("tests/helpers/await.lua")

for _, case in ipairs({
  { '{{ "one\\ntwo\\nthree" }}\ntail\n', 1, { 1, 2, 3 } },
  -- Adjacent actions keep the original selection of one mapped block.
  { '{{ "one\\n" }}{{ "two" }}', 1, { 1 } },
  { '{{ define "rows" }}one\ntwo\nthree{{ end }}\n{{ template "rows" . }}\ntail\n', 4, { 2, 3, 4 } },
  { '{{ block "rows" . }}one\ntwo\nthree{{ end }}\ntail\n', 1, { 1, 2, 3 } },
  { "first\nsecond\nthird\n", 2, { 2 } },
  { "{{ if false }}\nignored\n{{ end }}\ntail\n", 2, {} },
  { 'value={{ "one" }}\ntail\n', 1, { 1, 2, 3 }, "value=two\nextra\nextra\ntail\n" },
}) do
  vim.cmd("tabnew")
  local source, target = api.nvim_get_current_buf(), api.nvim_create_buf(true, false)
  util.set_buffer_text(source, case[1])
  local trace = assert(await(source_map.trace, case[1]))
  util.set_buffer_text(target, case[4] or trace.output)
  views.diff_buffers(source, target)
  dofile("tests/helpers/diff.lua")()
  local session = assert(sessions.by_window[api.nvim_get_current_win()])
  local first, last = sync.target_range(session, case[2])
  local lines = {}
  for row = first, last do
    lines[#lines + 1] = row
  end
  assert(vim.deep_equal(lines, case[3]), vim.inspect({ case, lines }))
  if #lines > 0 then
    local _, line = sync.corresponding_line(session, session.source_win, case[2])
    assert(line == lines[math.floor((#lines + 1) / 2)], "expanded output did not select its middle row")
  end
  sessions.close(session)
end

-- Repeated executions retain the existing nearest-occurrence behavior,
-- including when only the target cursor changes between queries.
vim.cmd("tabnew")
local source, target = api.nvim_get_current_buf(), api.nvim_create_buf(true, false)
local loop = "{{ range list 1 2 3 }}\nitem={{ . }}\n{{ end }}tail\n"
util.set_buffer_text(source, loop)
util.set_buffer_text(target, assert(await(source_map.trace, loop)).output)
views.diff_buffers(source, target)
dofile("tests/helpers/diff.lua")()
local session = assert(sessions.by_window[api.nvim_get_current_win()])
for _, target_line in ipairs({ 6, 2, 4 }) do
  api.nvim_win_set_cursor(session.target_win, { target_line, 0 })
  local first, last = sync.target_range(session, 2)
  assert(first == target_line and last == target_line, "occurrence selection changed")
  local _, line = sync.corresponding_line(session, session.source_win, 2)
  assert(line == target_line)
end
sessions.close(session)

print(
  "cursorline: full action expansion, changed hunks, middle row, inactive text and nearest repeated occurrences verified"
)

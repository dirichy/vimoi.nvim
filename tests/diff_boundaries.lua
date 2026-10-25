local waiting = dofile("tests/helpers/waiting.lua")
---@diagnostic disable: duplicate-set-field -- Observe placement choices and reject accidental renders.
vim.opt.swapfile = false
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
local api, util = require("vimoi.api"), require("vimoi.core.util")
local sessions = require("vimoi.compare")
local source_map = require("vimoi.render.source_map")
local await = dofile("tests/helpers/await.lua")
local select, trace, trace_async = vim.ui.select, source_map.trace, source_map.trace_async
local block = "xxx\n{{- if true }}\naaa\n{{- end }}\nyyy\n"

for _, case in ipairs({
  { name = "before block", source = block, target = "xxx\nbbb\naaa\nyyy\n", row = 2, choices = 2, cancel = true },
  { name = "after block", source = block, target = "xxx\naaa\nccc\nyyy\n", row = 3, choices = 2, cancel = true },
  {
    name = "empty block",
    source = "before\n{{- if true }}\n{{- end }}\nafter\n",
    target = "before\nnew\nafter\n",
    row = 2,
    choices = 3,
    choice = 2,
  },
  {
    name = "inline prefix",
    source = "xxx = {{ if true -}} ooowww {{- end }}\nvvv\n",
    target = "xaxx = ooowww\nvvv\n",
    expected_source = "xaxx = {{ if true -}} ooowww {{- end }}\nvvv\n",
  },
  { name = "inline suffix", source = "{{ if true -}} ooo {{- end }}\nvvv\n", target = "ooouuu\nvvv\n", choices = 2 },
  { name = "inline deletion", source = "{{ if true -}} ooouuu {{- end }}\nvvv\n", target = "ooo\nvvv\n" },
  { name = "inline replacement", source = "{{ if true -}} ooouuu {{- end }}\nvvv\n", target = "ooowww\nvvv\n" },
  {
    name = "literal delimiter",
    source = "before\n",
    target = "before\naaa{{}}\n",
    row = 2,
    expected_source = 'before\naaa{{ "{{" }}}}\n',
  },
  { name = "parser text boundary", source = "a{\n", target = "a{{\n" },
}) do
  vim.cmd("tabnew")
  local source, target = vim.api.nvim_get_current_buf(), vim.api.nvim_create_buf(true, false)
  util.set_buffer_text(source, case.source)
  util.set_buffer_text(target, case.target)
  api.diff_buffers(source, target)
  dofile("tests/helpers/diff.lua")()
  local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
  vim.api.nvim_set_current_win(session.target_win)
  vim.api.nvim_win_set_cursor(0, { case.row or 1, 0 })
  local offered
  vim.ui.select = function(items, opts, callback)
    offered = items
    assert(#items == case.choices, case.name .. ": unexpected choices")
    local labels = {}
    for _, item in ipairs(items) do
      local label = opts.format_item(item)
      assert(not labels[label], case.name .. ": indistinguishable placement labels")
      labels[label] = true
    end
    callback(not case.cancel and items[case.choice or 1] or nil)
  end
  -- All these edits are inferred locally; neither render entry should run.
  source_map.trace = function()
    error(case.name .. ": synchronous render during static transfer")
  end
  source_map.trace_async = function()
    error(case.name .. ": asynchronous render during static transfer")
  end
  local result = api.put_hunk()
  source_map.trace, source_map.trace_async, vim.ui.select = trace, trace_async, select
  assert(not waiting(), case.name .. ": left a pending operation")
  assert((offered and #offered or 0) == (case.choices or 0), case.name)
  local merged = util.buffer_text(source)
  if case.cancel then
    assert(not result and merged == case.source, case.name .. ": cancelled placement changed source")
  else
    assert(result == true, case.name)
    if case.expected_source then
      assert(merged == case.expected_source, case.name .. ": " .. merged)
    end
    assert(assert(await(trace, merged)).output == case.target, case.name .. ": output changed")
  end
  assert(util.buffer_text(target) == case.target, case.name .. ": transfer changed target")
  sessions.close(session)
end
print(
  "diff boundaries: control choices, inline byte edits, literal escaping, labels, cancellation and local inference verified"
)

---@diagnostic disable: duplicate-set-field -- Observe native syntax projection and cache reuse.
local api = vim.api
local namespace = api.nvim_create_namespace("vimoi-host-highlight")
local register = api.nvim_set_decoration_provider
local provider
api.nvim_set_decoration_provider = function(ns, callbacks)
  if ns == namespace then
    provider = callbacks
  end
  return register(ns, callbacks)
end
require("vimoi.editor.host_highlight")
api.nvim_set_decoration_provider = register
local on_win = assert(provider and provider.on_win)
local add_language = vim.treesitter.language.add
vim.treesitter.language.add = function(language, ...)
  if language ~= "gotmpl" then
    return nil, "test: use native Vim syntax"
  end
  return add_language(language, ...)
end
require("vimoi").setup({ diagnostics = { enabled = false } })
local util = require("vimoi.core.util")
local sessions = require("vimoi.render")
local renderer = require("vimoi.render.source_map")
local await = dofile("tests/helpers/await.lua")
local source = api.nvim_create_buf(true, false)
api.nvim_set_current_buf(source)
local win = api.nvim_get_current_win()
local checks, bytes = 0, 0
for _, case in ipairs({
  { "lua", '{{ "local message = \\"" }}世界{{ "\\"" }}\n' },
  { "sh", 'echo {{ "\\"" }}世界{{ "\\"" }}\n' },
  { "sh", 'cat <<{{ "EOF" }}\n世界\n{{ "EOF" }}\necho done\n' },
  { "yaml", 'message: {{ "\\"A" }}\n  世界\n  {{ "B\\"" }}\nnext: true\n' },
  { "lua", '{{ if false }}ignored{{ else }}local alive = "世界"{{ end }}\n' },
  {
    "lua",
    '{{ range $i := list 1 2 }}{{ if eq $i 1 }}--{{ else }}local x="{{ end }}marker{{ if eq $i 2 }}"{{ end }}\n{{ end }}',
  },
  {
    "lua",
    "{{ range list 1 2 }}{{ if eq . 2 }}local second = 2\n{{ end }}{{ if eq . 1 }}local first = 1\n{{ end }}{{ end }}",
  },
}) do
  local filetype, text = case[1], case[2]
  util.set_buffer_text(source, text)
  require("vimoi.editor.highlight").configure_template_buffer(source, filetype)
  assert(vim.bo[source].filetype == "gotmpl" and vim.bo[source].syntax == "gotmpl")
  assert(vim.b[source].vimoi_template_language == nil)
  local trace = assert(await(renderer.trace, text, { buf = source }))
  local state = sessions.update(source, trace)
  assert(state.map)
  require("vimoi.editor.host_highlight").update(source, state.map)
  assert(vim.bo[state.buf].filetype == "", "syntax projection activated host FileType providers")
  assert(vim.bo[state.buf].syntax == filetype)

  -- Independent oracle: query native syntax in a separate complete output buffer,
  -- then walk the first literal occurrence directly, without production regions.
  local reference = api.nvim_create_buf(false, true)
  util.set_buffer_text(reference, trace.output)
  vim.bo[reference].syntax = filetype
  local expected = {}
  api.nvim_buf_call(reference, function()
    for _, part in ipairs(trace.literal_parts) do
      local occurrence = part.output_ranges[1]
      for byte = part.source.start_byte, part.source.end_byte - 1 do
        if not occurrence then
          expected[byte .. ":Comment"] = true
        else
          local output_byte = occurrence.start_byte + byte - part.source.start_byte
          local row, col = util.byte_to_position(trace.output, output_byte)
          local id = vim.fn.synID(row + 1, col + 1, 1)
          if id ~= 0 then
            expected[byte .. ":" .. vim.fn.synIDattr(id, "name")] = true
          end
        end
      end
    end
  end)
  local count = api.nvim_buf_line_count(source)
  local viewports = { { 0, count - 1 } }
  for row = count - 1, 0, -1 do
    viewports[#viewports + 1] = { row, row }
  end
  local starts = util.line_starts(text)
  for _, viewport in ipairs(viewports) do
    on_win("win", win, source, viewport[1], viewport[2])
    local first, last = starts[viewport[1] + 1], starts[viewport[2] + 2] or #text
    local actual, visible = {}, {}
    for key in pairs(expected) do
      local byte = assert(tonumber(key:match("^(%d+):")))
      if byte >= first and byte < last then
        visible[key] = true
      end
    end
    for _, mark in ipairs(api.nvim_buf_get_extmarks(source, namespace, 0, -1, { details = true })) do
      local opts = assert(mark[4])
      if not opts.invalid then
        local a = starts[mark[2] + 1] + mark[3]
        local b = starts[opts.end_row + 1] + opts.end_col
        assert(a >= first and b <= last)
        assert(
          opts.priority == (opts.hl_group == "Comment" and vim.hl.priorities.treesitter or vim.hl.priorities.syntax)
        )
        for byte = a, b - 1 do
          actual[byte .. ":" .. opts.hl_group] = true
        end
      end
    end
    assert(
      vim.deep_equal(actual, visible),
      vim.inspect({ filetype, text, viewport, actual = actual, expected = visible })
    )
    checks, bytes = checks + 1, bytes + vim.tbl_count(visible)
  end
  api.nvim_buf_delete(reference, { force = true })
end

local syn_id, queries = vim.fn.synID, 0
vim.fn.synID = function(...)
  queries = queries + 1
  return syn_id(...)
end
on_win("win", win, source, 0, 0)
queries = 0
on_win("win", win, source, 0, 0)
assert(queries == 0, "unchanged viewport repeated native syntax queries")
vim.fn.synID = syn_id
vim.treesitter.language.add = add_language
api.nvim_buf_delete(source, { force = true })
print(("rendered Vim syntax: %d viewports, %d byte/group checks verified"):format(checks, bytes))

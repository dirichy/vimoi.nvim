require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "rendered" } })
local api = vim.api
local util = require("vimoi.util")
local highlighter = require("vimoi.host_highlight")
local source_map = require("vimoi.gotmpl.source_map")
local buf = api.nvim_create_buf(true, false)
api.nvim_set_current_buf(buf)
require("vimoi.highlight").configure_template_buffer(buf, "lua")

local function update(text)
  util.set_buffer_text(buf, text)
  local result, done, err
  source_map.trace_async(text, { buf = buf }, function(value, message)
    result, done, err = value, true, message
  end)
  assert(vim.wait(5000, function()
    return done
  end, 5))
  highlighter.update(buf, assert(result, err))
end

local lines = {}
for index = 1, 200 do
  lines[index] = ('local value%d = "世界"'):format(index)
end
local original = table.concat(lines, "\n") .. "\n"
update(original)
local output
for _, candidate in ipairs(api.nvim_list_bufs()) do
  if vim.b[candidate].vimoi_highlight_source == buf then
    assert(not output, "more than one highlight buffer was created")
    output = candidate
  end
end
output = assert(output)
assert(vim.bo[output].buftype == "nofile" and not vim.bo[output].buflisted)
assert(vim.bo[output].filetype == "", "highlight buffer activated host providers")
local parser = assert(vim.treesitter.get_parser(output, "lua"))
local tree = parser:parse(true)[1]
local tick = api.nvim_buf_get_changedtick(output)
update(original)
assert(api.nvim_buf_get_changedtick(output) == tick, "identical output was rewritten")
assert(parser:parse(true)[1] == tree, "identical output rebuilt the syntax tree")

local changes = {}
api.nvim_buf_attach(output, false, {
  on_bytes = function(_, _, _, start_row, _, _, old_rows, _, old_bytes, new_rows, _, new_bytes)
    changes[#changes + 1] = { row = start_row, old_rows = old_rows, new_rows = new_rows, bytes = old_bytes + new_bytes }
  end,
})
lines[10], lines[190] = 'local value10 = "朋友"', 'local value190 = "北京"'
local modified = table.concat(lines, "\n") .. "\n"
update(modified)
assert(util.buffer_text(output) == modified)
assert(vim.treesitter.get_parser(output, "lua") == parser, "output update replaced its native parser")
assert(#changes == 2, "separate edits were merged into a full-buffer replacement")
for _, change in ipairs(changes) do
  assert(change.old_rows == 0 and change.new_rows == 0 and change.bytes < 20, vim.inspect(change))
end
assert(not parser:parse(true)[1]:root():has_error())

-- Exercise EOF, insertion, deletion and final-newline handling through the same
-- partial-edit module used by merge, while retaining the buffer and parser.
for _, text in ipairs({
  "-- heading\n" .. modified,
  modified:gsub('local value100 = "世界"\n', ""),
  'return "字"',
  'return "字符"\n',
  "",
  "return true\n",
}) do
  update(text)
  assert(util.buffer_text(output) == text)
  assert(vim.treesitter.get_parser(output, "lua") == parser)
  assert(not parser:parse(true)[1]:root():has_error())
end
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
assert(not api.nvim_buf_is_valid(output), "disabling rendered mode leaked its output buffer")
assert(#api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("vimoi-host-highlight"), 0, -1, {}) == 0)
api.nvim_buf_delete(buf, { force = true })

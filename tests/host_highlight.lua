---@diagnostic disable: duplicate-set-field -- Observe redraw callbacks and emitted decorations.
local api = vim.api
local provider
local original_provider = api.nvim_set_decoration_provider
local namespace = api.nvim_create_namespace("vimoi-host-highlight")
api.nvim_set_decoration_provider = function(ns, callbacks)
  if ns == namespace then
    provider = callbacks
  end
  return original_provider(ns, callbacks)
end
require("vimoi.host_highlight")
api.nvim_set_decoration_provider = original_provider
assert(provider)

require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "rendered" } })
local buf = api.nvim_create_buf(true, false)
api.nvim_set_current_buf(buf)
local util = require("vimoi.util")
local source_map = require("vimoi.gotmpl.source_map")
local highlighter = require("vimoi.host_highlight")
local function trace(text)
  local result, done, err
  source_map.trace_async(text, { buf = buf }, function(value, message)
    result, done, err = value, true, message
  end)
  assert(
    vim.wait(5000, function()
      return done
    end, 5),
    "trace did not complete"
  )
  return assert(result, err)
end
local source = '{{ "local message = \\"" }}世界{{ "\\"" }}\n'
util.set_buffer_text(buf, source)
require("vimoi.highlight").configure_template_buffer(buf, "lua")
local win = api.nvim_get_current_win()

local function draw(top, bottom)
  provider.on_win("win", win, buf, top or 0, bottom or api.nvim_buf_line_count(buf))
  local marks = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })) do
    if not mark[4].invalid then
      marks[#marks + 1] = { row = mark[2], col = mark[3], opts = mark[4] }
    end
  end
  return marks
end

-- Rendering also runs with diagnostics disabled, without diff/preview.
assert(
  vim.wait(5000, function()
    return #draw() > 0
  end, 10),
  "rendered highlighting did not start independently of diagnostics"
)
local marks = draw()
assert(#marks == 1 and marks[1].opts.hl_group == "@string.lua", vim.inspect(marks))
local first = assert(source:find("世界", 1, true)) - 1
assert(marks[1].row == 0 and marks[1].col == first)
assert(marks[1].opts.end_col == first + #"世界", "UTF-8 bytes or template boundaries were mapped incorrectly")
assert(marks[1].opts.priority == vim.hl.priorities.treesitter)
local gotmpl = assert(vim.treesitter.get_parser(buf, "gotmpl"))
gotmpl:parse(true)
assert(not gotmpl:children().lua, "rendered mode still parsed host injections on source")

-- The query's capture metadata, offsets and priority survive projection.
local old_query = table.concat(
  vim.tbl_map(function(path)
    return table.concat(vim.fn.readfile(path), "\n")
  end, vim.treesitter.query.get_files("lua", "highlights")),
  "\n"
)
vim.treesitter.query.set(
  "lua",
  "highlights",
  [[
  ((string_content) @string.special
    (#offset! @string.special 0 0 0 0)
    (#set! @string.special priority 123))
]]
)
highlighter.update(buf, trace(source))
marks = draw()
assert(#marks == 1 and marks[1].opts.hl_group == "@string.special.lua", vim.inspect(marks))
assert(marks[1].opts.priority == 123)
vim.treesitter.query.set("lua", "highlights", old_query)

-- Coincident captures retain native query order in a single highlight stack.
for _, case in ipairs({
  { "lua", 'local t = { key = "value" }\n', 12, 15, "@property.lua" },
  { "yaml", 'key: "value"\n', 0, 3, "@property.yaml" },
}) do
  util.set_buffer_text(buf, case[2])
  require("vimoi.highlight").configure_template_buffer(buf, case[1])
  highlighter.update(buf, trace(case[2]))
  local keys = {}
  for _, mark in ipairs(draw()) do
    if mark.row == 0 and mark.col == case[3] and mark.opts.end_col == case[4] then
      keys[#keys + 1] = mark.opts.hl_group
    end
  end
  assert(vim.deep_equal(keys, { case[5] }), vim.inspect(keys))
end
require("vimoi.highlight").configure_template_buffer(buf, "lua")

-- Skipped literals receive Comment; a repeated body uses its first execution
-- once. Template actions keep their gotmpl highlighting.
source = '{{ if false }}\nignored\n{{ end }}\n{{ range list 1 2 }}\nlocal x = "世界"\n{{ end }}\n'
util.set_buffer_text(buf, source)
highlighter.update(buf, trace(source))
marks = draw()
assert(#marks > 0)
local keys = {}
local has_inactive = false
for _, mark in ipairs(marks) do
  if mark.opts.hl_group == "Comment" then
    assert(mark.row <= 1 and mark.opts.end_row > 1, "inactive branch was not commented")
    has_inactive = true
  end
  local key = mark.row .. ":" .. mark.col .. ":" .. mark.opts.hl_group
  assert(not keys[key], "loop body received duplicate host highlights")
  keys[key] = true
end
assert(has_inactive, "inactive branch did not receive Comment highlighting")

-- Query visible ranges; retain already displayed colors at native extmark
-- positions while source or chezmoi context changes await a new render.
assert(#draw(3, 3) == 0)
local inactive_marks = draw(1, 1)
assert(#inactive_marks == 1 and inactive_marks[1].opts.hl_group == "Comment")
assert(inactive_marks[1].row == 1 and inactive_marks[1].opts.end_row == 2, "inactive mark escaped the viewport")
local previous_marks = draw(4, 4)
assert(#previous_marks > 0)
local previous_string
for _, mark in ipairs(previous_marks) do
  if mark.opts.hl_group == "@string.lua" then
    previous_string = mark.col
  end
end
assert(previous_string)
api.nvim_buf_set_text(buf, 4, 0, 4, 0, { "-- " })
marks = draw()
assert(#marks == #previous_marks, "pending render removed existing highlights")
for _, mark in ipairs(marks) do
  if mark.opts.hl_group == "@string.lua" then
    assert(mark.col == previous_string + 3, "retained highlight did not follow inserted text")
  end
end
api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "", "" })
for _, mark in ipairs(draw()) do
  assert(mark.row == 5, "retained highlight did not follow an inserted line")
end
util.set_buffer_text(buf, source)
highlighter.update(buf, trace(source))
local cli = require("vimoi.cli")
cli.context_generation = cli.context_generation + 1
assert(#draw() > 0, "context refresh removed existing highlights")

-- A host string spanning several actions is parsed as a complete construct,
-- then split into exact literal ranges without coloring those actions.
source = 'message: "{{ "A" }}\n  世界\n  {{ "B" }}"\nnext: true\n'
util.set_buffer_text(buf, source)
require("vimoi.highlight").configure_template_buffer(buf, "yaml")
local yaml_trace = trace(source)
highlighter.update(buf, yaml_trace)
marks = draw()
local has_string = false
for _, mark in ipairs(marks) do
  has_string = has_string or mark.opts.hl_group == "@string.yaml"
  local start_byte = util.line_starts(source)[mark.row + 1] + mark.col
  local end_byte = util.line_starts(source)[mark.opts.end_row + 1] + mark.opts.end_col
  for _, tag in ipairs(yaml_trace.template_tags) do
    assert(end_byte <= tag.start_byte or start_byte >= tag.end_byte, "host capture crossed a template action")
  end
end
assert(has_string, "multiline YAML string lost native host highlighting")

-- Nested branches, else and an empty loop are classified by actual execution,
-- not a syntax guess. Trimmed whitespace and action ranges stay untouched.
source = "{{ if true -}}\nactive{{ if false }}nested{{ else }}chosen{{ end }}\n{{ else }}skipped{{ end }}\n"
  .. "{{ range list }}empty{{ end }}\n"
util.set_buffer_text(buf, source)
local branch_trace = trace(source)
highlighter.update(buf, branch_trace)
local comments = {}
local starts = util.line_starts(source)
for _, mark in ipairs(draw()) do
  if mark.opts.hl_group == "Comment" then
    local first_byte = starts[mark.row + 1] + mark.col
    local last_byte = starts[mark.opts.end_row + 1] + mark.opts.end_col
    comments[#comments + 1] = source:sub(first_byte + 1, last_byte)
    for _, tag in ipairs(branch_trace.template_tags) do
      assert(last_byte <= tag.start_byte or first_byte >= tag.end_byte, "Comment crossed a template action")
    end
  end
end
assert(vim.deep_equal(comments, { "nested", "skipped", "empty" }), vim.inspect(comments))

-- A new execution replaces the old inactive ranges, and Comment does not
-- depend on the availability of a host Tree-sitter parser.
source = source:gsub("if false", "if true")
util.set_buffer_text(buf, source)
vim.b[buf].vimoi_template_language = nil
highlighter.update(buf, trace(source))
comments = {}
starts = util.line_starts(source)
for _, mark in ipairs(draw()) do
  assert(mark.opts.hl_group == "Comment")
  local first_byte = starts[mark.row + 1] + mark.col
  local last_byte = starts[mark.opts.end_row + 1] + mark.opts.end_col
  comments[#comments + 1] = source:sub(first_byte + 1, last_byte)
end
assert(vim.deep_equal(comments, { "chosen", "skipped", "empty" }), vim.inspect(comments))

require("vimoi.highlight").configure_template_buffer(buf, "lua")

-- Disabling a rendered snapshot retires its provider and keeps host injections off.
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
gotmpl:parse(true)
assert(not gotmpl:children().lua, "disabled mode enabled host injections")
assert(#draw() == 0, "disabled mode retained projected host highlighting")

-- Switching back restores native host injection and clears projections.
require("vimoi").setup({ diagnostics = { enabled = false } })
gotmpl:parse(true)
assert(gotmpl:children().lua, "disabling rendered mode did not restore host injection")
assert(#draw() == 0)
api.nvim_buf_delete(buf, { force = true })

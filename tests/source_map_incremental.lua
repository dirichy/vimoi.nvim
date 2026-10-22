local source_map = require("vimoi.gotmpl.source_map")
local util = require("vimoi.util")
local buf = vim.api.nvim_create_buf(false, true)
local checked = 0
local previous, snapshot

local function check(label)
  local source = util.buffer_text(buf)
  local actual, actual_error, visited = source_map.parse(source, buf)
  local expected, expected_error = source_map.parse(source)
  assert((actual ~= nil) == (expected ~= nil), vim.inspect({ label, source, actual_error, expected_error }))
  if actual then
    assert(
      vim.deep_equal(actual, expected),
      vim.inspect({ label = label, source = source, actual = actual, expected = expected })
    )
  end
  if previous then
    assert(vim.deep_equal(previous, snapshot), "cached syntax mutated an exported template parts")
  end
  previous, snapshot = actual, actual and vim.deepcopy(actual)
  checked = checked + 1
  return visited, actual
end

local function replace(first, last, text)
  local source = util.buffer_text(buf)
  local sr, sc = util.byte_to_position(source, first)
  local er, ec = util.byte_to_position(source, last)
  vim.api.nvim_buf_set_text(buf, sr, sc, er, ec, vim.split(text, "\n", { plain = true }))
end

local function replace_once(from, to)
  local source = util.buffer_text(buf)
  local first, last = assert(source:find(from, 1, true))
  replace(first - 1, last, to)
end

-- The syntax shape and token length are unchanged. changedtree alone may not
-- report this, so on_bytes must still refresh the literal text.
util.set_buffer_text(buf, "head\n{{ if true }}\nvalue=one\n{{ end }}\ntail")
check("initial")
replace_once("one", "two")
check("same shape and size")
replace_once("two", "中文\nnew line")
check("newlines and unicode shift later positions")
replace_once("{{ if true }}", "{{- if true -}}")
check("add both trims")
replace_once("{{ end }}", "{{- end -}}")
check("trim closing action")
replace_once("{{- if true -}}", "{{ if false }}")
check("remove trims and change branch")

-- Several edits/parses can occur before a debounced syntax refresh.
replace_once("head", "HEAD!")
vim.treesitter.get_parser(buf, "gotmpl"):parse()
replace_once("tail", "TAIL!!")
check("disjoint edits with an intermediate parse")
replace_once("{{ if false }}", "")
replace_once("{{- end -}}", "")
check("remove block and merge neighboring text nodes")
replace_once("HEAD!", '{{ if true }}{{ "{{" }}{ {{ end }}')
check("new block and literal brace nodes")
replace_once("{{ if true }}", "{{ if")
check("temporary parse error")
replace_once("{{ if", "{{ if true }}")
check("recovery after parse error")
util.set_buffer_text(buf, "")
check("empty buffer")
util.set_buffer_text(buf, "{{ if true }}{{ end }}")
check("adjacent actions")
replace_once("}}{{", "}}X{{")
check("insert into empty slot")
replace_once("}}X{{", "}}{{")
check("remove slot text")

-- A large unchanged prefix must not be traversed again for a small tail edit.
local padding = ("setting=value\n{{ if true }}nested=value{{ end }}\n"):rep(400)
util.set_buffer_text(buf, padding .. "tail=AAAA")
local full_visits = check("large initial")
replace_once("tail=AAAA", "tail=BBBB")
local local_visits = check("large local edit")
assert(full_visits > 1000 and local_visits < 100, vim.inspect({ full_visits, local_visits }))
replace_once("setting=value", "setting=changed")
replace_once("tail=BBBB", "tail=CCCC")
local disjoint_visits = check("large disjoint edit")
assert(disjoint_visits < 200, disjoint_visits)
local unchanged_visits = check("unchanged syntax")
assert(unchanged_visits == 0)
vim.api.nvim_buf_call(buf, function()
  vim.cmd("undo")
end)
check("undo")
vim.api.nvim_buf_call(buf, function()
  vim.cmd("redo")
end)
check("redo")

-- Keep the tree valid while repeatedly adding/removing nested blocks and trim.
util.set_buffer_text(buf, "prefix{{ if true }}abc{{ else }}def{{ end }}suffix")
check("valid mutations baseline")
local valid_text =
  { "", " text ", "中文\n", "{x}", '{{ "X" }}', "{{- if true -}}inside{{- end -}}", "{{/* comment */}}" }
math.randomseed(4096)
for edit = 1, 200 do
  local source = util.buffer_text(buf)
  local parts = assert(source_map.parse(source))
  local literal_part_index = math.random(#parts.template_tags)
  local start_byte = literal_part_index == 1 and 0 or parts.template_tags[literal_part_index - 1].end_byte
  replace(start_byte, parts.template_tags[literal_part_index].start_byte, valid_text[math.random(#valid_text)])
  if edit % 4 == 0 then
    vim.treesitter.get_parser(buf, "gotmpl"):parse()
  end
  check("valid mutation " .. edit)
end

-- Differential testing against a fresh string parse. Whole actions, comments,
-- braces and whitespace can split/merge text or create/remove control structure.
math.randomseed(8192)
local replacements =
  { "", "literal", "{", "}", " \t ", "\nnew\n", "中文", '{{ "X" }}', "{{ if true }}x{{ end }}", "{{/* c */}}" }
for _, case in ipairs(dofile("tests/fixtures/sentinel_cases.lua")) do
  util.set_buffer_text(buf, case[2]:gsub("\n$", ""))
  check(case[1] .. " baseline")
  for edit = 1, 12 do
    local source = util.buffer_text(buf)
    -- Preserve the last byte so EOF stays a valid nvim_buf_set_text position.
    local limit = math.max(0, #source - 1)
    local first = math.random(0, limit)
    local last = math.min(limit, first + math.random(0, 3))
    replace(first, last, replacements[math.random(#replacements)])
    if edit % 3 == 0 then
      vim.treesitter.get_parser(buf, "gotmpl"):parse()
    end
    check(case[1] .. " edit " .. edit)
  end
end

vim.api.nvim_buf_delete(buf, { force = true })
print(
  ("incremental source map: %d full-parse comparisons; node visits %d -> %d (%d for disjoint edits)"):format(
    checked,
    full_visits,
    local_visits,
    disjoint_visits
  )
)

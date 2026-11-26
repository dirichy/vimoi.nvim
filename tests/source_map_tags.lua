local map_objects = dofile("tests/helpers/map_objects.lua")
local source_map = require("vimoi.render.source_map")
local util = require("vimoi.core.util")

-- Defines and empty blocks are opaque; nonempty blocks expose their bodies.
local cases = {
  {
    "{{- if true -}}a{{ else if false }}b{{ else }}c{{- end -}}",
    { "{{- if true -}}", "{{ else if false }}", "{{ else }}", "{{- end -}}" },
  },
  {
    "{{ with . }}a{{ else with .other }}b{{ end }}",
    { "{{ with . }}", "{{ else with .other }}", "{{ end }}" },
  },
  {
    '{{ define "x" }}a{{ end }}{{ block "y" . }}b{{ end }}{{ template "x" . }}',
    { '{{ define "x" }}a{{ end }}', '{{ block "y" . }}', "{{ end }}", '{{ template "x" . }}' },
  },
  {
    '{{ define "x" }}{{ if true }}{{ "}}" }}{{ else }}other{{ end }}{{ end }}',
    { '{{ define "x" }}{{ if true }}{{ "}}" }}{{ else }}other{{ end }}{{ end }}' },
  },
  {
    '{{ block "x" . }}{{ block "y" . }}nested{{ end }}{{ end }}',
    { '{{ block "x" . }}', '{{ block "y" . }}', "{{ end }}", "{{ end }}" },
  },
  {
    "{{ range (list 1 2) }}{{ if eq . 1 }}{{ continue }}{{ end }}{{ break }}{{ end }}",
    { "{{ range (list 1 2) }}", "{{ if eq . 1 }}", "{{ continue }}", "{{ end }}", "{{ break }}", "{{ end }}" },
  },
  {
    '{{/* {{ fake }} */}}{{- /* trimmed }} */ -}}{{ printf "%s" "}}" }}{{ `{{ raw }}` }}',
    { "{{/* {{ fake }} */}}", "{{- /* trimmed }} */ -}}", '{{ printf "%s" "}}" }}', "{{ `{{ raw }}` }}" },
  },
  { '{{ printf\n "%s"\n "{{}}" }}', { '{{ printf\n "%s"\n "{{}}" }}' } },
}
for _, case in ipairs(cases) do
  local parsed = assert(source_map.parse(case[1]))
  local tags = vim.tbl_map(function(tag)
    return tag.text
  end, map_objects.tags(parsed))
  assert(vim.deep_equal(tags, case[2]), vim.inspect({ case[1], tags, case[2] }))
  assert(#map_objects.literals(parsed) == #tags + 1)
end

local buf = vim.api.nvim_create_buf(false, true)
local function parse(source)
  util.set_buffer_text(buf, source)
  local actual = assert(source_map.parse(util.buffer_text(buf), buf))
  assert(vim.deep_equal(actual, assert(source_map.parse(util.buffer_text(buf)))))
  return actual
end

-- Identical expression shape/length does not trigger a structural tree change.
local before = parse('prefix{{ printf "%s" "alpha" }}suffix')
local snapshot = vim.deepcopy(before)
local start_byte = assert(util.buffer_text(buf):find("alpha", 1, true)) - 1
vim.api.nvim_buf_set_text(buf, 0, start_byte, 0, start_byte + 5, { "omega" })
local after = assert(source_map.parse(util.buffer_text(buf), buf))
assert(vim.deep_equal(after, assert(source_map.parse(util.buffer_text(buf)))))
assert(map_objects.tags(after)[1].text == '{{ printf "%s" "omega" }}')
assert(vim.deep_equal(before, snapshot), "refresh mutated an earlier source map")

-- New tags and tag removal must invalidate the whole affected action, including internal braces.
for _, source in ipairs({
  'prefix{{/* {{ "x" }} */}}suffix',
  'prefix{{ "x" }}suffix',
  'prefix{{- "x" -}}suffix',
  'prefix{{ if true }}{{ "x" }}{{ else }}{{ end }}suffix',
  "prefixsuffix",
}) do
  parse(source)
end
local trimmed = parse('{{ "a" -}} \t\r\n {{- "b" }}')
assert(map_objects.tags(trimmed)[1].right_trim and map_objects.tags(trimmed)[2].left_trim)
assert(map_objects.literals(trimmed)[2].text == "")
assert(map_objects.literals(trimmed)[2].source_byte == map_objects.tags(trimmed)[2].start_byte)
for _, keyword in ipairs({ "define", "block" }) do
  local argument = keyword == "block" and " ." or ""
  local outer_trim = parse("before \n{{- " .. keyword .. ' "x"' .. argument .. " }} body {{ end -}}\n after")
  assert(
    map_objects.tags(outer_trim)[1].left_trim and map_objects.tags(outer_trim)[#map_objects.tags(outer_trim)].right_trim
  )
  assert(
    map_objects.literals(outer_trim)[1].text == "before"
      and map_objects.literals(outer_trim)[#map_objects.literals(outer_trim)].text == "after"
  )
  local inner_trim = parse("before \n{{ " .. keyword .. ' "x"' .. argument .. " -}} body {{- end }}\n after")
  assert(
    not map_objects.tags(inner_trim)[1].left_trim
      and not map_objects.tags(inner_trim)[#map_objects.tags(inner_trim)].right_trim
  )
  assert(
    map_objects.literals(inner_trim)[1].text == "before \n"
      and map_objects.literals(inner_trim)[#map_objects.literals(inner_trim)].text == "\n after"
  )
end
vim.api.nvim_buf_delete(buf, { force = true })
print("source map tags: control actions, expressions, comments, trim, and snapshot isolation verified")

-- Trim directives remain meaningful even when there is no whitespace to remove.
local no_space = assert(source_map.parse('a{{- "x" -}}b'))
assert(
  vim.deep_equal(
    no_space._index.source_types,
    { source_map.BOUNDARY, source_map.LITERAL, source_map.TAG, source_map.LITERAL, source_map.BOUNDARY }
  )
)
assert(no_space._index.trim_flags[3] == 3)
local adjacent = assert(source_map.parse('{{ "a" }}{{ "b" }}'))
assert(adjacent._index.source_bytes[4] == adjacent._index.source_bytes[5])
assert(source_map.tags(adjacent, adjacent._index.source_bytes[4])() == adjacent._index.source_bytes[5])

-- The same identifier reader serves parsing and on-demand merge classification.
for _, case in ipairs({
  { "{{ if .enabled }}", "if" },
  { "{{- \t range .items -}}", "range" },
  { "{{\nelse if .enabled }}", "else" },
  { "{{ with . }}", "with" },
  { "{{ end }}", "end" },
  { '{{ printf "%s" "if" }}', "printf" },
  { "{{ ifSomething }}", "ifSomething" },
  { "{{ if中文 }}", false },
  { "{{ .if }}", false },
  { '{{ "if" }}', false },
  { "{{/* if */}}", false },
  { "{{-3}}", false },
}) do
  assert(source_map.action_keyword(case[1]) == (case[2] or nil), case[1])
end

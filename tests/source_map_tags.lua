local source_map = require("vimoi.render.source_map")
local util = require("vimoi.core.util")

-- Only definitions and blocks include their bodies in a single tag.
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
    { '{{ define "x" }}a{{ end }}', '{{ block "y" . }}b{{ end }}', '{{ template "x" . }}' },
  },
  {
    '{{ define "x" }}{{ if true }}{{ "}}" }}{{ else }}other{{ end }}{{ end }}',
    { '{{ define "x" }}{{ if true }}{{ "}}" }}{{ else }}other{{ end }}{{ end }}' },
  },
  {
    '{{ block "x" . }}{{ block "y" . }}nested{{ end }}{{ end }}',
    { '{{ block "x" . }}{{ block "y" . }}nested{{ end }}{{ end }}' },
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
  end, parsed.template_tags)
  assert(vim.deep_equal(tags, case[2]), vim.inspect({ case[1], tags, case[2] }))
  assert(#parsed.literal_parts == #tags + 1)
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
assert(after.template_tags[1].text == '{{ printf "%s" "omega" }}')
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
assert(trimmed.template_tags[1].right_trim and trimmed.template_tags[2].left_trim)
assert(trimmed.literal_parts[2].text == "")
assert(trimmed.literal_parts[2].source.start_byte == trimmed.literal_parts[2].source.end_byte)
for _, keyword in ipairs({ "define", "block" }) do
  local argument = keyword == "block" and " ." or ""
  local outer_trim = parse("before \n{{- " .. keyword .. ' "x"' .. argument .. " }} body {{ end -}}\n after")
  assert(outer_trim.template_tags[1].left_trim and outer_trim.template_tags[1].right_trim)
  assert(outer_trim.literal_parts[1].text == "before" and outer_trim.literal_parts[2].text == "after")
  local inner_trim = parse("before \n{{ " .. keyword .. ' "x"' .. argument .. " -}} body {{- end }}\n after")
  assert(not inner_trim.template_tags[1].left_trim and not inner_trim.template_tags[1].right_trim)
  assert(inner_trim.literal_parts[1].text == "before \n" and inner_trim.literal_parts[2].text == "\n after")
end
vim.api.nvim_buf_delete(buf, { force = true })
print("source map tags: control actions, expressions, comments, trim, and snapshot isolation verified")

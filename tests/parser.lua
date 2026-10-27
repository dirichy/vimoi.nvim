---@diagnostic disable: duplicate-set-field -- Compare the collector with Tree-sitter and force the missing-parser branch.
local collector = require("vimoi.parser").collect_template_tags
local source_map = require("vimoi.render.source_map")
local cases = {}
for _, fixture in ipairs(dofile("tests/fixtures/sentinel_cases.lua")) do
  cases[#cases + 1] = fixture[2]
end
for _, expression in ipairs({ [[printf "%s" "}}"]], [['}']], [[`{{ fake }} /* */`]], "-3", [[printf "%s" "\\\"}}"]] }) do
  for _, opening in ipairs({ "{{", "{{- ", "{{\n" }) do
    for _, closing in ipairs({ "}}", " -}}", "\t-}}" }) do
      for _, wrapper in ipairs({
        { "前缀 ", " 后缀" },
        { '{{ define "x" }}{{ if true }}', '{{ else }}other{{ end }}{{ end }}{{ template "x" . }}' },
        { '{{ block "x" . }}{{ range . }}', "{{ end }}{{ end }}" },
      }) do
        cases[#cases + 1] = wrapper[1] .. opening .. expression .. closing .. wrapper[2]
      end
    end
  end
end
cases[#cases + 1] = '{{- define "x" -}}'
  .. string.rep("{{ if . }}", 64)
  .. "body"
  .. string.rep("{{ end }}", 64)
  .. "{{- end -}}"
cases[#cases + 1] = "{{/* \" ' ` {{ if . }} fake }} */}}{{- /* \n {{ end }} */\t-}}"
for _, left in ipairs({ "", "- ", "-\t", "-\r", "-\n" }) do
  for _, right in ipairs({ "", " -", "\t-", "\r-", "\n-" }) do
    cases[#cases + 1] = "{{" .. left .. "/* {{ fake }} */" .. right .. "}}"
  end
end
cases[#cases + 1] = [[{{ '\'' }}{{ '\\' }}{{ '\u007d' }}]]
-- Host text does not escape template delimiters, even inside quotes.
cases[#cases + 1] = [[\{{ . }} "{{ . }}" '{{ . }}' `{{ . }}`]]
cases[#cases + 1] = [[{{ printf "%s" "\\" }}{{ printf "%s" "\"}}" }}]]
local expected = {}
for index, source in ipairs(cases) do
  local native, err = source_map.parse(source)
  assert(native, source .. ": " .. tostring(err))
  local tags = {}
  for _, tag in ipairs(native.template_tags) do
    tags[#tags + 1] = {
      start_byte = tag.start_byte,
      end_byte = tag.end_byte,
      left_trim = tag.left_trim,
      right_trim = tag.right_trim,
    }
  end
  local actual, collect_error = collector(source)
  assert(actual, collect_error)
  assert(vim.deep_equal(actual, tags), vim.inspect({ source, expected = tags, actual = actual }))
  expected[index] = native
end
for _, source in ipairs({
  "{{",
  '{{ "unterminated }}',
  "{{ `raw }}",
  "{{'x",
  "{{/* x }}",
  "{{/* x */ }}",
  '{{ define "x" }}body',
  '{{ block "x" . }}{{ if true }}body{{ end }}',
}) do
  local tags, err = collector(source)
  assert(not tags and err, source)
end
-- This interface collects boundaries; it does not validate expressions or pipelines.
assert(collector("{{ if true }}"))
assert(collector("{{ end }}"))
assert(collector("{{ }}"))
assert(#assert(collector("{{ define世界 }}{{ end }}")) == 2, "Unicode identifiers must not open a definition")

local original = vim.treesitter.get_string_parser
vim.treesitter.get_string_parser = function(source, language, ...)
  if language == "gotmpl" then
    return nil
  end
  return original(source, language, ...)
end
for index, source in ipairs(cases) do
  local actual, err = source_map.parse(source)
  assert(actual, err)
  assert(vim.deep_equal(actual, expected[index]), vim.inspect({ source, actual, expected[index] }))
end
vim.treesitter.get_string_parser = original
local collect = require("vimoi.parser").collect_template_tags
require("vimoi.parser").collect_template_tags = function()
  error("a Tree-sitter syntax error must not switch to the experimental collector")
end
local invalid, err = source_map.parse("{{ if }}")
assert(not invalid and err and err:find("Tree-sitter parse errors", 1, true))
require("vimoi.parser").collect_template_tags = collect
print(("experimental tag collector: %d Tree-sitter comparisons and missing-parser layouts verified"):format(#cases))

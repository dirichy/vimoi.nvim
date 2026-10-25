local run_async = dofile("tests/helpers/await.lua")
local source_map = require("vimoi.render.source_map")

local templates = {
  "A {{- if true }}B{{ end }} C\n",
  "A {{- if false }}B{{ else }}C{{ end }} D\n",
  "{{ range (list 1 2) }}X{{ end }}Y\n",
  "before\n{{- if true }}\n{{- end }}\nafter\n",
  "{{ if false }}{{ end }}\n",
}
local replacements = { "X", " X\n", "\nX\n" }
local checked = 0

for _, source in ipairs(templates) do
  local trace = assert(run_async(source_map.trace, source))
  local positions = { [0] = true, [#source] = true }
  for _, template_tag in ipairs(trace.template_tags) do
    for _, byte in ipairs({
      template_tag.start_byte - 1,
      template_tag.start_byte,
      template_tag.end_byte,
      template_tag.end_byte + 1,
    }) do
      if byte >= 0 and byte <= #source then
        positions[byte] = true
      end
    end
  end
  for _, literal_part in ipairs(trace.literal_parts) do
    positions[literal_part.source.start_byte] = true
    positions[literal_part.source.end_byte] = true
  end
  for byte in pairs(positions) do
    for _, replacement in ipairs(replacements) do
      local candidate = source:sub(1, byte) .. replacement .. source:sub(byte + 1)
      local rebuilt = source_map.rebuild(trace, candidate)
      local predicted = rebuilt and rebuilt.output
      if predicted ~= nil then
        local actual, trace_error = run_async(source_map.trace, candidate)
        assert(actual, trace_error)
        assert(predicted == actual.output, vim.inspect({ source, byte, replacement, predicted, actual.output }))
        checked = checked + 1
      end
    end
  end
end
assert(checked >= 50, checked)

local map = require("vimoi.render.source_map")
local objects = dofile("tests/helpers/map_objects.lua")
local await = dofile("tests/helpers/await.lua")

-- Consumers retain only domain lengths and ask semantic questions. Repeated
-- text remains a one-to-many exact relation; selecting its first output is explicit.
local trace = assert(await(map.trace, "前\n{{ range until 3 }}x{{ . }}\n{{ end }}后\n"))
local published = map.mapping(trace)
assert(published.source_size == #trace.source and published.output_size == #trace.output)
assert(rawget(published, "source") == nil and rawget(published, "output") == nil)
for _, name in ipairs({
  "source_bytes",
  "source_types",
  "output_bytes",
  "output_slots",
  "output_indices",
  "source_starts",
  "output_starts",
}) do
  assert(rawget(published, name) == nil, "published map exposed " .. name)
end
local snapshot = map.snapshot(published, trace.source, trace.output)
assert(snapshot._index == published._index and published._index == trace._index)
assert(vim.deep_equal(map.rendered_regions(published), map.rendered_regions(trace)))
local repeated, all_repeated = 0, 0
for first, last, output, repeats in map.first_text_outputs(published) do
  if repeats and first < last then
    repeated = repeated + 1
    assert(trace.source:sub(first + 1, last) == trace.output:sub(output + 1, output + last - first))
  end
end
for region in map.regions(published) do
  if region.kind == "repeated" and region.source.start_byte < region.source.end_byte then
    all_repeated = all_repeated + 1
  end
end
assert(repeated > 0 and all_repeated == repeated * 3)
for _, side in ipairs({ "source", "output" }) do
  for byte = 0, #trace[side] do
    local row, col = map.byte_to_position(published, side, byte)
    assert(map.position_to_byte(published, side, row, col) == byte)
    local first, last = map.line_range(published, side, row, 1)
    assert(first <= byte and last >= byte)
  end
  assert(map.position_to_byte(published, side, -1) == nil)
  assert(map.position_to_byte(published, side, #trace[side] + 1) == nil)
end

-- Syntax is a separate query: skipped actions still exist, quoted delimiters
-- do not create tags, and trimmed whitespace remains in the raw text gaps.
for _, source in ipairs({
  "",
  "plain\n",
  '{{ "x" }}{{ "y" }}',
  "a \n{{- if false }}hidden{{ end -}} \nb",
  '{{ printf "%s" "{{ }}" }}',
  '{{ define "x" }}{{ . }}{{ end }}{{ template "x" . }}',
  '{{ block "x" . }}body{{ if true }}nested{{ end }}{{ end }}',
}) do
  local prepared = assert(map.prepare(source))
  local tags = objects.tags(prepared)
  for first = 0, #source do
    for last = first, #source do
      local expected, actual, reverse = {}, {}, {}
      for _, tag in ipairs(tags) do
        if tag.start_byte >= first and tag.end_byte <= last then
          expected[#expected + 1] = { tag.start_byte, tag.end_byte, tag.skeleton_start_byte }
        end
      end
      for a, b, skeleton in map.tags(prepared, first, last) do
        actual[#actual + 1] = { a, b, skeleton }
      end
      for a, b, skeleton in map.tags(prepared, first, last, true) do
        table.insert(reverse, 1, { a, b, skeleton })
      end
      assert(vim.deep_equal(actual, expected) and vim.deep_equal(reverse, expected))
    end
  end
  local reconstructed, index = {}, 0
  for first, last, followed_by_tag in map.text_gaps(prepared) do
    reconstructed[#reconstructed + 1] = source:sub(first + 1, last)
    index = index + 1
    assert(followed_by_tag == (index <= #tags))
    if followed_by_tag then
      reconstructed[#reconstructed + 1] = tags[index].text
    end
  end
  assert(index == #tags + 1 and table.concat(reconstructed) == source)
end
print("source map ownership, first/all outputs, coordinates and independent tag queries verified")

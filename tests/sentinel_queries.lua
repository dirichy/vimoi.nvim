local map_objects = dofile("tests/helpers/map_objects.lua")
local map = require("vimoi.render.source_map")
local await = dofile("tests/helpers/await.lua")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/source/.chezmoitemplates", "p")
vim.fn.writefile({ "external={{ .enabled }}" }, root .. "/source/.chezmoitemplates/external")
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(root .. "/source"),
  "destDir = " .. vim.json.encode(root .. "/target"),
  "[data]",
  "enabled = true",
}, root .. "/config.toml")
require("vimoi.core.cli").setup("chezmoi", root .. "/config.toml")

-- Independent linear oracle preserves interior mappings, with an explicit new EOF rule.
-- Reconstruct all ranges and search them without production query helpers.
local function expanded(trace)
  local regions, source_end, output_end = {}, 0, 0
  for _, token in ipairs(map_objects.sentinels(trace)) do
    local part = map_objects.literals(trace)[token.literal_id]
    regions[#regions + 1] = {
      source = { start_byte = source_end, end_byte = math.max(source_end, part.source_byte) },
      output_range = { start_byte = output_end, end_byte = token.output_byte },
      kind = part.source_byte < source_end and "ambiguous" or "dynamic",
    }
    regions[#regions + 1] = {
      source = { start_byte = part.source_byte, end_byte = part.source_byte + #part.text },
      output_range = { start_byte = token.output_byte, end_byte = token.output_byte + #part.text },
      kind = #part.occurrences > 1 and "repeated" or "static",
    }
    source_end, output_end = (part.source_byte + #part.text), token.output_byte + #part.text
  end
  regions[#regions + 1] = {
    source = { start_byte = source_end, end_byte = #trace.source },
    output_range = { start_byte = output_end, end_byte = #trace.output },
    kind = "dynamic",
  }
  return regions
end

local function source_span(trace, regions, byte)
  if byte == #trace.source then
    return #trace.output, #trace.output, false
  end
  for _, part in ipairs(map_objects.literals(trace)) do
    if byte >= part.source_byte and byte < (part.source_byte + #part.text) and part.occurrences[1] then
      local token = map_objects.sentinels(trace)[part.occurrences[1]]
      return token.output_byte + byte - part.source_byte, token.output_byte + #part.text, true
    end
  end
  for _, region in ipairs(regions) do
    if byte >= region.source.start_byte and byte < region.source.end_byte then
      return region.output_range.start_byte, region.output_range.end_byte, false
    end
  end
end

local function output_position(trace, regions, byte)
  if byte >= #trace.output then
    return #trace.source
  end
  local nearest, distance
  for _, part in ipairs(map_objects.literals(trace)) do
    for _, occurrence in ipairs(part.occurrences) do
      local first = map_objects.sentinels(trace)[occurrence].output_byte
      local last = first + #part.text
      if byte >= first and byte < last then
        return part.source_byte + byte - first
      end
      local candidate = math.min(math.abs(byte - first), math.abs(byte - last))
      if not distance or candidate < distance then
        nearest, distance = part.source_byte, candidate
      end
    end
  end
  for _, region in ipairs(regions) do
    local first, last = region.output_range.start_byte, region.output_range.end_byte
    if byte >= first and byte < last then
      return region.source.start_byte + math.min(byte - first, region.source.end_byte - region.source.start_byte)
    end
  end
  return nearest or 0
end

local cases = dofile("tests/fixtures/sentinel_cases.lua")
cases[#cases + 1] = {
  "nonmonotonic first executions",
  "{{ range list 1 2 }}{{ if eq . 2 }}second{{ end }}{{ if eq . 1 }}first{{ end }}{{ end }}",
}
cases[#cases + 1] = { "empty repeated output", '{{ range until 40 }}{{ "" }}{{ end }}' }
local checked = 0
for _, case in ipairs(cases) do
  local trace = assert(await(map.trace, case[2], case[3]))
  local regions = expanded(trace)
  local literals, part_index = map_objects.literals(trace), 0
  local tokens = map_objects.sentinels(trace)
  for first, last, output, repeated in map.first_text_outputs(trace) do
    part_index = part_index + 1
    local part = assert(literals[part_index])
    local occurrence = part.occurrences[1]
    assert(first == part.source_byte and last == first + #part.text)
    assert(output == (occurrence and tokens[occurrence].output_byte or nil))
    assert(repeated == (#part.occurrences > 1))
  end
  assert(part_index == #literals, "unbounded iteration dropped empty literal anchors")
  assert(vim.deep_equal(map.rendered_regions(trace), regions), case[1])
  for id, part in ipairs(map_objects.literals(trace)) do
    for _, occurrence in ipairs(part.occurrences) do
      local token = map_objects.sentinels(trace)[occurrence]
      assert(token.literal_id == id)
      assert(trace.output:sub(token.output_byte + 1, token.output_byte + #part.text) == part.text)
    end
  end
  for byte = 0, #trace.source + 1 do
    local visible, expected_visible = {}, {}
    local viewport_end = math.min(#trace.source, byte + 3)
    for first, last, output, repeated in map.first_text_outputs(trace, byte, viewport_end) do
      if first < last then
        visible[#visible + 1] = { first, last, output, repeated }
      end
    end
    for _, part in ipairs(literals) do
      if part.source_byte < viewport_end and part.source_byte + #part.text > byte and #part.text > 0 then
        local occurrence = part.occurrences[1]
        expected_visible[#expected_visible + 1] = {
          part.source_byte,
          part.source_byte + #part.text,
          occurrence and tokens[occurrence].output_byte or nil,
          #part.occurrences > 1,
        }
      end
    end
    assert(vim.deep_equal(visible, expected_visible), case[1] .. ": literal viewport projection")
    local actual = { map.source_span(trace, byte) }
    local expected = { source_span(trace, regions, byte) }
    assert(vim.deep_equal(actual, expected), vim.inspect({ case[1], "source", byte, actual, expected }))
    checked = checked + 1
  end
  for byte = 0, #trace.output + 1 do
    assert(
      map.output_position(trace, byte) == output_position(trace, regions, byte),
      vim.inspect({ case[1], "output", byte, map.output_position(trace, byte), output_position(trace, regions, byte) })
    )
    for _, last in ipairs({ byte, math.min(#trace.output, byte + 3), #trace.output }) do
      if last >= byte then
        local actual, expected = {}, {}
        for region in map.regions(trace, byte, last) do
          actual[#actual + 1] = region
        end
        for _, region in ipairs(regions) do
          if region.output_range.end_byte >= byte and region.output_range.start_byte <= last then
            expected[#expected + 1] = region
          end
        end
        assert(vim.deep_equal(actual, expected), vim.inspect({ case[1], byte, last, actual, expected }))
      end
    end
    checked = checked + 1
  end
end
print(("sentinel queries: %d byte positions and boundary windows matched the linear oracle"):format(checked))

-- Check derived indexes against exhaustive execution scans, not production helpers.
for _, case in ipairs(cases) do
  local prepared = assert(map.prepare(case[2], case[3]))
  local syntax_before = vim.deepcopy({ prepared._index.source_bytes, prepared._index.trim_flags })
  local trace = assert(await(map.trace, case[2], case[3]))
  assert(
    vim.deep_equal({ trace._index.source_bytes, trace._index.trim_flags }, syntax_before),
    "rendering changed syntax metadata"
  )
  assert(#trace._index.source_bytes == #trace._index.source_types + 1)
  assert(trace._index.source_bytes[1] == 0 and trace._index.source_bytes[#trace._index.source_bytes] == #trace.source)
  assert(
    trace._index.source_types[1] == map.BOUNDARY
      and trace._index.source_types[#trace._index.source_types] == map.BOUNDARY
  )
  assert(
    trace._index.output_slots[1] == 1
      and trace._index.output_slots[#trace._index.output_slots] == #trace._index.source_types
  )
  assert(#trace._index.output_bytes == #trace._index.output_slots)
  local firsts, counts = {}, {}
  for execution, slot in ipairs(trace._index.output_slots) do
    firsts[slot] = firsts[slot] or execution
    counts[slot] = (counts[slot] or 0) + 1
    local kind = trace._index.source_types[slot]
    assert(kind == map.LITERAL or kind == map.REPEATED or kind == map.BOUNDARY)
    assert(execution == 1 or trace._index.output_bytes[execution - 1] <= trace._index.output_bytes[execution])
  end
  for slot, kind in ipairs(trace._index.source_types) do
    assert(trace._index.source_bytes[slot] <= trace._index.source_bytes[slot + 1])
    if kind == map.LITERAL or kind == map.REPEATED or kind == map.BOUNDARY then
      assert(trace._index.output_indices[slot] == (firsts[slot] or 0))
      assert((trace._index.source_types[slot] == map.REPEATED) == ((counts[slot] or 0) > 1))
    else
      local expected
      for execution, source_slot in ipairs(trace._index.output_slots) do
        if source_slot >= slot then
          expected = execution
          break
        end
      end
      assert(trace._index.output_indices[slot] == expected)
    end
    if kind == map.TRIMMED then
      local text = trace.source:sub(trace._index.source_bytes[slot] + 1, trace._index.source_bytes[slot + 1])
      assert(#text > 0 and not text:find("[^ \t\r\n]"))
    end
  end
end
print("parallel indexes: unified anchors, duplicate starts and EOF boundaries verified")

-- Compare collectors without changing production code. Both variants retain
-- the same dirty-range cache, tag merging, trim, and template-parts export.
local util = require("vimoi.util")
local production_parse = require("vimoi.gotmpl.source_map").parse
local source_map_source = assert(util.read_file("lua/vimoi/gotmpl/source_map.lua"))
local collector_start = assert(source_map_source:find("local function collect_tags", 1, true))
local collector_end = assert(source_map_source:find("\n-- Map a position", collector_start, true))

-- Control nodes include their bodies, not just {{ if ... }}/{{ end }}.
-- Capture actual opening tokens and locate their sibling closing tokens.
-- Both variants export complete tag ranges without inspecting expressions.
local query_collector = [=[
local delimiter_query = vim.treesitter.query.parse("gotmpl", [[
  ["{{" "{{-"] @opening
]])
local util = require("vimoi.util")
local function collect_tags(node, result, range_start_byte, range_end_byte, source, buf)
  local function position(byte)
    if not buf then
      return util.byte_to_position(source, byte)
    end
    -- Use Neovim's line-offset index, not a scan of the source prefix. This
    -- keeps byte-to-query-position conversion cheap even on huge single lines.
    local first, last = 0, vim.api.nvim_buf_line_count(buf) - 1
    while first < last do
      local middle = math.ceil((first + last) / 2)
      if vim.api.nvim_buf_get_offset(buf, middle) <= byte then
        first = middle
      else
        last = middle - 1
      end
    end
    return first, byte - vim.api.nvim_buf_get_offset(buf, first)
  end
  local start_row, end_row, query_options
  if range_start_byte then
    local start_col, end_col
    start_row, start_col = position(range_start_byte)
    end_row, end_col = position(range_end_byte)
    -- Include tokens touching a zero-width boundary (at most three bytes),
    -- then filter by the byte interval. Columns matter for long inline files.
    query_options = { start_col = math.max(0, start_col - 3), end_col = end_col + 1 }
  end
  local captures, seen = 0, {}
  for _, delimiter_node in delimiter_query:iter_captures(node, source, start_row, end_row, query_options) do
    captures = captures + 1
    local opaque, ancestor = nil, delimiter_node:parent()
    while ancestor do
      if ancestor:type() == "define_action" or ancestor:type() == "block_action" then
        opaque = ancestor
      end
      ancestor = ancestor:parent()
    end
    local opening = opaque and opaque:child(0) or delimiter_node
    local _, _, start_byte = opening:start()
    local closing = opaque and opaque:child(opaque:child_count() - 1) or delimiter_node:next_sibling()
    while delimiter_is_opening[closing:type()] ~= false do
      closing = closing:next_sibling()
    end
    local _, _, end_byte = closing:end_()
    if not seen[start_byte] and (not range_start_byte or overlaps(start_byte, end_byte, range_start_byte, range_end_byte)) then
      seen[start_byte] = true
      result[#result + 1] = {
        start_byte = start_byte, end_byte = end_byte,
        left_trim = opening:type() == "{{-", right_trim = closing:type() == "-}}",
      }
    end
  end
  return captures
end
]=]

local query_source = source_map_source:sub(1, collector_start - 1)
  .. query_collector
  .. source_map_source:sub(collector_end)
local replaced_calls
query_source, replaced_calls =
  query_source:gsub("collect_tags%(root, template_tags%)", "collect_tags(root, template_tags, nil, nil, source, buf)")
assert(replaced_calls == 1, "production full collector call changed; update this benchmark")
query_source, replaced_calls = query_source:gsub(
  "collect_tags%(root, changed_tags, range.start_byte, range.end_byte%)",
  "collect_tags(root, changed_tags, range.start_byte, range.end_byte, source, buf)"
)
assert(replaced_calls == 1, "production incremental collector call changed; update this benchmark")

local function load_variant(source, label)
  -- Expose only the test copy's collector for the parser-free measurement.
  source = source:gsub("\nreturn M%s*$", "\nM.benchmark_collect = collect_tags\nreturn M\n")
  return assert(loadstring(source, "@tag-collection-benchmark-" .. label))()
end

local walker_map = load_variant(source_map_source, "walker")
local query_map = load_variant(query_source, "query")
local comparisons = 0

local function check_parts(source, buf)
  local expected, expected_error, visited_nodes = production_parse(source, buf)
  local actual, actual_error = query_map.parse(source, buf)
  assert((actual ~= nil) == (expected ~= nil), vim.inspect({ source, expected_error, actual_error }))
  if expected then
    assert(vim.deep_equal(actual, expected), vim.inspect({ source, expected, actual }))
  end
  comparisons = comparisons + 1
  return actual, actual_error, visited_nodes
end

for _, case in ipairs(dofile("tests/fixtures/sentinel_cases.lua")) do
  check_parts(case[2])
end

-- Reuse the incremental mutation suite, but compare every query result to the
-- production collector as well as the suite's cold parse/snapshot assertions.
local source_map = require("vimoi.gotmpl.source_map")
local saved_parse = source_map.parse
source_map.parse = check_parts
local mutation_ok, mutation_error = pcall(dofile, "tests/source_map_incremental.lua")
source_map.parse = saved_parse
assert(mutation_ok, mutation_error)
print(("query correctness: %d production/query tag comparisons"):format(comparisons))

local function median(values)
  table.sort(values)
  return values[math.ceil(#values / 2)]
end

local function compare(label, iterations, make_operation)
  local variants = { walker = walker_map, query = query_map }
  local operations, measurements, cleanups = {}, { walker = {}, query = {} }, {}
  for name, variant in pairs(variants) do
    operations[name], cleanups[name] = make_operation(variant)
    for _ = 1, 10 do
      operations[name]()
    end
  end
  -- Alternate batch order. Collect garbage outside the timed batches, and
  -- include normal allocation/GC within each batch instead of disabling GC.
  for round = 1, 11 do
    local order = round % 2 == 0 and { "walker", "query" } or { "query", "walker" }
    for _, name in ipairs(order) do
      collectgarbage("collect")
      local started = vim.uv.hrtime()
      for _ = 1, iterations do
        operations[name]()
      end
      measurements[name][#measurements[name] + 1] = (vim.uv.hrtime() - started) / 1e6 / iterations
    end
  end
  for _, cleanup in pairs(cleanups) do
    cleanup()
  end
  local walker_ms, query_ms = median(measurements.walker), median(measurements.query)
  print(
    ("%-36s walker=%8.4f ms  query=%8.4f ms  query/walker=%5.2fx"):format(
      label,
      walker_ms,
      query_ms,
      query_ms / walker_ms
    )
  )
end

local cases = {}
for _, count in ipairs({ 100, 400, 1600 }) do
  cases[#cases + 1] = {
    label = count .. " if blocks",
    source = ("setting=value\n{{ if true }}nested=value{{ end }}\n"):rep(count) .. "tail=AAAA",
  }
end
cases[#cases + 1] =
  { label = "100KB mostly literal", source = ("setting=value\n"):rep(7500) .. "{{ if true }}tail=AAAA{{ end }}" }
cases[#cases + 1] = {
  label = "400 inline nested blocks",
  source = ("{{- if true -}}{{ with . }}x{{ else }}y{{ end }}{{- end -}}"):rep(400) .. "tail=AAAA",
}

for _, case in ipairs(cases) do
  print(("\n%s: %d bytes"):format(case.label, #case.source))
  local parser = vim.treesitter.get_string_parser(case.source, "gotmpl")
  local root = parser:parse()[1]:root()
  assert(not root:has_error())
  compare("collector only (already parsed)", 10, function(variant)
    return function()
      variant.benchmark_collect(root, {}, nil, nil, case.source)
    end
  end)
  compare("full template parts (includes parse)", 3, function(variant)
    return function()
      assert(variant.parse(case.source))
    end
  end)
  for _, edit_kind in ipairs({ "same size", "insert/delete", "tag change" }) do
    compare("incremental " .. edit_kind, 10, function(variant)
      local buf = vim.api.nvim_create_buf(false, true)
      util.set_buffer_text(buf, case.source)
      assert(variant.parse(util.buffer_text(buf), buf))
      local original_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local row = #original_lines - 1
      local line = original_lines[#original_lines]
      local column = assert(line:find("AAAA", 1, true)) - 1
      local replacement = edit_kind == "same size" and "BBBB"
        or edit_kind == "tag change" and '{{ "B" }}'
        or "BBBB-extra"
      local alternate = false
      return function()
        local previous = alternate and replacement or "AAAA"
        local following = alternate and "AAAA" or replacement
        vim.api.nvim_buf_set_text(buf, row, column, row, column + #previous, { following })
        alternate = not alternate
        assert(variant.parse(util.buffer_text(buf), buf))
      end, function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end)
  end
end
print("tag collection benchmark: all comparisons passed")

local run_async = dofile("tests/helpers/await.lua")
local source_map = require("vimoi.gotmpl.source_map")
local diff_hunks = require("vimoi.gotmpl.diff_hunks")

local source = 'name = {{ "alice" }}\ntimeout = 10\n'
local trace, trace_error = run_async(source_map.trace, source)
assert(trace, trace_error)

local hunks = diff_hunks.compute("name = alice\ntimeout = 20\n", trace)
assert(#hunks == 1, vim.inspect(hunks))
assert(hunks[1].rendered_start_line == 2)
assert(hunks[1].rendered_line_count == 1)
assert(hunks[1].target_start_line == 2)
assert(hunks[1].target_line_count == 1)
assert(#hunks[1].source_ranges > 0)
local timeout_start = assert(source:find("timeout", 1, true)) - 1
local found_precise_static = false
for _, range in ipairs(hunks[1].source_ranges) do
  if range.kind == "static" and range.start_byte == timeout_start then
    found_precise_static = true
  end
end
assert(found_precise_static, vim.inspect(hunks))

local dynamic_source = 'name = {{ "alice" }}\n'
local dynamic_trace, dynamic_error = run_async(source_map.trace, dynamic_source)
assert(dynamic_trace, dynamic_error)
local dynamic_hunks = diff_hunks.compute("name = bob\n", dynamic_trace)
assert(#dynamic_hunks == 1)
local has_dynamic = false
for _, range in ipairs(dynamic_hunks[1].source_ranges) do
  has_dynamic = has_dynamic or range.kind == "dynamic"
end
assert(has_dynamic, vim.inspect(dynamic_hunks))

local insertion_hunks = diff_hunks.compute("name = alice\nadded = true\ntimeout = 10\n", trace)
assert(#insertion_hunks == 1)
assert(insertion_hunks[1].rendered_line_count == 0)
assert(insertion_hunks[1].target_line_count == 1)

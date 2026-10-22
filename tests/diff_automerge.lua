local run_async = dofile("tests/helpers/await.lua")
local source_map = require("vimoi.gotmpl.source_map")
local diff_hunks = require("vimoi.gotmpl.diff_hunks")
local merge_plan = require("vimoi.gotmpl.merge_plan")

local function plan(source, modified)
  local trace, trace_error = run_async(source_map.trace, source)
  assert(trace, trace_error)
  local hunks = diff_hunks.compute(modified, trace)
  return merge_plan.plan(trace, modified, hunks), trace
end

-- Multiple independent static hunks are applied from the end of the source so
-- earlier byte ranges are not shifted by later replacements.
local static_source = "first = 1\nkeep = true\nlast = 3\n"
local static_plan = plan(static_source, "first = 2\nkeep = true\nlast = 4\n")
assert(#static_plan.edits == 2, vim.inspect(static_plan))
assert(#static_plan.skipped == 0)
local static_updated = assert(merge_plan.apply_source_edits(assert(source_map.parse(static_source)), static_plan.edits))
assert(static_updated == "first = 2\nkeep = true\nlast = 4\n")
assert(assert(run_async(source_map.trace, static_updated)).output == static_updated)

-- File boundaries in an otherwise static template have one source anchor and
-- remain safe; the stricter rule applies to template-control boundaries.
local end_plan = plan("line = 1\n", "line = 1\nlast = true\n")
assert(#end_plan.edits == 1, vim.inspect(end_plan))
assert(#end_plan.skipped == 0)

-- Insertion in the interior of one static text node is unambiguous, including
-- when that text node happens to be inside an active if block.
local block_source = "before\n{{ if true }}\ninside1\ninside2\n{{ end }}\nafter\n"
local inside_plan = plan(block_source, "before\n\ninside1\nnew\ninside2\n\nafter\n")
assert(#inside_plan.edits == 1, vim.inspect(inside_plan))
assert(#inside_plan.skipped == 0)
assert(
  assert(merge_plan.apply_source_edits(assert(source_map.parse(block_source)), inside_plan.edits)):find(
    "inside1\nnew\ninside2",
    1,
    true
  )
)

-- The same rendered insertion at the end of the if body could be placed
-- either before {{ end }} or after it, so it becomes an interactive choice.
local boundary_source = "before\n{{ if true }}\ninside\n{{ end }}\nafter\n"
local boundary_plan = plan(boundary_source, "before\n\ninside\nnew\n\nafter\n")
assert(#boundary_plan.edits == 0, vim.inspect(boundary_plan))
assert(#boundary_plan.choices == 1, vim.inspect(boundary_plan))
assert(#boundary_plan.choices[1].candidates == 2, vim.inspect(boundary_plan))
assert(#boundary_plan.skipped == 0)

-- An empty block has three meaningful positions: before the if, inside it,
-- and after the end action.
local empty_source = "before\n{{- if true }}\n{{- end }}\nafter\n"
local empty_target = "before\nnew\nafter\n"
local empty_plan = plan(empty_source, empty_target)
assert(#empty_plan.choices == 1, vim.inspect(empty_plan))
assert(#empty_plan.choices[1].candidates == 3, vim.inspect(empty_plan))
local valid_empty_candidates = 0
local empty_outputs = {}
for _, candidate in ipairs(empty_plan.choices[1].candidates) do
  local candidate_source = empty_source:sub(1, candidate.start_byte)
    .. candidate.replacement
    .. empty_source:sub(candidate.end_byte + 1)
  local candidate_trace = assert(run_async(source_map.trace, candidate_source))
  empty_outputs[#empty_outputs + 1] = candidate_trace.output
  if candidate_trace.output == empty_target then
    valid_empty_candidates = valid_empty_candidates + 1
  end
end
assert(valid_empty_candidates == 3, vim.inspect(empty_outputs))

-- Inline control actions use the same finite boundary candidates. Rendering
-- validation may later reduce these to one automatic choice.
local inline_source = "before\n{{ if true }}inside{{ end }}\nafter\n"
local inline_plan = plan(inline_source, "before\nnew\ninside\nafter\n")
assert(#inline_plan.choices == 1, vim.inspect(inline_plan))
assert(#inline_plan.choices[1].candidates == 2, vim.inspect(inline_plan))
assert(#inline_plan.skipped == 0, vim.inspect(inline_plan))

-- A line-level replacement can contain a byte insertion at a control
-- boundary. Keep the inserted bytes, not the whole line, as the choice edit.
local inline_suffix_source = "{{ if true -}} ooo {{- end }}\nvvv\n"
local inline_suffix_plan = plan(inline_suffix_source, "ooouuu\nvvv\n")
assert(#inline_suffix_plan.choices == 1, vim.inspect(inline_suffix_plan))
assert(#inline_suffix_plan.skipped == 0, vim.inspect(inline_suffix_plan))
assert(inline_suffix_plan.choices[1].candidates[1].replacement == "uuu")
local valid_inline_suffix = 0
for _, candidate in ipairs(inline_suffix_plan.choices[1].candidates) do
  local candidate_source = inline_suffix_source:sub(1, candidate.start_byte)
    .. candidate.replacement
    .. inline_suffix_source:sub(candidate.end_byte + 1)
  local candidate_trace = run_async(source_map.trace, candidate_source)
  if candidate_trace and candidate_trace.output == "ooouuu\nvvv\n" then
    valid_inline_suffix = valid_inline_suffix + 1
  end
end
assert(valid_inline_suffix == 2, valid_inline_suffix)

-- Removing those bytes has one exact static source span, even though the
-- line-level hunk also projects over the adjacent end action.
local inline_delete_source = "{{ if true -}} ooouuu {{- end }}\nvvv\n"
local inline_delete_plan = plan(inline_delete_source, "ooo\nvvv\n")
assert(#inline_delete_plan.edits == 1, vim.inspect(inline_delete_plan))
assert(#inline_delete_plan.choices == 0 and #inline_delete_plan.skipped == 0, vim.inspect(inline_delete_plan))
assert(inline_delete_plan.edits[1].replacement == "")
assert(
  merge_plan.apply_source_edits(assert(source_map.parse(inline_delete_source)), inline_delete_plan.edits)
    == inline_suffix_source
)

local inline_replace_plan = plan(inline_delete_source, "ooowww\nvvv\n")
assert(#inline_replace_plan.edits == 1, vim.inspect(inline_replace_plan))
assert(#inline_replace_plan.choices == 0 and #inline_replace_plan.skipped == 0, vim.inspect(inline_replace_plan))
assert(inline_replace_plan.edits[1].replacement == "www")
assert(
  merge_plan.apply_source_edits(assert(source_map.parse(inline_delete_source)), inline_replace_plan.edits)
    == "{{ if true -}} ooowww {{- end }}\nvvv\n"
)

-- A byte insertion in static text on the same line as a template action is
-- unambiguous even though the line hunk projects across dynamic content.
local inline_prefix_source = "xxx = {{ if true -}} ooowww {{- end }}\nvvv\n"
local inline_prefix_plan = plan(inline_prefix_source, "xaxx = ooowww\nvvv\n")
assert(#inline_prefix_plan.edits == 1, vim.inspect(inline_prefix_plan))
assert(#inline_prefix_plan.choices == 0 and #inline_prefix_plan.skipped == 0, vim.inspect(inline_prefix_plan))
assert(inline_prefix_plan.edits[1].replacement == "a")
assert(
  merge_plan.apply_source_edits(assert(source_map.parse(inline_prefix_source)), inline_prefix_plan.edits)
    == "xaxx = {{ if true -}} ooowww {{- end }}\nvvv\n"
)

-- Repeated bytes may make an insertion inside a static node equivalent to
-- one at its control boundary; that must not be silently auto-merged.
local repeated_boundary_plan = plan("{{ if true -}} ooo {{- end }}\n", "oooo\n")
assert(#repeated_boundary_plan.edits == 0, vim.inspect(repeated_boundary_plan))
assert(#repeated_boundary_plan.choices == 1, vim.inspect(repeated_boundary_plan))

-- Identical rendered bytes from separate static nodes can have different
-- future behavior; deleting one of them must remain an explicit choice.
local two_branches = "{{ if true -}} a {{- end }}{{ if true -}} a {{- end }}\n"
local two_branches_plan = plan(two_branches, "a\n")
assert(#two_branches_plan.edits == 0, vim.inspect(two_branches_plan))
assert(#two_branches_plan.choices == 1, vim.inspect(two_branches_plan))
assert(#two_branches_plan.choices[1].candidates == 2, vim.inspect(two_branches_plan))

-- A safe static edit may still be merged when another hunk changes dynamic
-- output and therefore requires manual handling.
local mixed_source = 'name = {{ "alice" }}\nkeep = true\ntimeout = 10\n'
local mixed_plan = plan(mixed_source, "name = bob\nkeep = true\ntimeout = 20\n")
assert(#mixed_plan.edits == 1, vim.inspect(mixed_plan))
assert(#mixed_plan.skipped == 1)
local mixed_updated = assert(merge_plan.apply_source_edits(assert(source_map.parse(mixed_source)), mixed_plan.edits))
assert(mixed_updated:find("timeout = 20", 1, true))
assert(mixed_updated:find('{{ "alice" }}', 1, true))

-- One source segment rendered by a loop is repeated and cannot identify which
-- source occurrence a target-only edit intended to change.
local repeated_source = '{{ range (list "a" "b") }}item={{ . }};{{ end }}'
local repeated_plan = plan(repeated_source, "item=x;item=b;")
assert(#repeated_plan.edits == 0, vim.inspect(repeated_plan))
assert(#repeated_plan.skipped == 1)

-- Tag boundaries come from syntax, including multiline conditions and quoted braces.
for _, condition in ipairs({ 'eq "}}" "}}"', '\n eq "}}" "}}"\n' }) do
  local source = "before\n{{- if " .. condition .. " }}\n{{- end }}\nafter\n"
  local result = plan(source, "before\nnew\nafter\n")
  assert(#result.choices == 1 and #result.choices[1].candidates == 3, vim.inspect(result))
  for _, edit in ipairs(result.choices[1].candidates) do
    local candidate = assert(merge_plan.apply_source_edits(assert(source_map.parse(source)), { edit }))
    assert(assert(run_async(source_map.trace, candidate)).output == "before\nnew\nafter\n")
  end
end

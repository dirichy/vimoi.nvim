local run_async = dofile("tests/helpers/await.lua")
local source_map = require("vimoi.render.source_map")
local diff_hunks = require("vimoi.compare.diff_hunks")
local merge_plan = require("vimoi.merge.plan")

-- Production infers the new map. Independently render without the skeleton
-- cache here so tests detect inference errors rather than reuse their result.
local function validate_edits(trace, edits)
  local candidate, err, source_edits = merge_plan.apply_source_edits(trace, edits)
  if not candidate then
    return nil, err
  end
  local inferred, infer_error = source_map.rebuild_after_edits(trace, candidate, source_edits)
  if not inferred then
    return nil, infer_error
  end
  local actual, render_error = run_async(require("vimoi.core.cli").execute_template, candidate, { cache = false })
  assert(actual, render_error)
  assert(inferred.output == actual, vim.inspect({ candidate, inferred.output, actual }))
  return { source_text = candidate, source_edits = source_edits, trace = inferred }
end

local function plan(source, modified)
  local trace, trace_error = run_async(source_map.trace, source)
  assert(trace, trace_error)
  local hunks = diff_hunks.compute(modified, trace)
  return merge_plan.plan(trace, modified, hunks), trace, hunks
end

local function expect_automatic(source, modified, count)
  local result, trace, hunks = plan(source, modified)
  assert(#hunks == 1, vim.inspect(hunks))
  assert(#result.edits == count and #result.choices == 0 and #result.skipped == 0, vim.inspect(result))
  local candidate, error_message = validate_edits(trace, result.edits)
  assert(candidate, error_message)
  assert(candidate.trace.output == modified, vim.inspect(candidate.trace.output))
end

-- Several independent changes in one line hunk are kept as separate byte
-- edits, including insertion, replacement, and deletion across text nodes.
expect_automatic("left=abcd{{ if true }}middle=mnop{{ end }}right=wxyz\n", "left=abXcdmiddle=mnppright=wxy\n", 3)

-- No template action: multiple replacements on one line must also stay
-- independent rather than becoming one broad source edit.
expect_automatic("abc123xyz\n", "aBc124xyZ\n", 3)

-- The mapping is byte-based, but the resulting UTF-8 source must still be
-- valid and render exactly as requested.
expect_automatic("键={{ if true }}你好{{ end }}；尾=甲\n", "键=你们；尾=甲\n", 1)

-- Literal template delimiters in a static target edit must be escaped in source.
expect_automatic("before\n", "before\naaa{{}}\n", 1)
expect_automatic("a\n", "a\n{{- not an action -}}\n", 1)

-- Parser text-node boundaries are not semantic template boundaries. Braces
-- inside one literal slot merge automatically and are escaped when necessary.
expect_automatic("a{\n", "a{{\n", 1)
expect_automatic("a}\n", "a}}\n", 1)
expect_automatic("a{b}c\n", "a{{b}}c\n", 2)
-- A real action boundary is different: identical braces on opposite sides of
-- an action still have distinct source placements, so keep the explicit choice.
local brace_action_source = 'a{{ "{" }}{\n'
local brace_action = plan(brace_action_source, "a{{{\n")
assert(#brace_action.choices == 1 and #brace_action.edits == 0, vim.inspect(brace_action))
assert(#brace_action.choices[1].candidates == 2)
for _, candidate in ipairs(brace_action.choices[1].candidates) do
  local source = assert(merge_plan.apply_source_edits(assert(source_map.parse(brace_action_source)), { candidate }))
  assert(assert(run_async(source_map.trace, source)).output == "a{{{\n")
end
expect_automatic("", "first\n", 1)
expect_automatic('{{ "A" }}{{ "B" }}', "AXB", 1)

-- An ambiguous boundary edit and an independent static edit may share one
-- line hunk. The boundary remains a choice, while the other edit is retained.
local boundary_source = "prefix{{ if true -}} ooo {{- end }}suffix\n"
local boundary_plan, _, boundary_hunks = plan(boundary_source, "pRefixooousuffix\n")
assert(#boundary_hunks == 1, vim.inspect(boundary_hunks))
assert(#boundary_plan.edits == 1, vim.inspect(boundary_plan))
assert(#boundary_plan.choices == 1, vim.inspect(boundary_plan))
assert(#boundary_plan.skipped == 0, vim.inspect(boundary_plan))

-- Deterministic combinations of disjoint byte edits: pure static text must
-- always round-trip through the planner, regardless of edit order or spacing.
math.randomseed(2048)
for case = 1, 64 do
  local before = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n"
  local first = math.random(2, 8)
  local second = math.random(12, 19)
  local third = math.random(24, 32)
  local after = before:sub(1, first)
    .. "#"
    .. before:sub(first + 1, second - 1)
    .. "$"
    .. before:sub(second + 1, third - 1)
    .. before:sub(third + 1)
  local result, trace = plan(before, after)
  assert(#result.choices == 0 and #result.skipped == 0, ("case %d: %s"):format(case, vim.inspect(result)))
  local candidate, error_message = validate_edits(trace, result.edits)
  assert(candidate, error_message)
  assert(candidate.trace.output == after, case)
end

-- Deletions and simultaneous edits can create delimiters without inserting one.
expect_automatic("a{x{b\n", "a{{b\n", 1)
expect_automatic("a{\nx{b\n", "a{{b\n", 1)
expect_automatic("a{x{y{b\n", "a{{{b\n", 2)

-- A static write must never replace existing dynamic code.
do
  local trace = assert(run_async(source_map.trace, '{{ "A" }}\n'))
  local candidate, err = merge_plan.apply_source_edits(trace, {
    { start_byte = 3, end_byte = 6, replacement = 'fail "candidate failure"' },
  })
  assert(not candidate and err == "source edit crosses a template tag", err)
  assert(trace.output == "A\n")
end

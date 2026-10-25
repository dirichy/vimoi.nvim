local run_async = dofile("tests/helpers/await.lua")
local source_map = require("vimoi.render.source_map")
local merge_plan = require("vimoi.merge.plan")
local cli = require("vimoi.core.cli")
local checked, duplicate_ranges = 0, 0

local function check(trace, edits)
  local candidate, candidate_error, source_edits = merge_plan.apply_source_edits(trace, edits)
  assert(candidate, candidate_error)
  local inferred, infer_error = source_map.rebuild_after_edits(trace, candidate, source_edits)
  assert(inferred, infer_error)
  -- Bypass all trace/skeleton caches: the external renderer is an independent oracle.
  local actual, render_error = run_async(cli.execute_template, candidate, { cache = false })
  assert(actual, render_error)
  assert(inferred.output == actual, vim.inspect({ trace.source, edits, candidate, inferred.output, actual }))
  checked = checked + 1
  if checked % 5 == 0 then
    local actual_skeleton = assert(run_async(cli.execute_template, inferred.skeleton, { cache = false }))
    assert(inferred.rendered_skeleton == actual_skeleton, "inferred skeleton lost execution order or marker IDs")
    -- A later ordinary edit must reuse the inferred trace, including the new slots.
    local later_source = inferred.source .. "tail\n"
    local later = assert(source_map.rebuild(inferred, later_source))
    assert(later.output == assert(run_async(cli.execute_template, later_source, { cache = false })))
  end
  return inferred
end

-- Include empty/skipped/repeated slots, trims, dynamic output, and adjacent tags.
for _, source in ipairs({
  "a{x{y{b\n",
  'left={{ "D" }} right\n',
  "A {{- if true }} B {{- end }} C\n",
  "A {{ if false -}} B {{- else -}} C {{ end }} D\n",
  "{{ if true }}{{ end }}\n",
  "{{ if false }}{{ end }}\n",
  "{{ range (list 1 2) }} X {{ end }}Y\n",
  "{{ range (list 1 2) }}{{ if true }}\n X \n{{ end }}{{ end }}\n",
}) do
  local trace = assert(run_async(source_map.trace, source))
  local snapshot = vim.deepcopy(trace)
  local seen = {}
  for index = 1, #trace.literal_parts do
    local previous_tag, following_tag = trace.template_tags[index - 1], trace.template_tags[index]
    local first = previous_tag and previous_tag.end_byte or 0
    local last = following_tag and following_tag.start_byte or #source
    local middle = math.floor((first + last) / 2)
    local ranges = { { first, first }, { last, last }, { middle, middle }, { first, last } }
    for _, range in ipairs(ranges) do
      local key = range[1] .. ":" .. range[2]
      -- Empty and one-byte slots make several boundary positions identical.
      if seen[key] then
        duplicate_ranges = duplicate_ranges + 1
      else
        seen[key] = true
        for _, replacement in ipairs({ "", "{", "{{", "{{{", "{{{{", " {{ x }} ", "\n{\n", " \t\r\n" }) do
          check(trace, { { start_byte = range[1], end_byte = range[2], replacement = replacement } })
        end
      end
    end
  end
  assert(vim.deep_equal(trace, snapshot), "inference mutated the old mapping")
end

local literal_brace_trace = assert(run_async(source_map.trace, "a{x{y{b\n"))
check(literal_brace_trace, {
  { start_byte = 2, end_byte = 3, replacement = "" },
  { start_byte = 4, end_byte = 5, replacement = "" },
})
check(literal_brace_trace, {
  { start_byte = 2, end_byte = 3, replacement = "{" },
  { start_byte = 4, end_byte = 5, replacement = "{{" },
})
check(assert(run_async(source_map.trace, "a{\nx{b\n")), { { start_byte = 2, end_byte = 4, replacement = "" } })
-- Simultaneous escaping on both sides of existing (including identical) tags
-- must preserve old tag identities while assigning new literal marker IDs.
local source = 'left{{ "{" }}middle{{ "{" }}right\n'
local trace = assert(run_async(source_map.trace, source))
local middle = assert(source:find("middle", 1, true)) - 1
local right = assert(source:find("right", 1, true)) - 1
local inferred = check(trace, {
  { start_byte = 0, end_byte = 4, replacement = "{{left{" },
  { start_byte = middle, end_byte = middle + 6, replacement = "middle{{{" },
  { start_byte = right, end_byte = right + 5, replacement = "{{right" },
})
local following, following_error, following_edits = merge_plan.apply_source_edits(inferred, {
  {
    start_byte = assert(inferred.source:find("right", 1, true)) - 1,
    end_byte = assert(inferred.source:find("right", 1, true)) + 4,
    replacement = "new{{text",
  },
})
assert(following, following_error)
local following_trace = assert(source_map.rebuild_after_edits(inferred, following, following_edits))
assert(following_trace.output == assert(run_async(cli.execute_template, following, { cache = false })))
print(
  ("static merge inference: %d independent render comparisons; skipped %d identical edit cases"):format(
    checked + 1,
    duplicate_ranges * 8
  )
)

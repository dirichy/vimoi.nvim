local map = require("vimoi.render.source_map")
local await = dofile("tests/helpers/await.lua")
local merge = require("vimoi.merge.plan")
local diff = require("vimoi.compare.diff_hunks")

-- Each body executes once, but in reverse source order. At their touching
-- output boundary both placements must survive, ordered by source, not output.
local source = "{{ range list 1 2 }}{{ if eq . 2 }}a{{ end }}{{ if eq . 1 }}b{{ end }}{{ end }}\n"
local trace = assert(await(map.trace, source))
assert(trace.output == "ba\n")
local plan = merge.plan(trace, "bXa\n", diff.compute("bXa\n", trace))
assert(#plan.edits == 0 and #plan.skipped == 0 and #plan.choices == 1)
local candidates = plan.choices[1].candidates
assert(#candidates == 2)
local a = assert(source:find("a{{ end }}", 1, true)) - 1
local b = assert(source:find("b{{ end }}", 1, true))
assert(candidates[1].start_byte == a and candidates[2].start_byte == b)
for _, candidate in ipairs(candidates) do
  assert(candidate.start_byte == candidate.end_byte)
  assert(candidate.rendered_start_byte == 1 and candidate.rendered_end_byte == 1)
  assert(candidate.replacement == "X")
end

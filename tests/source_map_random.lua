local map = require("vimoi.render.source_map")
local cli = require("vimoi.core.cli")
local await = dofile("tests/helpers/await.lua")
local merge = require("vimoi.merge.plan")

-- Local deterministic PRNG: failures reproduce without depending on test order.
local seed, serial = 73129, 0
local function pick(n)
  seed = seed * 48271 % 2147483647
  return seed % n + 1
end
local texts = { "", "a", "中文", " \n", "aaa", "\t", "tail\n" }
local function body(depth)
  if depth == 0 then
    return texts[pick(#texts)] .. ({ '{{ "" }}', '{{ "x" }}', "{{/* comment */}}", "" })[pick(4)]
  end
  local inner, other = body(depth - 1), body(depth - 1)
  local kind = pick(6)
  if kind == 1 then
    return "{{ if " .. (pick(2) == 1 and "true" or "false") .. " }}" .. inner .. "{{ else }}" .. other .. "{{ end }}"
  elseif kind == 2 then
    return "{{ range until " .. (pick(4) - 1) .. " }}" .. inner .. "{{ end }}"
  elseif kind == 3 then
    return '{{ with "value" }}' .. inner .. "{{ else }}" .. other .. "{{ end }}"
  elseif kind == 4 then
    serial = serial + 1
    return '{{ block "b' .. serial .. '" . }}' .. inner .. "{{ end }}"
  elseif kind == 5 then
    return " \n{{- if true -}} \n" .. inner .. " \n{{- end -}} \n"
  end
  return inner .. other
end
local function render(source)
  return assert(await(cli.execute_template, source, { cache = false }))
end
local function same(a, b)
  assert(a.output == b.output)
  assert(vim.deep_equal(map.rendered_regions(a), map.rendered_regions(b)), "cached regions differ")
  local left, right = map.first_text_outputs(a), map.first_text_outputs(b)
  while true do
    local x, y = { left() }, { right() }
    assert(vim.deep_equal(x, y), "cached first outputs differ")
    if x[1] == nil then
      break
    end
  end
end
for case = 1, 48 do
  local template = body(2)
  if case % 4 == 0 then
    template = '{{ define "d" }}' .. template .. '{{ end }}{{ template "d" . }}{{ template "d" . }}'
  end
  local source = "head\n" .. template .. "\nfoot"
  local trace = assert(await(map.trace, source))
  assert(trace.output == render(source), "render equivalence case " .. case)
  local candidate = "longer中文\n" .. source:sub(6)
  local rebuilt = assert(map.rebuild(trace, candidate), "literal cache miss case " .. case)
  local fresh = assert(await(map.trace, candidate))
  same(rebuilt, fresh)
  assert(rebuilt.output == render(candidate), "rebuild render equivalence case " .. case)
  -- Escaped static merges reuse executions even though escaping adds brace tags.
  local edited, err, edits =
    merge.apply_source_edits(trace, { { start_byte = 0, end_byte = 1, replacement = "{{中文" } })
  assert(edited, err)
  local inferred = assert(map.rebuild_after_edits(trace, edited, edits))
  same(inferred, assert(await(map.trace, edited)))
  assert(inferred.output == render(edited), "merge inference case " .. case)
end
print("48 seeded random templates: direct rendering, literal rebuild and escaped merge inference agree")

local map_objects = dofile("tests/helpers/map_objects.lua")
local run_async = dofile("tests/helpers/await.lua")
local source_map = require("vimoi.render.source_map")

-- Short byte markers survive the real CLI and cannot collide with UTF-8 text,
-- including U+FFFD, noncharacters, and strings resembling the old prefix.
local utf8_source = '__VIMOI_123_456__1__VIMOI_123_456__ 中文 � \239\191\191 {{ "世界" }}'
local utf8_trace = assert(run_async(source_map.trace, utf8_source))
assert(utf8_trace.output == "__VIMOI_123_456__1__VIMOI_123_456__ 中文 � \239\191\191 世界")
assert(utf8_trace.skeleton == '\2551\255{{ "世界" }}\2552\255')
assert(utf8_trace.rendered_skeleton == "\2551\255世界\2552\255")
assert(
  map_objects.sentinels(utf8_trace)[map_objects.literals(utf8_trace)[2].occurrences[1]].output_byte
    == #utf8_trace.output
)

local reserved, reserved_error = source_map.prepare("before\255after")
assert(not reserved and reserved_error == "template contains the renderer's reserved sentinel prefix")
local unknown, unknown_error = source_map.restore(assert(source_map.prepare("text")), "\255999\255")
assert(not unknown and unknown_error == "unknown sentinel in rendered output")

-- Failed decoding must leave the prepared input reusable, including slot kinds.
local retry = assert(source_map.prepare("text"))
local untouched = vim.deepcopy(retry)
local failed, failed_error = source_map.restore(retry, "\2551\255\2551\255\255999\255")
assert(not failed and failed_error == "unknown sentinel in rendered output")
assert(vim.deep_equal(retry, untouched), "failed restore mutated its prepared input")
local retried = assert(source_map.restore(retry, "\2551\255"))
assert(retried == retry and retried.output == "text")
assert(retried._index.source_types[retried.sentinel_slots[1]] == source_map.LITERAL)
local completed = vim.deepcopy(retry)
assert(source_map.restore(retry, "ignored") == retry, "successful restoration must remain idempotent")
assert(source_map.restore(retry, nil, "late error") == retry)
assert(source_map.restore(retry, "\255999\255") == retry)
assert(vim.deep_equal(retry, completed), "a consumed input accepted another execution")

local trace, err = run_async(source_map.trace, 'hello {{ "world" }}!\n')
assert(trace, err)
assert(trace.output == "hello world!\n", vim.inspect(trace))
assert(#map_objects.literals(trace) == 2)
assert(#map_objects.tags(trace) == 1 and map_objects.tags(trace)[1].text == '{{ "world" }}')
assert(map_objects.literals(trace)[1].occurrences[1] == 1)
assert(map_objects.literals(trace)[2].occurrences[1] == 2)
assert(map_objects.literals(trace)[1].text == "hello ")
assert(map_objects.sentinels(trace)[map_objects.literals(trace)[1].occurrences[1]].output_byte == 0)
assert(
  (
    map_objects.sentinels(trace)[map_objects.literals(trace)[1].occurrences[1]].output_byte
    + #map_objects.literals(trace)[1].text
  ) == 6
)
assert(map_objects.literals(trace)[2].text == "!\n")
assert(map_objects.sentinels(trace)[map_objects.literals(trace)[2].occurrences[1]].output_byte == 11)
assert(
  (
    map_objects.sentinels(trace)[map_objects.literals(trace)[2].occurrences[1]].output_byte
    + #map_objects.literals(trace)[2].text
  ) == 13
)

local loop, loop_err = run_async(source_map.trace, '{{ range (list "a" "b") }}item={{ . }};{{ end }}')
assert(loop, loop_err)
assert(loop.output == "item=a;item=b;")
assert(#map_objects.literals(loop) == 4)
assert(#map_objects.literals(loop)[2].occurrences == 2)
assert(#map_objects.literals(loop)[3].occurrences == 2)

local trimmed, trim_err = run_async(source_map.trace, 'before \n{{- "x" -}}\n after')
assert(trimmed, trim_err)
assert(trimmed.output == "beforexafter", vim.inspect(trimmed))
assert(#map_objects.literals(trimmed) == 2)
assert(map_objects.literals(trimmed)[1].text == "before")
assert((map_objects.literals(trimmed)[1].source_byte + #map_objects.literals(trimmed)[1].text) == 6)
assert(map_objects.sentinels(trimmed)[map_objects.literals(trimmed)[1].occurrences[1]].output_byte == 0)
assert(
  (
    map_objects.sentinels(trimmed)[map_objects.literals(trimmed)[1].occurrences[1]].output_byte
    + #map_objects.literals(trimmed)[1].text
  ) == 6
)
assert(map_objects.literals(trimmed)[2].text == "after")
assert(map_objects.literals(trimmed)[2].source_byte == #trimmed.source - #"after")
assert(map_objects.sentinels(trimmed)[map_objects.literals(trimmed)[2].occurrences[1]].output_byte == 7)
assert(
  (
    map_objects.sentinels(trimmed)[map_objects.literals(trimmed)[2].occurrences[1]].output_byte
    + #map_objects.literals(trimmed)[2].text
  ) == 12
)

local left_trimmed, left_trim_err = run_async(source_map.trace, 'a \n{{- "b" }} c')
assert(left_trimmed, left_trim_err)
assert(left_trimmed.output == "ab c")

local right_trimmed, right_trim_err = run_async(source_map.trace, 'a {{ "b" -}}\n c')
assert(right_trimmed, right_trim_err)
assert(right_trimmed.output == "a bc")

local whitespace_only, whitespace_err = run_async(source_map.trace, '{{ "a" -}} \n {{- "b" }}')
assert(whitespace_only, whitespace_err)
assert(whitespace_only.output == "ab")
assert(#map_objects.literals(whitespace_only) == 3)
assert(map_objects.literals(whitespace_only)[2].text == "")
assert(map_objects.literals(whitespace_only)[2].source_byte == map_objects.tags(whitespace_only)[2].start_byte)
assert(map_objects.sentinels(whitespace_only)[map_objects.literals(whitespace_only)[2].occurrences[1]].output_byte == 1)
assert(
  (
    map_objects.sentinels(whitespace_only)[map_objects.literals(whitespace_only)[2].occurrences[1]].output_byte
    + #map_objects.literals(whitespace_only)[2].text
  ) == 1
)

local init_template, init_error =
  run_async(source_map.trace, '{{ promptChoiceOnce . "vimoi_test" "Choose one" (list "a" "b") "a" }}', { init = true })
assert(init_template, init_error)
assert(init_template.output ~= "")

local async_done = false
local async_trace, async_error
source_map.trace_async("async = true\n", {}, function(result, trace_error)
  async_trace = result
  async_error = trace_error
  async_done = true
end)
assert(
  vim.wait(1000, function()
    return async_done
  end),
  "async sentinel render timed out"
)
assert(async_trace, async_error)
assert(async_trace.output == "async = true\n")

local invalid_template = "{{ chezmoiNvimMissingFunction }}"
local failed_trace, render_error = run_async(source_map.trace, invalid_template)
assert(failed_trace == nil and render_error and render_error:find("not defined", 1, true))
local async_render_error
source_map.trace_async(invalid_template, {}, function(result, trace_error)
  assert(result == nil and not vim.in_fast_event())
  async_render_error = trace_error
end)
assert(vim.wait(1000, function()
  return async_render_error ~= nil
end))
assert(async_render_error == render_error)

-- Every gap between actions has an execution marker, including empty
-- branches with no static text node to carry the older S/E sentinels.
local empty_true = assert(run_async(source_map.trace, "{{ if true }}{{ end }}"))
local empty_false = assert(run_async(source_map.trace, "{{ if false }}{{ end }}"))
assert(#map_objects.literals(empty_true) == 3 and #map_objects.literals(empty_true)[2].occurrences == 1)
assert(#map_objects.literals(empty_false) == 3 and #map_objects.literals(empty_false)[2].occurrences == 0)
assert(assert(source_map.rebuild(empty_true, "{{ if true }}X{{ end }}")).output == "X")
assert(assert(source_map.rebuild(empty_false, "{{ if false }}X{{ end }}")).output == "")

local else_trace = assert(run_async(source_map.trace, "{{ if false }}{{ else }}{{ end }}"))
assert(#map_objects.literals(else_trace) == 4)
assert(#map_objects.literals(else_trace)[2].occurrences == 0 and #map_objects.literals(else_trace)[3].occurrences == 1)
assert(assert(source_map.rebuild(else_trace, "{{ if false }}{{ else }}X{{ end }}")).output == "X")
local else_if_trace = assert(run_async(source_map.trace, "{{ if false }}{{ else if true }}{{ end }}"))
assert(
  #map_objects.literals(else_if_trace)[2].occurrences == 0 and #map_objects.literals(else_if_trace)[3].occurrences == 1
)
assert(assert(source_map.rebuild(else_if_trace, "{{ if false }}{{ else if true }}X{{ end }}")).output == "X")

local empty_range = assert(run_async(source_map.trace, "{{ range (list) }}{{ end }}"))
local double_range = assert(run_async(source_map.trace, "{{ range (list 1 2) }}{{ end }}"))
assert(#map_objects.literals(empty_range)[2].occurrences == 0)
assert(#map_objects.literals(double_range)[2].occurrences == 2)
assert(assert(source_map.rebuild(double_range, "{{ range (list 1 2) }}X{{ end }}")).output == "XX")

local trim_source = "before\n{{- if true }}\n{{- end }}\nafter\n"
local trim_trace = assert(run_async(source_map.trace, trim_source))
assert(trim_trace.output == "before\nafter\n")
assert(
  assert(source_map.rebuild(trim_trace, "before\nnew\n{{- if true }}\n{{- end }}\nafter\n")).output
    == "before\nnew\nafter\n"
)

-- A new template action is not a literal change and must not be guessed.
assert(source_map.rebuild(assert(run_async(source_map.trace, "A\n")), 'A{{ "B" }}\n') == nil)

-- Gap probes must never change the template's actual output, including
-- adjacent actions, whitespace-only gaps, comments, and nested branches.
for _, template in ipairs({
  "{{ if true }}{{ end }}",
  "{{ if false }}{{ else }}{{ end }}",
  "{{ if true -}}  {{- end }}",
  "A {{- if true -}}  B {{- else -}} C {{- end -}} D",
  '{{ range (list "a" "b") }}{{ if true }}{{ . }}{{ end }}{{ end }}',
  "{{ if true }}{{/* comment */}}{{ end }}",
  '{{ define "piece" }}X{{ end }}{{ template "piece" . }}',
  "{{ range (list 1 2) }}{{ if eq . 2 }}second{{ end }}{{ if eq . 1 }}first{{ end }}{{ end }}",
}) do
  local direct = vim.system({ "chezmoi", "execute-template" }, { stdin = template, text = true }):wait()
  assert(direct.code == 0, direct.stderr)
  local skeleton = assert(run_async(source_map.trace, template))
  assert(skeleton.output == direct.stdout, vim.inspect({ template, skeleton.output, direct.stdout }))
  -- Regions must cover output in order, including empty/repeated literal slots.
  local last, literals, expected = 0, 0, 0
  for _, part in ipairs(map_objects.literals(skeleton)) do
    expected = expected + #part.occurrences
  end
  for _, region in ipairs(source_map.rendered_regions(skeleton)) do
    assert(region.output_range.start_byte == last)
    assert(region.output_range.end_byte >= last)
    last = region.output_range.end_byte
    if region.kind == "static" or region.kind == "repeated" then
      literals = literals + 1
    end
  end
  assert(last == #skeleton.output and literals == expected)
end

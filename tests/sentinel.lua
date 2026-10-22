local run_async = dofile("tests/helpers/await.lua")
local source_map = require("vimoi.gotmpl.source_map")

local trace, err = run_async(source_map.trace, 'hello {{ "world" }}!\n')
assert(trace, err)
assert(trace.output == "hello world!\n", vim.inspect(trace))
assert(rawget(trace, "segments") == nil and #trace.literal_parts == 2)
assert(#trace.template_tags == 1 and trace.template_tags[1].text == '{{ "world" }}')
assert(trace.literal_parts[1].output_ranges[1].execution_order == 1)
assert(trace.literal_parts[2].output_ranges[1].execution_order == 2)
assert(trace.literal_parts[1].text == "hello ")
assert(trace.literal_parts[1].output_ranges[1].start_byte == 0)
assert(trace.literal_parts[1].output_ranges[1].end_byte == 6)
assert(trace.literal_parts[2].text == "!\n")
assert(trace.literal_parts[2].output_ranges[1].start_byte == 11)
assert(trace.literal_parts[2].output_ranges[1].end_byte == 13)

local loop, loop_err = run_async(source_map.trace, '{{ range (list "a" "b") }}item={{ . }};{{ end }}')
assert(loop, loop_err)
assert(loop.output == "item=a;item=b;")
assert(#loop.literal_parts == 4)
assert(#loop.literal_parts[2].output_ranges == 2)
assert(#loop.literal_parts[3].output_ranges == 2)

local trimmed, trim_err = run_async(source_map.trace, 'before \n{{- "x" -}}\n after')
assert(trimmed, trim_err)
assert(trimmed.output == "beforexafter", vim.inspect(trimmed))
assert(#trimmed.literal_parts == 2)
assert(trimmed.literal_parts[1].text == "before")
assert(trimmed.literal_parts[1].source.end_byte == 6)
assert(trimmed.literal_parts[1].output_ranges[1].start_byte == 0)
assert(trimmed.literal_parts[1].output_ranges[1].end_byte == 6)
assert(trimmed.literal_parts[2].text == "after")
assert(trimmed.literal_parts[2].source.start_byte == #trimmed.source - #"after")
assert(trimmed.literal_parts[2].output_ranges[1].start_byte == 7)
assert(trimmed.literal_parts[2].output_ranges[1].end_byte == 12)

local left_trimmed, left_trim_err = run_async(source_map.trace, 'a \n{{- "b" }} c')
assert(left_trimmed, left_trim_err)
assert(left_trimmed.output == "ab c")

local right_trimmed, right_trim_err = run_async(source_map.trace, 'a {{ "b" -}}\n c')
assert(right_trimmed, right_trim_err)
assert(right_trimmed.output == "a bc")

local whitespace_only, whitespace_err = run_async(source_map.trace, '{{ "a" -}} \n {{- "b" }}')
assert(whitespace_only, whitespace_err)
assert(whitespace_only.output == "ab")
assert(#whitespace_only.literal_parts == 3)
assert(whitespace_only.literal_parts[2].text == "")
assert(whitespace_only.literal_parts[2].source.start_byte == whitespace_only.literal_parts[2].source.end_byte)
assert(whitespace_only.literal_parts[2].output_ranges[1].start_byte == 1)
assert(whitespace_only.literal_parts[2].output_ranges[1].end_byte == 1)

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
assert(#empty_true.literal_parts == 3 and #empty_true.literal_parts[2].output_ranges == 1)
assert(#empty_false.literal_parts == 3 and #empty_false.literal_parts[2].output_ranges == 0)
assert(source_map.predict_literal_edit(empty_true, "{{ if true }}X{{ end }}") == "X")
assert(source_map.predict_literal_edit(empty_false, "{{ if false }}X{{ end }}") == "")

local else_trace = assert(run_async(source_map.trace, "{{ if false }}{{ else }}{{ end }}"))
assert(#else_trace.literal_parts == 4)
assert(#else_trace.literal_parts[2].output_ranges == 0 and #else_trace.literal_parts[3].output_ranges == 1)
assert(source_map.predict_literal_edit(else_trace, "{{ if false }}{{ else }}X{{ end }}") == "X")
local else_if_trace = assert(run_async(source_map.trace, "{{ if false }}{{ else if true }}{{ end }}"))
assert(#else_if_trace.literal_parts[2].output_ranges == 0 and #else_if_trace.literal_parts[3].output_ranges == 1)
assert(source_map.predict_literal_edit(else_if_trace, "{{ if false }}{{ else if true }}X{{ end }}") == "X")

local empty_range = assert(run_async(source_map.trace, "{{ range (list) }}{{ end }}"))
local double_range = assert(run_async(source_map.trace, "{{ range (list 1 2) }}{{ end }}"))
assert(#empty_range.literal_parts[2].output_ranges == 0)
assert(#double_range.literal_parts[2].output_ranges == 2)
assert(source_map.predict_literal_edit(double_range, "{{ range (list 1 2) }}X{{ end }}") == "XX")

local trim_source = "before\n{{- if true }}\n{{- end }}\nafter\n"
local trim_trace = assert(run_async(source_map.trace, trim_source))
assert(trim_trace.output == "before\nafter\n")
assert(
  source_map.predict_literal_edit(trim_trace, "before\nnew\n{{- if true }}\n{{- end }}\nafter\n")
    == "before\nnew\nafter\n"
)

-- A new template action is not a literal change and must not be guessed.
assert(source_map.predict_literal_edit(assert(run_async(source_map.trace, "A\n")), 'A{{ "B" }}\n') == nil)

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
}) do
  local direct = vim.system({ "chezmoi", "execute-template" }, { stdin = template, text = true }):wait()
  assert(direct.code == 0, direct.stderr)
  local skeleton = assert(run_async(source_map.trace, template))
  assert(skeleton.output == direct.stdout, vim.inspect({ template, skeleton.output, direct.stdout }))
end

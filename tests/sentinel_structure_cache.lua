local run_async = dofile("tests/helpers/await.lua")
---@diagnostic disable: duplicate-set-field -- Isolated CLI counters and delayed completion.
local root = vim.fn.tempname() .. " structure cache"
local config = root .. "/config.toml"
local source_root = root .. "/source"
vim.fn.mkdir(source_root .. "/.chezmoitemplates", "p")
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(source_root),
  "destDir = " .. vim.json.encode(root .. "/target"),
  "[data]",
  "enabled = true",
}, config)
vim.fn.writefile({ "external={{ .enabled }}" }, source_root .. "/.chezmoitemplates/external")
local cli = require("vimoi.cli")
cli.setup("chezmoi", config)
local source_map = require("vimoi.gotmpl.source_map")
local diff_hunks = require("vimoi.gotmpl.diff_hunks")
local merge_plan = require("vimoi.gotmpl.merge_plan")
local util = require("vimoi.util")
local execute = cli.execute_template
local run = cli.run
local executions = 0
cli.run = function(args, opts)
  if args[1] == "execute-template" then
    executions = executions + 1
  end
  return run(args, opts)
end

local checked, reused = 0, 0
local function check(source, opts)
  local args = { "chezmoi", "--config", config, "execute-template" }
  if opts and opts.init then
    args[#args + 1] = "--init"
  end
  local result = vim.system(args, { stdin = source }):wait(10000)
  assert(result.code == 0, result.stderr)
  local trace, err = run_async(source_map.trace, source, opts)
  assert(trace, err)
  assert(
    trace.output == result.stdout,
    vim.inspect({ source = source, actual = trace.output, expected = result.stdout })
  )
  for _, literal_part in ipairs(trace.literal_parts) do
    assert(source:sub(literal_part.source.start_byte + 1, literal_part.source.end_byte) == literal_part.text)
    for _, occurrence in ipairs(literal_part.output_ranges) do
      assert(occurrence.start_byte >= 0 and occurrence.end_byte <= #trace.output)
      assert(occurrence.end_byte - occurrence.start_byte == #literal_part.text)
      assert(
        trace.output:sub(occurrence.start_byte + 1, occurrence.end_byte) == literal_part.text,
        vim.inspect(literal_part)
      )
    end
  end
  checked = checked + 1
  return trace
end

for _, case in ipairs(dofile("tests/fixtures/sentinel_cases.lua")) do
  local source = case[2]
  local opts = type(case[3]) == "table" and case[3] or nil
  local baseline = check(source, opts)
  for changed = 1, #baseline.literal_parts do
    for _, replacement in ipairs({ "", "new static text\n", " \t 新行\r\n " }) do
      local previous, following = baseline.template_tags[changed - 1], baseline.template_tags[changed]
      local first = previous and previous.end_byte or 0
      local last = following and following.start_byte or #source
      local edited = source:sub(1, first) .. replacement .. source:sub(last + 1)
      local before = executions
      check(edited, opts)
      assert(executions == before, "literal edit spawned chezmoi: " .. edited)
      local rebuilt = assert(source_map.rebuild(baseline, edited))
      assert(rebuilt.output == assert(run_async(source_map.trace, edited, opts)).output)
      reused = reused + 1
    end
  end
end

-- Calls own the whole output of opaque definitions/blocks. No body slot may
-- appear as repeated static text or become a candidate for source writeback.
for _, keyword in ipairs({ "define", "block" }) do
  local argument = keyword == "block" and ' "initial"' or ""
  local definition = "{{ " .. keyword .. ' "item"' .. argument .. " }}static={{ . }};{{ end }}"
  local first_call, second_call = '{{ template "item" "first" }}', '{{ template "item" "second" }}'
  local source = definition .. "\nbefore\n" .. first_call .. "\nmiddle\n" .. second_call .. "\nafter\n"
  local trace = check(source)
  assert(#trace.template_tags == 3 and trace.template_tags[1].text == definition)
  for _, part in ipairs(trace.literal_parts) do
    assert(#part.output_ranges == 1, "opaque bodies must not export repeated slots")
  end
  local output_by_tag = {}
  for _, region in ipairs(source_map.rendered_regions(trace)) do
    if region.kind == "dynamic" and region.output_range.start_byte < region.output_range.end_byte then
      local tag = source:sub(region.source.start_byte + 1, region.source.end_byte)
      output_by_tag[tag] = trace.output:sub(region.output_range.start_byte + 1, region.output_range.end_byte)
    end
  end
  assert(output_by_tag[first_call] == "static=first;")
  assert(output_by_tag[second_call] == "static=second;")
  assert(output_by_tag[definition] == (keyword == "block" and "static=initial;" or nil))
  local modified = trace.output:gsub("static=first;", "edited=first;")
  local plan = merge_plan.plan(trace, modified, diff_hunks.compute(modified, trace))
  assert(#plan.edits == 0 and #plan.choices == 0 and #plan.skipped > 0, "call output must require manual body edits")
  local edited = source:gsub("static=", "changed=")
  assert(source_map.rebuild(trace, edited) == nil, "body edits must invalidate the skeleton")
  local before = executions
  check(edited)
  assert(executions == before + 1, "body edits must render the changed definition")
end

-- Parser-specific text-node splits must not affect a literal slot's mapping.
check("a{\n")
check(' {{ "A\\r\\n" }}\r\nend')
for _, source in ipairs({ "tail", "tail{", "{{ if true }}tail{{ end }}", "{{ if true }}{{ end }}" }) do
  local trace = check(source)
  local buf = vim.api.nvim_create_buf(false, true)
  util.set_buffer_text(buf, source .. "new")
  local rebuilt = assert(source_map.rebuild(trace, source .. "new", buf))
  local full = check(source .. "new")
  assert(vim.deep_equal(rebuilt.literal_parts, full.literal_parts), vim.inspect({ rebuilt, full }))
  vim.api.nvim_buf_delete(buf, { force = true })
end

local cached = check("{{ if true }}cache{{ end }}")
local before = executions
assert(
  vim.deep_equal(run_async(source_map.trace, cached.source), cached),
  "cached skeleton produced a different mapping"
)
assert(executions == before)
local done = false
source_map.trace_async(cached.source, {}, function(trace, err)
  assert(not err and vim.deep_equal(trace, cached) and not vim.in_fast_event())
  done = true
end)
assert(not done, "cache-hit callbacks must remain asynchronous")
assert(vim.wait(1000, function()
  return done
end))

-- Manual invalidation clears both whole-text and structural results.
cli.invalidate()
assert(source_map.rebuild(cached, cached.source) == nil)
assert(run_async(source_map.trace, cached.source))
assert(executions == before + 1)

-- Capture an async cache hit before invalidation, then let it complete. The
-- callback may receive its old snapshot, but cannot revive the cleared cache.
done = false
source_map.trace_async("{{ if true }}changed{{ end }}", {}, function(trace, err)
  assert(trace and not err and trace.output == "changed")
  done = true
end)
cli.invalidate()
assert(vim.wait(1000, function()
  return done
end))
before = executions
assert(run_async(source_map.trace, "{{ if true }}changed{{ end }}"))
assert(executions == before + 1)

-- A real in-flight miss completing after invalidation is equally unable to
-- poison the next generation, even when its source text is unchanged.
local pending_source, pending_callback
cli.execute_template = function(source, opts)
  pending_source, pending_callback = source, opts.callback
end
done = false
source_map.trace_async('{{ "dynamic" }}stale', {}, function(trace, err)
  assert(trace and not err and trace.output == "dynamicstale")
  done = true
end)
assert(pending_callback)
cli.invalidate()
pending_callback(assert(run_async(execute, pending_source)))
assert(done)
cli.execute_template = execute
before = executions
assert(run_async(source_map.trace, '{{ "dynamic" }}stale'))
assert(executions == before + 1)

-- A session can reuse its prepared input instead of parsing/decoding it twice.
local prepared = assert(source_map.prepare('{{ "prepared" }} tail'))
local completed = run_async(require("vimoi.util").await, function(callback)
  source_map.trace_async(prepared.source, { prepared = prepared }, callback)
end)
assert(completed == prepared and completed.output == "prepared tail")

-- Different init contexts must never share a rendered skeleton.
cli.invalidate()
assert(run_async(source_map.trace, "literal", { init = true }))
before = executions
assert(run_async(source_map.trace, "literal"))
assert(executions == before + 1)

-- Structural history is bounded, while its most recent entries remain usable.
cli.invalidate()
for i = 1, 33 do
  assert(assert(run_async(source_map.trace, ("{{ %d }}"):format(i))).output == tostring(i))
end
before = executions
assert(assert(run_async(source_map.trace, "{{ 2 }}")).output == "2")
assert(executions == before)
assert(assert(run_async(source_map.trace, "{{ 1 }}")).output == "1")
assert(executions == before + 1, "oldest structure should have been evicted")

cli.execute_template = execute
cli.run = run
vim.fn.delete(root, "rf")
print(
  ("production structure cache: %d outputs/ranges verified; %d literal edits without processes"):format(checked, reused)
)

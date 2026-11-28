-- Run variants in separate Neovim processes, with the same generated inputs.
local api, util = vim.api, require("vimoi.core.util")
local renderer = require("vimoi.render.source_map")
local sync = require("vimoi.compare.sync_scroll")
local cli = require("vimoi.core.cli")
local await = dofile("tests/helpers/await.lua")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/source", "p")
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(root .. "/source"),
  "destDir = " .. vim.json.encode(root .. "/target"),
}, root .. "/config.toml")
cli.setup("chezmoi", root .. "/config.toml", root .. "/source")
local working_dir = "/tmp/vimoi-sentinel-benchmark-cwd"
vim.fn.mkdir(working_dir, "p")
api.nvim_set_current_dir(working_dir)

-- Match the render session's asynchronous notify path, bypassing only the
-- execution cache so every wall-time sample includes a real child process.
local function render(skeleton)
  return await(util.await, function(done)
    cli.execute_template(skeleton, { cache = false, callback = done })
  end)
end

local function median(values)
  table.sort(values)
  return values[math.floor(#values / 2) + 1]
end

local function materialize(trace)
  trace.source_size, trace.output_size = #trace.source, #trace.output
  if not trace._index then
    trace.source_starts, trace.output_starts = util.line_starts(trace.source), util.line_starts(trace.output)
  end
  -- The baseline retains expanded regions; the new map retains sentinel points.
  if not trace._index and not trace.sentinels and not trace.output_bytes then
    return vim.tbl_extend("force", trace, { regions = renderer.rendered_regions(trace) })
  end
  return trace
end

local cases = { { "plain", ("setting=value\n"):rep(2000) } }
for _, size in ipairs({ 200, 2000, 10000 }) do
  local lines = {}
  for row = 1, size do
    lines[row] = ('key_%d={{ "value" }}\n'):format(row)
  end
  cases[#cases + 1] = { "tags_" .. size, table.concat(lines) }
end
local body = {}
for row = 1, 200 do
  body[row] = ("key_%d={{ . }}\n"):format(row)
end
cases[#cases + 1] = { "repeated", "{{ range until 30 }}\n" .. table.concat(body) .. "{{ end }}" }
cases[#cases + 1] = {
  "skipped",
  ("{{ if false }}ignored\n{{ else }}active\n{{ end }}"):rep(2000),
}

local result = {
  variant = vim.env.VIMOI_BENCH_VARIANT,
  nvim = vim.version(),
  queries_per_sample = 512,
  cases = {},
  working_dir = working_dir,
  rendering = "async notify, cache=false",
}
for _, case in ipairs(cases) do
  local name, source = unpack(case)
  local buf = api.nvim_create_buf(false, true)
  util.set_buffer_text(buf, source)
  local prepared = assert(renderer.prepare(source, { buf = buf }))
  local rendered = assert(render(prepared.skeleton))
  local trace = materialize(assert(renderer.restore(prepared, rendered)))
  local session = { map = trace, hunks = {}, source_win = 1, target_win = 2 }
  local line_index = trace._index or trace
  local source_rows =
    math.max(1, #line_index.source_starts - (line_index.source_starts[#line_index.source_starts] == #source and 1 or 0))
  local output_rows = math.max(
    1,
    #line_index.output_starts - (line_index.output_starts[#line_index.output_starts] == #trace.output and 1 or 0)
  )
  local source_times, output_times, builds = {}, {}, {}
  local source_sum, output_sum = 0, 0
  for sample = 1, 12 do
    local cpu = os.clock()
    for query = 1, result.queries_per_sample do
      local row = (query * 7919) % source_rows + 1
      session.cursor_range = nil
      local _, mapped = sync.corresponding_line(session, 1, row)
      source_sum = source_sum + mapped
    end
    local source_cpu = (os.clock() - cpu) * 1000
    cpu = os.clock()
    for query = 1, result.queries_per_sample do
      local row = (query * 7919) % output_rows + 1
      local _, mapped = sync.corresponding_line(session, 2, row)
      output_sum = output_sum + mapped
    end
    local output_cpu = (os.clock() - cpu) * 1000
    collectgarbage("collect")
    cpu = os.clock()
    local next_prepared = assert(renderer.prepare(source, { buf = buf }))
    materialize(assert(renderer.restore(next_prepared, rendered)))
    local build_cpu = (os.clock() - cpu) * 1000
    if sample > 4 then
      source_times[#source_times + 1] = source_cpu
      output_times[#output_times + 1] = output_cpu
      builds[#builds + 1] = build_cpu
    end
  end
  local wall_times = {}
  for sample = 1, 7 do
    local start = vim.uv.hrtime()
    local next_prepared = assert(renderer.prepare(source, { buf = buf }))
    local next_output = assert(render(next_prepared.skeleton))
    materialize(assert(renderer.restore(next_prepared, next_output)))
    if sample > 2 then
      wall_times[#wall_times + 1] = (vim.uv.hrtime() - start) / 1e6
    end
  end
  -- Measure additional retained mapping storage after GC, excluding temporary
  -- trace/source/skeleton fields. Both variants share the same input strings.
  collectgarbage("collect")
  local memory_before = collectgarbage("count")
  ---@type table?
  local candidate = materialize(assert(renderer.restore(assert(renderer.prepare(source, { buf = buf })), rendered)))
  local retained = {}
  for _, key in ipairs({
    "_index",
    "literal_parts",
    "template_tags",
    "sentinels",
    "regions",
    "nodes",
    "source_bytes",
    "source_types",
    "output_indices",
    "slot_starts",
    "slot_types",
    "trim_flags",
    "controls",
    "first_occurrences",
    "next_sentinels",
    "output_bytes",
    "output_slots",
    "source_starts",
    "output_starts",
  }) do
    retained[key] = assert(candidate)[key]
  end
  candidate = nil
  collectgarbage("collect")
  local map_kib = collectgarbage("count") - memory_before
  assert(next(retained))
  result.cases[name] = {
    source_checksum = source_sum,
    output_checksum = output_sum,
    source_bytes = #source,
    output_bytes = #trace.output,
    source_query_cpu_ms = median(source_times),
    output_query_cpu_ms = median(output_times),
    build_cpu_ms = median(builds),
    render_wall_ms = median(wall_times),
    map_kib = map_kib,
  }
  api.nvim_buf_delete(buf, { force = true })
end
vim.fn.writefile({ vim.json.encode(result) }, assert(vim.env.VIMOI_BENCH_RESULT))
print(vim.json.encode(result))

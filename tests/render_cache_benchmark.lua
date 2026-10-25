-- Compare preparation/decoding and cached hunk projection without CLI time.
---@diagnostic disable: duplicate-set-field -- Benchmark-only wrappers count real preparation/decoding.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.env.VIMOI_TEST_DESTINATION = vim.fn.tempname()
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})
local api, util, cli = vim.api, require("vimoi.core.util"), require("vimoi.core.cli")
local renderer, hunks = require("vimoi.render.source_map"), require("vimoi.compare.diff_hunks")
local await = dofile("tests/helpers/await.lua")
local execute, prepare, restore = cli.execute_template, renderer.prepare, renderer.restore
local calls = { prepare = 0, restore = 0 }
renderer.prepare = function(...)
  calls.prepare = calls.prepare + 1
  return prepare(...)
end
renderer.restore = function(prepared, ...)
  if prepared.output == nil then
    calls.restore = calls.restore + 1
  end
  return restore(prepared, ...)
end
local function median(values)
  table.sort(values)
  return values[math.ceil(#values / 2)]
end
local results = {}
for _, size in ipairs({ 8, 1000 }) do
  local lines = {}
  for i = 1, size do
    lines[i] = "key" .. i .. ' = {{ printf "value' .. i .. '" }}'
  end
  local source = table.concat(lines, "\n") .. "\n"
  local buf = api.nvim_create_buf(true, false)
  util.set_buffer_text(buf, source)
  local trace = assert(await(renderer.trace, source, { buf = buf }))
  cli.execute_template = function(_, opts)
    vim.schedule(function()
      opts.callback(trace.rendered_skeleton)
    end)
  end
  local pipeline, diff = {}, {}
  local prepare_count, restore_count
  for repeat_index = 1, 133 do
    calls.prepare, calls.restore = 0, 0
    local cpu = os.clock()
    local prepared = assert(renderer.prepare(source, { buf = buf }))
    local completed = false
    renderer.trace_async(source, { buf = buf, prepared = prepared }, function(value, err)
      assert(value, err)
      assert(assert(renderer.restore(prepared, value.rendered_skeleton)).output == trace.output)
      cpu = (os.clock() - cpu) * 1000
      completed = true
    end)
    assert(vim.wait(10000, function()
      return completed
    end, 1))
    if repeat_index > 33 then
      pipeline[#pipeline + 1] = cpu
    end
    prepare_count, restore_count = calls.prepare, calls.restore
  end
  trace.regions = renderer.rendered_regions(trace)
  trace.output_starts = util.line_starts(trace.output)
  for repeat_index = 1, 133 do
    local cpu = os.clock()
    assert(#hunks.compute(trace.output .. "tail\n", trace) == 1)
    cpu = (os.clock() - cpu) * 1000
    if repeat_index > 33 then
      diff[#diff + 1] = cpu
    end
  end
  local cached_regions = trace.regions
  trace.regions = nil
  local region_build = {}
  for repeat_index = 1, 133 do
    local cpu = os.clock()
    local built = renderer.rendered_regions(trace)
    cpu = (os.clock() - cpu) * 1000
    assert(#built == #cached_regions)
    if repeat_index > 33 then
      region_build[#region_build + 1] = cpu
    end
  end
  trace.regions = cached_regions

  -- Sparse hunks exercise region lookup, native line projection and merge planning.
  local target_lines = util.text_lines(trace.output)
  local stride = math.max(2, math.floor(size / 100))
  for row = stride, size, stride do
    target_lines[row] = target_lines[row]:gsub("^key", "kex", 1)
  end
  local modified = table.concat(target_lines, "\n") .. "\n"
  local target_buf = api.nvim_create_buf(true, false)
  util.set_buffer_text(target_buf, modified)
  require("vimoi.api").diff_buffers(buf, target_buf)
  local views = require("vimoi.compare")
  local view = assert(views.by_window[api.nvim_get_current_win()])
  assert(vim.wait(5000, function()
    return not view.loading
  end, 1))
  local native = require("vimoi.compare.native_diff")
  local planner = require("vimoi.merge.plan")
  local sparse, projection, planning = {}, {}, {}
  for repeat_index = 1, 83 do
    local cpu = os.clock()
    local sparse_hunks = hunks.compute(modified, trace)
    local sparse_cpu = (os.clock() - cpu) * 1000
    assert(#sparse_hunks == math.floor(size / stride))
    view.projected_hunks = nil
    cpu = os.clock()
    assert(native.hunk_at(view, buf, stride) == view.hunks[1])
    local projection_cpu = (os.clock() - cpu) * 1000
    cpu = os.clock()
    local plan = planner.plan(trace, modified, sparse_hunks)
    local planning_cpu = (os.clock() - cpu) * 1000
    assert(#plan.edits == #sparse_hunks and #plan.choices == 0 and #plan.skipped == 0)
    if repeat_index > 53 then
      sparse[#sparse + 1] = sparse_cpu
      projection[#projection + 1] = projection_cpu
      planning[#planning + 1] = planning_cpu
    end
  end
  views.close(view)
  api.nvim_buf_delete(target_buf, { force = true })
  results[tostring(size)] = {
    pipeline_cpu_ms = median(pipeline),
    diff_cpu_ms = median(diff),
    prepare_calls = prepare_count,
    decode_calls = restore_count,
    sparse_hunk_cpu_ms = median(sparse),
    native_projection_cpu_ms = median(projection),
    merge_planning_cpu_ms = median(planning),
    region_build_cpu_ms = median(region_build),
  }
  api.nvim_buf_delete(buf, { force = true })
  cli.execute_template = execute
end
renderer.prepare, renderer.restore = prepare, restore
if vim.env.VIMOI_BENCH_RESULT then
  vim.fn.writefile({ vim.json.encode(results) }, vim.env.VIMOI_BENCH_RESULT)
else
  print(vim.json.encode(results))
end

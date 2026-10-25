-- All consumers borrow one mutable output and one current source render.
vim.opt.swapfile = false
local api, util = vim.api, require("vimoi.core.util")
local lint_jobs = {}
package.loaded.lint = {
  linters_by_ft = { lua = { "test" } },
  linters = { test = { stdin = true } },
  lint = function()
    local job = { buf = api.nvim_get_current_buf(), cancelled = false }
    function job:cancel()
      self.cancelled = true
    end
    lint_jobs[#lint_jobs + 1] = job
    return job
  end,
}
require("vimoi").setup()
local actions = require("vimoi.api")
local sessions = require("vimoi.render")
local views = require("vimoi.compare")
local cli = require("vimoi.core.cli")
local execute = cli.execute_template
local renders = 0
---@diagnostic disable-next-line: duplicate-set-field -- Count shared renderer requests.
cli.execute_template = function(...)
  renders = renders + 1
  return execute(...)
end
local function await(predicate)
  assert(vim.wait(5000, predicate, 5), "shared output did not settle")
end
local source = api.nvim_create_buf(true, false)
api.nvim_set_current_buf(source)
api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua.tmpl")
local text = 'local n = {{ "1" }}\nlocal label = "one"\n'
util.set_buffer_text(source, text)
actions.preview()
local preview = assert(views.by_window[api.nvim_get_current_win()])
await(function()
  return not preview.loading and #lint_jobs > 0
end)
local state = sessions.get(source)
local output = state.buf
local parser = assert(vim.treesitter.get_parser(output, "lua"))
assert(output == preview.target_buf and output == lint_jobs[1].buf)
assert(renders == 1, "preview/highlight/diagnostics launched independent renders")
assert(
  state.automatic and vim.tbl_count(state.subscribers) == 2,
  "automatic features did not share one source subscription"
)

assert(
  rawget(state, "trace") == nil
    and rawget(state, "source") == nil
    and rawget(state, "output") == nil
    and state.prepared == nil,
  "output retained a completed text snapshot"
)
assert(rawget(state.map, "source") == nil and rawget(state.map, "output") == nil, "mapping duplicated buffer text")
local map, initial_tick = assert(state.map), api.nvim_buf_get_changedtick(output)
local checks = #lint_jobs
local snapshot = assert(sessions.snapshot(source))
assert(
  snapshot.regions == map.regions
    and snapshot.output_starts == map.output_starts
    and snapshot.source_starts == map.source_starts
)
sessions.update(source, snapshot)
assert(#lint_jobs == checks and not lint_jobs[checks].cancelled, "unchanged mapping restarted host checks")
assert(
  state.map == map and api.nvim_buf_get_changedtick(output) == initial_tick,
  "the same source/context version rebuilt its output"
)

vim.cmd("tabnew")
api.nvim_win_set_buf(0, source)
local target = api.nvim_create_buf(true, false)
util.set_buffer_text(target, util.buffer_text(output))
actions.diff_buffers(source, target, { filetype = "lua" })
local diff = assert(views.by_window[api.nvim_get_current_win()])
await(function()
  return not diff.loading
end)
assert(renders == 1 and diff.map == state.map)
local count = 0
for _, buf in ipairs(api.nvim_list_bufs()) do
  if vim.b[buf].vimoi_output_source == source then
    count = count + 1
  end
end
assert(count == 1, "source has multiple rendered buffers")

local function change(before, after)
  text = text:gsub(before, after)
  util.set_buffer_text(source, text)
  api.nvim_exec_autocmds("TextChangedI", { buffer = source })
  await(function()
    return state.map.tick == api.nvim_buf_get_changedtick(source) and preview.map == state.map and diff.map == state.map
  end)
  assert(sessions.get(source).buf == output and lint_jobs[#lint_jobs].buf == output)
  assert(vim.treesitter.get_parser(output, "lua") == parser)
  assert(util.buffer_text(output) == util.buffer_text(output))
end
change('"1"', '"2"')
assert(renders == 2 and lint_jobs[1].cancelled)
change('"one"', '"two"')
assert(renders == 2, "literal edit started a new render")
-- 'endofline' changes rendered text without advancing changedtick.
local source_tick = api.nvim_buf_get_changedtick(source)
vim.bo[source].endofline = false
api.nvim_exec_autocmds("OptionSet", { pattern = "endofline" })
await(function()
  return state.map.source_eol == false and not vim.bo[output].endofline
end)
assert(api.nvim_buf_get_changedtick(source) == source_tick and renders == 2)
vim.bo[source].endofline = true
api.nvim_exec_autocmds("OptionSet", { pattern = "endofline" })
await(function()
  return state.map.source_eol and vim.bo[output].endofline
end)

assert(util.buffer_text(target) == 'local n = 1\nlocal label = "one"\n', "shared output overwrote target edits")

-- A source-only edit shifts mappings without changing the rendered document.
-- Providers receive no output edit, so their cached diagnostics must reproject.
local provider = api.nvim_create_namespace("shared-output-provider")
local projected = api.nvim_create_namespace("vimoi-host-diagnostics")
vim.diagnostic.set(provider, output, { { lnum = 1, col = 0, end_col = 5, message = "retained" } })
local tick = api.nvim_buf_get_changedtick(output)
text = "{{/*\ncomment\n*/}}" .. text
util.set_buffer_text(source, text)
api.nvim_exec_autocmds("TextChangedI", { buffer = source })
await(function()
  local found = vim.diagnostic.get(source, { namespace = projected })
  return state.map.tick == api.nvim_buf_get_changedtick(source) and #found == 1 and found[1].lnum == 3
end)
assert(api.nvim_buf_get_changedtick(output) == tick, "source-only change rewrote identical output")

-- Leaving gotmpl releases automatic providers, not a view's output.
vim.bo[source].filetype = "text"
assert(api.nvim_buf_is_valid(output) and lint_jobs[#lint_jobs].cancelled)
assert(not state.automatic and vim.tbl_count(state.subscribers) == 2, "automatic cleanup released an explicit view")
change('"2"', '"3"')
views.close(preview)
assert(views.is_valid(diff) and api.nvim_buf_is_valid(output))
views.close(diff)
await(function()
  return next(state.subscribers) == nil
end)
local previous = util.buffer_text(output)
util.set_buffer_text(source, "no consumers\n")
api.nvim_exec_autocmds("TextChangedI", { buffer = source })
assert(util.buffer_text(output) == previous)
api.nvim_buf_delete(source, { force = true })
assert(not api.nvim_buf_is_valid(output), "source unload leaked its output")
print(
  "shared output: preview/diff/highlight/lint identity, one render, incremental parsing, target isolation and lifecycle verified"
)

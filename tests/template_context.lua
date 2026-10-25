---@diagnostic disable: duplicate-set-field -- Count actual CLI executions independently of the oracle.
local await = dofile("tests/helpers/await.lua")
local util = require("vimoi.core.util")
local root = vim.fn.tempname() .. ' context " 中文'
local source_root, target_root = root .. "/source", root .. "/target"
local managed_root = source_root .. "/nested"
local config, wrapper = root .. "/config.toml", root .. "/chezmoi"
vim.fn.mkdir(managed_root .. "/.chezmoitemplates", "p")
vim.fn.mkdir(target_root, "p")
vim.fn.writefile({ "nested" }, source_root .. "/.chezmoiroot")
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(source_root),
  "destDir = " .. vim.json.encode(target_root),
}, config)
vim.fn.writefile({
  "#!/bin/sh",
  "exec " .. vim.fn.shellescape(vim.fn.exepath("chezmoi")) .. " --persistent-state " .. vim.fn.shellescape(
    root .. "/state"
  ) .. ' "$@"',
}, wrapper)
assert(vim.uv.fs_chmod(wrapper, 493))
local body = '{{ dict "direct" .chezmoi "included" (includeTemplate "nested" . | fromJson) '
  .. '"types" (printf "%T|%T|%T|%T" .chezmoi.sourceFile .chezmoi.targetFile .chezmoi.command .chezmoi.args) | toJson }}'
vim.fn.writefile({ "{{ .chezmoi | toJson }}" }, managed_root .. "/.chezmoitemplates/leaf")
vim.fn.writefile({ '{{ includeTemplate "leaf" . }}' }, managed_root .. "/.chezmoitemplates/nested")
for _, name in ipairs({ "alpha", "beta" }) do
  vim.fn.writefile({ body }, managed_root .. "/dot_" .. name .. ".tmpl")
end
require("vimoi").setup({
  chezmoi_executable = wrapper,
  chezmoi_config_path = config,
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})
local cli, map = require("vimoi.core.cli"), require("vimoi.render.source_map")
assert(cli.source_root == managed_root, ".chezmoiroot must be reflected in sourceFile")
local run, renders = cli.run, 0
cli.run = function(args, opts)
  if args[1] == "execute-template" then
    renders = renders + 1
  end
  return run(args, opts)
end
local function buffer(name)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, managed_root .. "/dot_" .. name .. ".tmpl")
  util.set_buffer_text(buf, body .. "\n")
  return buf
end
local first, second = buffer("alpha"), buffer("beta")
local function oracle(name)
  local result = vim.system({ wrapper, "--config", config, "cat", target_root .. "/." .. name }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function trace(buf)
  return assert(await(map.trace, util.buffer_text(buf), { buf = buf }))
end

local alpha = trace(first)
assert(alpha.output == oracle("alpha"), alpha.output)
assert(alpha.prefix ~= "" and alpha.skeleton:sub(1, #alpha.prefix) == alpha.prefix)
assert(alpha.template_tags[1].skeleton_start_byte > #alpha.prefix)
local data = vim.json.decode(alpha.output)
assert(data.direct.command == "cat" and data.direct.sourceFile == "dot_alpha.tmpl")
assert(data.direct.targetFile == target_root .. "/.alpha")
assert(vim.deep_equal(data.direct, data.included))
assert(data.types == "string|string|string|[]string", data.types)

-- Identical source text must not hit the whole-trace or CLI skeleton cache
-- for another file. Returning to the first file should reuse its skeleton.
local before = renders
local beta = trace(second)
assert(beta.output == oracle("beta") and alpha.skeleton ~= beta.skeleton)
assert(renders == before + 1)
before = renders
assert(trace(first).output == alpha.output and renders == before)
assert(map.rebuild(alpha, alpha.source, second) == nil)

-- Static inference must retain the exact same context without a live buffer.
local changed = "header\n" .. alpha.source
local rebuilt = assert(map.rebuild(alpha, changed))
assert(rebuilt.prefix == alpha.prefix and rebuilt.output == "header\n" .. alpha.output)
local edited =
  assert(map.rebuild_after_edits(alpha, changed, { { start_byte = 0, end_byte = 0, replacement = "header\n" } }))
assert(edited.output == rebuilt.output and edited.prefix == alpha.prefix)
assert(renders == before)

-- Concurrent consumers for equal source text must also get distinct in-flight
-- skeleton jobs when their file contexts differ.
cli.invalidate()
before = renders
local results, complete = {}, 0
for _, buf in ipairs({ first, second }) do
  map.trace_async(util.buffer_text(buf), { buf = buf }, function(result, err)
    results[buf] = assert(result, err)
    complete = complete + 1
  end)
end
assert(vim.wait(5000, function()
  return complete == 2
end, 5))
assert(renders == before + 2)
alpha, beta = results[first], results[second]
assert(alpha.output == oracle("alpha") and beta.output == oracle("beta"))

-- Renaming a buffer with unchanged text also changes its rendering context.
vim.api.nvim_buf_delete(second, { force = true })
vim.api.nvim_buf_set_name(first, managed_root .. "/dot_beta.tmpl")
assert(map.rebuild(alpha, alpha.source, first) == nil)
assert(trace(first).output == beta.output)

-- Initial source text, including leading trim and CRLF, must remain literal;
-- the prelude must not emit output or accidentally define user variables.
for _, text in ipairs({ "", "plain\r\n", ' \r\n{{- "x" -}}\r\n tail', '{{ define "x" }} {{ end }}{{ template "x" . }}' }) do
  util.set_buffer_text(first, text)
  local direct = assert(await(cli.execute_template, text))
  assert(trace(first).output == direct)
end
util.set_buffer_text(first, "{{ $_ }}")
local invalid, err = await(map.trace, "{{ $_ }}", { buf = first })
assert(not invalid and err:find('undefined variable "$_"', 1, true))

-- Init templates, unnamed buffers and standalone helper templates keep the
-- original execute-template context rather than inventing a managed target.
local plain = "{{ .chezmoi.command }}|{{ .chezmoi.sourceFile }}|{{ .chezmoi.targetFile }}"
local unnamed = vim.api.nvim_create_buf(true, false)
util.set_buffer_text(unnamed, plain)
local raw = assert(await(cli.execute_template, plain))
local standalone = trace(unnamed)
assert(standalone.prefix == "" and standalone.output == raw)
vim.api.nvim_buf_set_name(unnamed, managed_root .. "/.chezmoitemplates/leaf")
local helper = trace(unnamed)
assert(helper.prefix == "" and helper.output == raw)
util.set_buffer_text(first, plain)
local init = assert(await(map.trace, plain, { buf = first, init = true }))
assert(init.prefix == "" and init.output == assert(await(cli.execute_template, plain, { init = true })))
cli.run = run
-- Real views must share the managed context with strict cat validation and
-- preview; a preview's scratch URI must never become .chezmoi.targetFile.
local expected = oracle("alpha")
vim.fn.writefile(util.text_lines(expected), target_root .. "/.alpha")
local api, sessions = require("vimoi.api"), require("vimoi.compare")
api.diff_files(managed_root .. "/dot_alpha.tmpl", target_root .. "/.alpha", { validate = true })
dofile("tests/helpers/diff.lua")()
local session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
assert(
  assert(require("vimoi.render").snapshot(session.source_buf)).output == expected
    and session.session.validate == true
    and session.session.initialized == true
)
api.preview()
session = assert(sessions.by_window[vim.api.nvim_get_current_win()])
assert(vim.wait(5000, function()
  return not session.loading
end, 5))
assert(session.preview and assert(require("vimoi.render").snapshot(session.source_buf)).output == expected)
assert(util.buffer_text(session.target_buf) == expected)
sessions.close(session)
vim.api.nvim_buf_delete(first, { force = true })
vim.api.nvim_buf_delete(unnamed, { force = true })
vim.fn.delete(root, "rf")
print(
  "template context: cat equality, nested includes, argument types, .chezmoiroot, quoting, caches, inference and rename verified"
)

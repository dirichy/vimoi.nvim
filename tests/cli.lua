local run_async = dofile("tests/helpers/await.lua")
local cli = require("vimoi.core.cli")
local source_root = vim.fn.getcwd() .. "/tests/fixtures/environment/source"
local source_file = source_root .. "/dot_diff_target.tmpl"
local ignored_source = source_root .. "/dot_ignored"
local calls = {}
local forced_result
local last_options
local original_system = vim.system

---@diagnostic disable-next-line: duplicate-set-field -- Count calls without launching chezmoi.
vim.system = function(argv, opts, callback)
  last_options = opts
  local key = table.concat(argv, " ")
  calls[key] = (calls[key] or 0) + 1
  local output = ""
  if argv[2] == "source-path" then
    output = argv[3] and (argv[3] == "/tmp/missing" and "" or source_file) or source_root
  elseif argv[2] == "target-path" then
    output = argv[3] == ignored_source and "/tmp/.ignored" or "/tmp/vimoi-cli-target"
  elseif argv[2] == "data" then
    output = vim.json.encode({
      chezmoi = {
        sourceDir = source_root,
        destDir = "/tmp",
        command = "data",
        args = { "data" },
        sourceFile = "stdin",
        targetFile = "/tmp/target",
      },
    })
  elseif argv[2] == "execute-template" and argv[3] == "{{ .chezmoi.configFile }}" then
    output = "/tmp/vimoi-cli-config"
  end
  local result = forced_result
    or (argv[2] == "source-path" and argv[3] == "/tmp/.ignored" and { code = 1, stdout = "", stderr = "not managed" })
    or { code = 0, stdout = output, stderr = "" }
  if callback then
    vim.schedule(function()
      callback(result)
    end)
    return {}
  end
  return {
    wait = function()
      return result
    end,
  }
end

require("vimoi").setup({ chezmoi_executable = "fake" })
assert(cli.source_root == source_root)
assert(cli.source_root == source_root)
assert(calls["fake source-path"] == 1)

assert(cli.counterpart_path(source_file) == "/tmp/vimoi-cli-target")
assert(cli.counterpart_path(source_file) == "/tmp/vimoi-cli-target")
assert(cli.counterpart_path(source_root .. "/./dot_diff_target.tmpl") == "/tmp/vimoi-cli-target")
assert(cli.counterpart_path(source_root .. "/unused/../dot_diff_target.tmpl") == "/tmp/vimoi-cli-target")
assert(calls["fake target-path " .. source_file] == 1)
assert(calls["fake source-path /tmp/vimoi-cli-target"] == 1, "source target must be validated")
assert(cli.counterpart_path("/tmp/vimoi-cli-target") == source_file)
assert(calls["fake source-path /tmp/vimoi-cli-target"] == 1, "reverse mapping should be cached")

assert(cli.counterpart_path("/tmp/target") == source_file)
assert(cli.counterpart_path("/tmp/target") == source_file)
assert(calls["fake source-path /tmp/target"] == 1)
assert(cli.counterpart_path("/tmp/missing") == "")
assert(cli.counterpart_path("/tmp/missing") == "")
assert(calls["fake source-path /tmp/missing"] == 2, "missing source paths must not be cached")

local ignored_target, ignored_error = cli.counterpart_path(ignored_source)
assert(ignored_target == nil and ignored_error and ignored_error:find("not managed", 1, true))
assert(cli.counterpart_path(ignored_source) == nil)
assert(calls["fake target-path " .. ignored_source] == 2, "inactive targets must not be cached")

local sibling_path = source_root .. "-other/dot_file"
assert(cli.counterpart_path(sibling_path) == source_file)
assert(calls["fake source-path " .. sibling_path] == 1, "source-root prefix must end at a directory boundary")

assert(run_async(cli.data).chezmoi.sourceDir == source_root)
assert(run_async(cli.data).chezmoi.sourceDir == source_root)
local cached_data = run_async(cli.data)
for _, field in ipairs({ "command", "args", "sourceFile", "targetFile" }) do
  assert(cli.is_runtime_value(cached_data.chezmoi[field]), field .. " was not sanitized")
end
assert(calls["fake data --format=json"] == 1)

local working_directory = vim.fn.getcwd()
vim.api.nvim_set_current_dir("/tmp")
assert(run_async(cli.data).chezmoi.sourceDir == source_root)
assert(cli.counterpart_path("/tmp/vimoi-cli-target") == source_file)
vim.api.nvim_set_current_dir(working_directory)
assert(calls["fake data --format=json"] == 1, "changing cwd must reuse cached data")
assert(calls["fake source-path /tmp/vimoi-cli-target"] == 1, "changing cwd must reuse cached paths")

run_async(cli.run, { "cat", "/tmp/target" })
run_async(cli.run, { "cat", "/tmp/target" })
assert(calls["fake cat /tmp/target"] == 2)
assert(run_async(cli.execute_template, "{{ .value }}", { timeout = 123 }) == "")
assert(last_options.stdin == "{{ .value }}" and last_options.timeout == 123)
run_async(cli.execute_template, "{{ .value }}")
assert(last_options.timeout == nil)
assert(calls["fake execute-template"] == 2)

cli.invalidate()
local received = 0
for _ = 1, 2 do
  cli.data_async(function(data, err)
    assert(data and not err)
    received = received + 1
  end)
end
assert(vim.wait(1000, function()
  return received == 2
end))
assert(calls["fake data --format=json"] == 2, "concurrent data requests were not coalesced")

cli.invalidate()
local stale_result_received = false
cli.data_async(function(data, err)
  assert(data == nil and err and err:find("cache invalidated", 1, true))
  stale_result_received = true
end)
cli.invalidate()
local fresh_data
cli.data_async(function(data, err)
  assert(data and not err)
  fresh_data = data
end)
assert(vim.wait(1000, function()
  return stale_result_received and fresh_data ~= nil
end))
assert(run_async(cli.data) == fresh_data, "stale requests must not overwrite the new cache")
assert(calls["fake data --format=json"] == 4)

local decoded_async
run_async(cli.run, { "data", "--format=json" }, {
  decode_json = true,
  callback = function(data, err)
    assert(not err)
    decoded_async = data
  end,
})
assert(vim.wait(1000, function()
  return decoded_async ~= nil
end))
assert(decoded_async.chezmoi.sourceDir == source_root)

local template_async
run_async(cli.execute_template, "{{ .value }}", {
  timeout = 456,
  callback = function(output, err)
    assert(not err and not vim.in_fast_event())
    template_async = output
  end,
})
assert(last_options.stdin == "{{ .value }}" and last_options.timeout == 456)
assert(vim.wait(1000, function()
  return template_async ~= nil
end))
assert(template_async == "")

cli.invalidate()
assert(cli.source_root == source_root)
assert(calls["fake source-path"] == 1)
cli.invalidate()
assert(cli.source_root == source_root)
assert(calls["fake source-path"] == 1, "invalidate must not reload the setup-time source root")
assert(calls["fake execute-template {{ .chezmoi.configFile }}"] == 1, "config path must be queried only at setup")

forced_result = { code = 1, stdout = "", stderr = "example failure" }
local _, command_error = run_async(cli.run, { "cat", "/tmp/target" })
assert(command_error and command_error:find("fake cat /tmp/target failed (1): example failure", 1, true))

local rendered, render_error = run_async(cli.execute_template, "bad template")
assert(
  rendered == nil and render_error and render_error:find("fake execute-template failed (1): example failure", 1, true)
)
local async_render_error
run_async(cli.execute_template, "bad template", {
  callback = function(output, err)
    assert(output == nil and not vim.in_fast_event())
    async_render_error = err
  end,
})
assert(vim.wait(1000, function()
  return async_render_error ~= nil
end))
assert(async_render_error == render_error)

forced_result = { code = 0, stdout = "{invalid", stderr = "" }
local _, json_error = run_async(cli.run, { "data", "--format=json" }, { decode_json = true })
assert(json_error and json_error:find("cannot decode JSON", 1, true))
cli.invalidate()
local async_error
cli.data_async(function(data, err)
  assert(data == nil)
  async_error = err
end)
assert(vim.wait(1000, function()
  return async_error ~= nil
end))
assert(async_error:find("cannot decode JSON", 1, true))

forced_result = { code = 0, stdout = "false", stderr = "" }
cli.invalidate()
local _, shape_error = run_async(cli.data)
assert(shape_error == "invalid `chezmoi data`: missing chezmoi object")
local async_shape_error
cli.data_async(function(data, err)
  assert(data == nil)
  async_shape_error = err
end)
assert(vim.wait(1000, function()
  return async_shape_error ~= nil
end))
assert(async_shape_error == shape_error)
vim.system = original_system

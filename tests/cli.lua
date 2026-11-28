local run_async = dofile("tests/helpers/await.lua")
local cli = require("vimoi.core.cli")
local source_root = vim.fn.getcwd() .. "/tests/fixtures/environment/source"
local source_file = source_root .. "/dot_diff_target.tmpl"
local missing_source = source_root .. "/dot_missing"
local batch_queries = 0
local calls = {}
local forced_result
local last_options
local original_system = vim.system

---@diagnostic disable-next-line: duplicate-set-field -- Count calls without launching chezmoi.
vim.system = function(argv, opts, callback)
  last_options = opts
  assert(argv[2] == "--config" and argv[4] == "--source" and argv[5] == source_root)
  argv = vim.list_extend({ argv[1] }, vim.list_slice(argv, 6))
  local key = table.concat(argv, " ")
  calls[key] = (calls[key] or 0) + 1
  local output = ""
  assert(argv[2] ~= "source-path", "configured source paths must not be queried")
  if argv[2] == "target-path" then
    assert(argv[3] == "--")
    batch_queries = batch_queries + (#argv > 4 and 1 or 0)
    local targets = {}
    for index = 4, #argv do
      targets[#targets + 1] = argv[index] == source_file and "/tmp/vimoi-cli-target"
        or "/tmp/vimoi-cli-" .. vim.fs.basename(argv[index])
    end
    output = table.concat(targets, "\n") .. "\n"
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
  end
  local result = forced_result or { code = 0, stdout = output, stderr = "" }
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

dofile("tests/helpers/setup.lua")({ chezmoi_executable = "fake" })
assert(cli.source_root == source_root)
assert(cli.source_root == source_root)
assert(calls["fake source-path"] == nil)

assert(cli.counterpart_path(source_file) == "/tmp/vimoi-cli-target")
assert(cli.counterpart_path(source_file) == "/tmp/vimoi-cli-target")
assert(cli.counterpart_path(source_root .. "/./dot_diff_target.tmpl") == "/tmp/vimoi-cli-target")
assert(cli.counterpart_path(source_root .. "/unused/../dot_diff_target.tmpl") == "/tmp/vimoi-cli-target")
assert(calls["fake target-path -- " .. source_file] == nil, "forward misses must query the whole source tree")
assert(cli.counterpart_path("/tmp/vimoi-cli-target") == source_file)
assert(batch_queries == 1, "a forward miss must rebuild once and populate the reverse cache")

local plain_source = source_root .. "/dot_plain"
assert(cli.counterpart_path("/tmp/vimoi-cli-dot_plain") == plain_source)
assert(cli.counterpart_path("/tmp/vimoi-cli-dot_plain") == plain_source)
assert(batch_queries == 1, "the first rebuild must populate all reverse entries")
assert(cli.counterpart_path(plain_source) == "/tmp/vimoi-cli-dot_plain")
assert(calls["fake target-path -- " .. plain_source] == nil, "rebuild must populate forward entries too")
assert(cli.counterpart_path("/tmp/missing") == "")
assert(cli.counterpart_path("/tmp/missing") == "")
assert(batch_queries == 3, "reverse misses must rescan instead of caching absence")

assert(cli.counterpart_path(missing_source) == "")
assert(cli.counterpart_path(source_root .. "/.chezmoitemplates/missing") == "")
assert(batch_queries == 3, "missing/source-only source paths must not enumerate")

local sibling_path = source_root .. "-other/dot_file"
assert(cli.counterpart_path(sibling_path) == "")
assert(batch_queries == 4, "source-root prefix must end at a directory boundary")

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
assert(batch_queries == 4, "changing cwd must reuse cached paths")

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
assert(calls["fake source-path"] == nil)
cli.invalidate()
assert(cli.source_root == source_root)
assert(calls["fake source-path"] == nil, "invalidate must not reload the setup-time source root")
assert(calls["fake execute-template {{ .chezmoi.configFile }}"] == nil, "configured paths must never be queried")

forced_result = { code = 1, stdout = "", stderr = "example failure" }
local _, command_error = run_async(cli.run, { "cat", "/tmp/target" })
assert(command_error and command_error:find("cat /tmp/target failed (1): example failure", 1, true))

local rendered, render_error = run_async(cli.execute_template, "bad template")
assert(rendered == nil and render_error and render_error:find("execute-template failed (1): example failure", 1, true))
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

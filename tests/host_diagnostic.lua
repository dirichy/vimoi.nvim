---@diagnostic disable: duplicate-set-field -- Simulate configured nvim-lint providers and observe publications.
vim.opt.swapfile = false
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local util = require("vimoi.util")
local cli = require("vimoi.cli")
local host_namespace = vim.api.nvim_create_namespace("vimoi-host-diagnostics")
local template_namespace = vim.api.nvim_create_namespace("vimoi-diagnostics")
local provider_namespace = vim.api.nvim_create_namespace("test-host-provider")
local requests = {}
local lint = {
  linters_by_ft = { lua = { "test", "disk_only" }, yaml = { "yaml_test" } },
  linters = {
    test = { stdin = true, cmd = "test" },
    disk_only = { stdin = false, cmd = "disk" },
    yaml_test = function()
      return { stdin = true, cmd = "yaml" }
    end,
  },
  lint = function(linter)
    local request = { buf = vim.api.nvim_get_current_buf(), linter = linter, cancelled = false }
    function request:cancel()
      self.cancelled = true
    end
    requests[#requests + 1] = request
    return request
  end,
}
package.loaded.lint = lint
local runs = 0
local original_run = cli.run
cli.run = function(args, ...)
  if args[1] == "execute-template" then
    runs = runs + 1
  end
  return original_run(args, ...)
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local source = '{{ if false }}\nskipped\n{{ end }}\nlocal 键 = {{ "1" }}\nprint(host_error)\n'
util.set_buffer_text(buf, source)
require("vimoi.highlight").configure_template_buffer(buf, "lua")
local function wait_for(test)
  assert(vim.wait(5000, test, 10), "host diagnostic update timed out")
end
local function change(text)
  util.set_buffer_text(buf, text)
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
end
local function report(request, diagnostics)
  vim.diagnostic.set(provider_namespace, request.buf, diagnostics)
end
local function diagnostics()
  return vim.diagnostic.get(buf, { namespace = host_namespace })
end
wait_for(function()
  return #requests == 1
end)
local request = requests[1]
assert(runs == 1, "template and host diagnostics launched duplicate renders")
assert(util.buffer_text(request.buf) == "\nlocal 键 = 1\nprint(host_error)\n")
assert(vim.bo[request.buf].filetype == "lua" and not vim.bo[request.buf].buflisted)
assert(vim.bo[request.buf].readonly and not vim.bo[request.buf].modifiable)
assert(vim.api.nvim_buf_get_name(buf) == "", "host diagnostics renamed the source")
assert(#vim.api.nvim_list_wins() == 1, "host checker opened a visible window")
assert(request.linter.name == "test", "file-only linter must be skipped")
report(request, {
  {
    lnum = 2,
    col = 6,
    end_lnum = 2,
    end_col = 16,
    message = "Unknown symbol",
    source = "test-linter",
    code = "test-code",
    severity = vim.diagnostic.severity.WARN,
  },
})
local found = diagnostics()
assert(#found == 1 and found[1].lnum == 4 and found[1].col == 6, vim.inspect(found))
assert(found[1].end_col == 16 and found[1].severity == vim.diagnostic.severity.WARN)
assert(found[1].source == "test-linter" and found[1].code == "test-code")
assert(found[1].message == "[host:lua] Unknown symbol")
assert(vim.diagnostic.get(request.buf, { namespace = provider_namespace })[1].message == "Unknown symbol")

-- Dynamic diagnostics anchor to the producing template expression.
report(request, { { lnum = 1, col = #"local 键 = ", end_col = #"local 键 = 1", message = "dynamic" } })
found = diagnostics()
assert(#found == 1 and found[1].lnum == 3 and found[1].col == #"local 键 = ", vim.inspect(found))
assert(found[1].end_col == #'local 键 = {{ "1" }}')
assert(found[1].message:find("template-generated output", 1, true))
assert(found[1].message == "[host:lua] dynamic (template-generated output)")

-- Editing invalidates provider snapshots immediately, before the debounce.
change("-- header\n" .. source)
assert(#diagnostics() == 0 and request.cancelled and not vim.api.nvim_buf_is_valid(request.buf))
wait_for(function()
  return #requests == 2
end)
assert(runs == 1, "literal edits must reuse the rendered skeleton")
assert(requests[2].buf ~= request.buf, "snapshots must not share provider URIs")
report(requests[2], { { lnum = 3, col = 6, end_col = 16, message = "shifted" } })
assert(diagnostics()[1].lnum == 5)

-- Repeated static source locations deduplicate without losing severity/source.
change("{{ range (list 1 2) }}host_error\n{{ end }}")
wait_for(function()
  return #requests == 3
end)
report(requests[3], {
  { lnum = 0, col = 0, end_col = 10, message = "same", source = "test" },
  { lnum = 1, col = 0, end_col = 10, message = "same", source = "test" },
})
assert(#diagnostics() == 1)
assert(diagnostics()[1].col == #"{{ range (list 1 2) }}")

-- Host changes rerun the configured provider without executing templates again.
local before = runs
require("vimoi.highlight").configure_template_buffer(buf, "yaml")
wait_for(function()
  return #requests == 4
end)
assert(requests[4].linter.name == "yaml_test" and runs == before)

-- Template failure clears host diagnostics instead of checking stale output.
change("{{ unknown_function . }}")
wait_for(function()
  return #vim.diagnostic.get(buf, { namespace = template_namespace }) == 1
end)
assert(#diagnostics() == 0 and requests[4].cancelled)

change("value: 1\n")
wait_for(function()
  return #requests == 5
end)
assert(runs == before + 1, "plain text host checks must not start a render")
local other = vim.api.nvim_create_namespace("test-independent-provider")
vim.diagnostic.set(other, buf, { { lnum = 0, col = 0, message = "keep" } })
require("vimoi").setup({ diagnostics = { host = false } })
assert(requests[5].cancelled and #diagnostics() == 0)
assert(#vim.diagnostic.get(buf, { namespace = other }) == 1)
require("vimoi").setup({ diagnostics = { host = true } })
wait_for(function()
  return #requests == 6
end)
vim.api.nvim_buf_set_name(buf, "vimoi-test://host")
wait_for(function()
  return #requests == 7
end)
assert(vim.fs.dirname(vim.api.nvim_buf_get_name(requests[7].buf)) == vim.fn.getcwd())
vim.bo[buf].filetype = "text"
assert(requests[7].cancelled)
assert(not vim.api.nvim_buf_is_valid(requests[7].buf))
assert(#diagnostics() == 0)
cli.run = original_run
print(
  "host diagnostics: automatic providers, projection, UTF-8, dynamic/repeated output, render reuse, and lifecycle verified"
)

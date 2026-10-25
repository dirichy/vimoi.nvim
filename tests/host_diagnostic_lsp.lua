vim.opt.swapfile = false
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({}, root .. "/host-marker")
local opened, closed, attached, changed = {}, {}, {}, {}
local dispatch
vim.lsp.config("vimoi_test_host", {
  filetypes = { "lua" },
  root_markers = { "host-marker" },
  workspace_required = true,
  on_attach = function(client, buf)
    attached[#attached + 1] = { client = client, buf = buf }
  end,
  cmd = function(dispatchers)
    dispatch = dispatchers
    local closing = false
    return {
      request = function(method, _, callback)
        vim.schedule(function()
          if method == "initialize" then
            callback(nil, { capabilities = { textDocumentSync = 1, positionEncoding = "utf-16" } })
          else
            callback(nil, nil)
          end
        end)
        return true, 1
      end,
      notify = function(method, params)
        if method == "textDocument/didOpen" then
          opened[#opened + 1] = params.textDocument
          local row = 0
          for line in params.textDocument.text:gmatch("([^\n]*)\n") do
            local first = line:find("host_error", 1, true)
            if first then
              local col = vim.str_utfindex(line, "utf-16", first - 1)
              local lnum = row
              vim.schedule(function()
                dispatchers.notification("textDocument/publishDiagnostics", {
                  uri = params.textDocument.uri,
                  version = params.textDocument.version,
                  diagnostics = {
                    {
                      range = {
                        start = { line = lnum, character = col },
                        ["end"] = { line = lnum, character = col + 10 },
                      },
                      severity = 2,
                      code = "unknown",
                      source = "native-test-lsp",
                      message = "Unknown symbol",
                    },
                  },
                })
              end)
            end
            row = row + 1
          end
        elseif method == "textDocument/didChange" then
          changed[#changed + 1] = params.textDocument
        elseif method == "textDocument/didClose" then
          closed[#closed + 1] = params.textDocument.uri
        end
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        closing = true
        dispatchers.on_exit(0, 0)
      end,
    }
  end,
})
vim.lsp.enable("vimoi_test_host")
local util = require("vimoi.core.util")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_name(buf, root .. "/config.lua.tmpl")
util.set_buffer_text(buf, '{{ if false }}\nskipped\n{{ end }}\nlocal n = {{ "1" }}\nprint("中文", host_error)\n')
require("vimoi.editor.highlight").configure_template_buffer(buf, "lua")
local namespace = vim.api.nvim_create_namespace("vimoi-host-diagnostics")
local function wait_for(predicate)
  assert(vim.wait(5000, predicate, 10), "native host LSP did not publish")
end
wait_for(function()
  return #vim.diagnostic.get(buf, { namespace = namespace }) == 1
end)
assert(#opened == 1 and #attached == 1)
assert(attached[1].client.root_dir == root, "native root discovery did not use the target directory")
assert(vim.bo[attached[1].buf].filetype == "lua")
assert(vim.b[attached[1].buf].vimoi_output_source == buf)
assert(vim.bo[buf].filetype == "gotmpl" and #vim.api.nvim_list_wins() == 1)
local diagnostic = vim.diagnostic.get(buf, { namespace = namespace })[1]
assert(diagnostic.lnum == 4 and diagnostic.col == #'print("中文", ', vim.inspect(diagnostic))
assert(diagnostic.end_col == #'print("中文", host_error')
assert(diagnostic.severity == vim.diagnostic.severity.WARN and diagnostic.code == "unknown")
assert(diagnostic.source == "native-test-lsp")
assert(diagnostic.message == "[host:lua] Unknown symbol")

local first_uri = opened[1].uri
util.set_buffer_text(buf, "local n = 1\n")
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
assert(#vim.diagnostic.get(buf, { namespace = namespace }) == 1, "pending rendering cleared visible diagnostics")
wait_for(function()
  return #changed >= 1
end)
assert(#opened == 1 and #attached == 1 and #closed == 0, "editing replaced the output's LSP attachment")
assert(changed[#changed].uri == first_uri)
assert(util.buffer_text(attached[1].buf) == "local n = 1\n")
-- Like a normal file, subsequent provider results use the current mapping.
dispatch.notification("textDocument/publishDiagnostics", {
  uri = first_uri,
  version = changed[#changed].version,
  diagnostics = {
    { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } }, message = "current" },
  },
})
assert(vim.diagnostic.get(buf, { namespace = namespace })[1].message == "[host:lua] current")
-- A failed render clears projected host errors but keeps the native client
-- attached to the last output. Leaving gotmpl must still detach it.
util.set_buffer_text(buf, "{{ if")
vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
wait_for(function()
  return #vim.diagnostic.get(buf, { namespace = vim.api.nvim_create_namespace("vimoi-diagnostics") }) > 0
end)
assert(#vim.lsp.get_clients({ bufnr = attached[1].buf }) == 1)
vim.bo[buf].filetype = "text"
assert(vim.api.nvim_buf_is_valid(attached[1].buf))
assert(#vim.lsp.get_clients({ bufnr = attached[1].buf }) == 0)
vim.lsp.enable("vimoi_test_host", false)
for _, client in ipairs(vim.lsp.get_clients({ name = "vimoi_test_host" })) do
  client:stop(true)
end
print(
  "native host LSP: automatic FileType activation, root discovery, on_attach, UTF-16 projection, and persistent didChange updates verified"
)

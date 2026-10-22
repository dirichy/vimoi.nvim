local run_async = dofile("tests/helpers/await.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
vim.cmd("syntax on")
vim.opt.swapfile = false
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
local api = require("vimoi.api")
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local util = require("vimoi.util")
local sessions = require("vimoi.gotmpl.session")
for _, template in ipairs({
  'name: {{ "alice" }}\nkeep: true\ntimeout: 10\n',
  'name: "{{ "alice" }}"\nkeep: true\ntimeout: 10\n',
  'name: {{ "alice" }}\nsettings:\n  timeout: 10\n  enabled: true\n',
  'name: {{ "alice" }}\n{{ if true }}timeout: 10\n{{ end }}keep: true\n',
}) do
  vim.cmd("tabnew")
  local source, target = vim.fn.tempname() .. ".yaml.tmpl", vim.fn.tempname() .. ".yaml"
  vim.fn.writefile(util.text_lines(template), source)
  local rendered = assert(run_async(require("vimoi.gotmpl.source_map").trace, template)).output
  vim.fn.writefile(util.text_lines(rendered:gsub("alice", "bob"):gsub("10", "20")), target)
  api.diff_files(source, target)
  dofile("tests/helpers/diff.lua")()
  local session = assert(view_for_buffer(vim.fn.bufnr(source)))
  local buf = session.source_buf
  local function snapshot()
    vim.cmd("redraw!")
    local result = {
      active = not not vim.treesitter.highlighter.active[buf],
      ft = vim.bo[buf].filetype,
      syntax = vim.bo[buf].syntax,
      language = vim.b[buf].vimoi_template_language,
      captures = {},
    }
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      for col = 0, #line - 1 do
        for _, c in ipairs(vim.treesitter.get_captures_at_pos(buf, row - 1, col)) do
          result.captures[#result.captures + 1] = { row, col, c.capture, c.lang }
        end
      end
    end
    result.children = vim.tbl_keys(vim.treesitter.get_parser(buf, "gotmpl"):children())
    return result
  end
  assert(vim.wait(2000, function()
    local s = snapshot()
    return #s.captures > 20
  end))
  local before = snapshot()
  local result = assert(api.readd())
  local after = snapshot()
  vim.wait(300)
  local delayed = snapshot()

  assert(result.merged == 1 and result.skipped == 1)
  assert(vim.deep_equal(before, after) and vim.deep_equal(after, delayed), "highlight changed")
  sessions.close(session)
  vim.fn.delete(source)
  vim.fn.delete(target)
end

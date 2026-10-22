-- Exercise actual ephemeral decorations in a TUI, not just captured callbacks.
if not vim.env.VIMOI_HIGHLIGHT_UI_RESULT then
  local result = vim.fn.tempname()
  local pending = ""
  local child = vim.fn.jobstart({
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--cmd",
    "set ttyfast background=dark",
    "-u",
    "tests/minimal_init.lua",
    "-c",
    "lua dofile('tests/host_highlight_ui.lua')",
  }, {
    pty = true,
    env = { VIMOI_HIGHLIGHT_UI_RESULT = result },
    on_stdout = function(channel, data)
      pending = pending .. table.concat(data, "\n")
      -- The test owns the pseudo-terminal, including background-color replies.
      if pending:find("\027]11;?", 1, true) then
        vim.fn.chansend(channel, "\027]11;rgb:1414/1616/1b1b\027\\")
      end
      if pending:find("\027[c", 1, true) then
        vim.fn.chansend(channel, "\027[?1;2c")
      end
      if pending:find("\027[5n", 1, true) then
        vim.fn.chansend(channel, "\027[0n")
      end
      pending = pending:sub(-4)
    end,
  })
  assert(child > 0)
  local status = vim.fn.jobwait({ child }, 15000)[1]
  if status == -1 then
    vim.fn.jobstop(child)
  end
  assert(vim.fn.filereadable(result) == 1, "TUI test did not finish: " .. status)
  local output = table.concat(vim.fn.readfile(result), "\n")
  vim.fn.delete(result)
  assert(status == 0 and output == "OK", output)
  return
end

local function finish(err)
  vim.fn.writefile({ err or "OK" }, vim.env.VIMOI_HIGHLIGHT_UI_RESULT)
  vim.cmd("qa!")
end
local function later(callback)
  vim.defer_fn(function()
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then
      finish(err)
    end
  end, 500)
end

require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "rendered" } })
vim.cmd("set noswapfile nonumber norelativenumber signcolumn=no laststatus=0 noruler noshowmode nowrap")
vim.api.nvim_set_hl(0, "@string.lua", { fg = "#ff1122" })
vim.api.nvim_set_hl(0, "Comment", { fg = "#779988", italic = true })
local source = '{{ "local message = \\"" }}世界{{ "\\"" }}'
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { source })
require("vimoi.highlight").configure_template_buffer(buf, "lua")
later(function()
  vim.cmd("redraw!")
  local column = assert(source:find("世界", 1, true))
  local projected = vim.fn.screenattr(1, column)
  assert(vim.fn.screenstring(1, column) == "世")
  assert(projected ~= vim.fn.screenattr(2, 1), "projected text has no color")
  local target = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(target)
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { 'local message = "世界"', "Comment reference" })
  vim.api.nvim_buf_set_extmark(target, vim.api.nvim_create_namespace("vimoi-test-comment"), 1, 0, {
    end_col = #"Comment reference",
    hl_group = "Comment",
    priority = 200,
  })
  vim.bo[target].filetype = "lua"
  vim.treesitter.start(target, "lua")
  later(function()
    vim.cmd("redraw!")
    assert(projected == vim.fn.screenattr(1, #'local message = "' + 1), "native and projected colors differ")
    local comment = vim.fn.screenattr(2, 1)
    vim.api.nvim_set_current_buf(buf)
    local lines = {}
    for index = 1, 300 do
      lines[index] = source
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    later(function()
      vim.api.nvim_win_set_cursor(0, { 250, 0 })
      vim.cmd("normal! zt")
      later(function()
        vim.cmd("redraw!")
        local position = vim.fn.screenpos(0, 250, column)
        assert(position.row > 0 and vim.fn.screenstring(position.row, position.col) == "世")
        assert(vim.fn.screenattr(position.row, position.col) == projected, "scrolling lost projected colors")
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
          "{{ if false }}",
          'local dead = "world"',
          "{{ else }}",
          "local alive = 1",
          "{{ end }}",
        })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd("normal! zt")
        vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
        later(function()
          vim.cmd("redraw!")
          assert(vim.fn.screenattr(2, 1) == comment, "inactive text does not use the actual Comment style")
          assert(vim.fn.screenattr(4, 1) ~= comment, "executed text received the inactive style")
          assert(vim.fn.screenattr(1, 4) ~= comment, "template action received the inactive style")
          local messages = vim.api.nvim_exec2("messages", { output = true }).output
          assert(messages == "", messages)
          finish()
        end)
      end)
    end)
  end)
end)

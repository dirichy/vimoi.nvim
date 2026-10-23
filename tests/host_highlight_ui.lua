-- Exercise persistent projected highlights and pending-render retention in a TUI.
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
  local status = vim.fn.jobwait({ child }, 30000)[1]
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
local function later(callback, delay)
  vim.defer_fn(function()
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then
      finish(err)
    end
  end, delay or 500)
end

require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "rendered" } })
vim.cmd("set noswapfile nonumber norelativenumber signcolumn=no laststatus=0 noruler noshowmode nowrap")
vim.api.nvim_set_hl(0, "@string.lua", { fg = "#ff1122" })
vim.api.nvim_set_hl(0, "Comment", { fg = "#779988", italic = true })
local source = '{{ "local message = \\"" }}世界{{ "\\"" }}'
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { source })
require("vimoi.highlight").configure_template_buffer(buf, "lua")

-- Lua identifiers and YAML plain scalars have generic and key-specific
-- captures at equal priority. Check actual screen colors throughout edits,
-- undo/redo and viewport replacement, against the native highlighter.
local function check_keys(index)
  local case = ({
    { language = "lua", line = 'local t = { stable = "anchor" }', column = 13, generic = "@variable.lua" },
    { language = "yaml", line = 'stable: "anchor"', column = 1, generic = "@string.yaml" },
  })[index]
  if not case then
    finish()
    return
  end
  vim.api.nvim_set_hl(0, case.generic, { fg = "#eeeeee" })
  vim.api.nvim_set_hl(0, "@property." .. case.language, { fg = "#11ff22" })
  local reference = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(reference)
  vim.api.nvim_buf_set_lines(reference, 0, -1, false, { case.line })
  vim.bo[reference].filetype = case.language
  vim.treesitter.start(reference, case.language)
  later(function()
    local expected = vim.fn.screenattr(1, case.column)
    assert(expected ~= vim.fn.screenattr(2, 1), "native key has no color")
    vim.api.nvim_set_current_buf(buf)
    local lines = {}
    for row = 1, 120 do
      lines[row] = case.line
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! zt")
    require("vimoi.highlight").configure_template_buffer(buf, case.language)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
    later(function()
      local samples, failures = 0, 0
      local timer = assert(vim.uv.new_timer())
      timer:start(
        0,
        10,
        vim.schedule_wrap(function()
          if vim.fn.line("w0") == 1 then
            samples = samples + 1
            if vim.fn.screenattr(1, case.column) ~= expected then
              failures = failures + 1
            end
          end
        end)
      )
      local steps = {}
      for _ = 1, 8 do
        for _, key in ipairs({ '10G0f"ci"', "a", "b", "c", "\027", "u", "\018", "G", "gg" }) do
          steps[#steps + 1] = key
        end
      end
      local step = 0
      local function run()
        step = step + 1
        if step <= #steps then
          vim.api.nvim_input(steps[step])
          vim.defer_fn(run, 60)
        else
          later(function()
            timer:stop()
            timer:close()
            assert(samples > 100, "key test did not sample enough screen updates")
            assert(failures == 0, ("%s key changed color in %d/%d samples"):format(case.language, failures, samples))
            vim.api.nvim_buf_delete(reference, { force = true })
            check_keys(index + 1)
          end)
        end
      end
      run()
    end)
  end)
end

later(function()
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
          assert(vim.fn.screenattr(2, 1) == comment, "inactive text does not use the actual Comment style")
          assert(vim.fn.screenattr(4, 1) ~= comment, "executed text received the inactive style")
          assert(vim.fn.screenattr(1, 4) ~= comment, "template action received the inactive style")
          local active = vim.fn.screenattr(4, 1)
          vim.api.nvim_buf_set_text(buf, 0, 6, 0, 11, { "true" })
          vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
          later(function()
            assert(vim.fn.screenattr(2, 1) == comment, "waiting for rendering cleared the previous colors")
            assert(vim.fn.screenattr(4, 1) == active, "editing one action cleared unrelated colors")
            vim.api.nvim_buf_set_text(buf, 0, 0, 0, 0, { "", "" })
            vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
            later(function()
              assert(vim.fn.screenattr(3, 1) == comment, "retained Comment did not follow the inserted line")
              assert(vim.fn.screenattr(5, 1) == active, "retained host colors did not follow the inserted line")
              later(function()
                assert(vim.fn.screenattr(3, 1) ~= comment, "new render did not replace the previous Comment")
                assert(vim.fn.screenattr(5, 1) == comment, "new inactive branch was not restyled")
                vim.api.nvim_buf_set_text(buf, 1, 6, 1, 10, { "(" })
                vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
                later(function()
                  assert(vim.fn.screenattr(3, 1) ~= comment, "temporary syntax error cleared the last result")
                  assert(vim.fn.screenattr(5, 1) == comment, "temporary syntax error cleared inactive colors")
                  local messages = vim.api.nvim_exec2("messages", { output = true }).output
                  assert(messages == "", messages)
                  check_keys(1)
                end)
              end)
            end, 60)
          end, 60)
        end)
      end)
    end)
  end)
end)

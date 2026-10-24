if not dofile("tests/helpers/tui.lua")("tests/cursorline_ui.lua") then
  return
end
local api, util = vim.api, require("vimoi.util")
api.nvim__inspect_cell(1, 0, 0) -- Enable highlight-state inspection before rendering the test.
local function finish(err)
  vim.fn.writefile({ err or "OK" }, vim.env.VIMOI_UI_RESULT)
  vim.cmd("qa!")
end
local function later(callback)
  vim.defer_fn(function()
    local ok, err = xpcall(callback, debug.traceback)
    if not ok then
      finish(err)
    end
  end, 350)
end
vim.cmd("set noswapfile nonumber norelativenumber signcolumn=no laststatus=0 noruler noshowmode nowrap")
vim.cmd("syntax on")
api.nvim_set_hl(0, "Normal", { fg = "#ffffff", bg = "#101010" })
api.nvim_set_hl(0, "Statement", { fg = "#ffffff" })
api.nvim_set_hl(0, "CursorLine", { bg = "#404040" })
api.nvim_set_hl(0, "NormalFloat", { bg = "#202020" })
require("vimoi").setup({ diagnostics = { enabled = false }, highlight = { mode = "disabled" } })
for _, name in ipairs(vim.treesitter.query.get("gotmpl", "highlights").captures) do
  api.nvim_set_hl(0, "@" .. name .. ".gotmpl", { fg = "#ffffff" })
end

local function background(row, col)
  local cell = api.nvim__inspect_cell(1, row - 1, col - 1)

  return cell[2].background or 0x101010
end
local action, line_style = 0x202020, 0x404040
later(function()
  local source_buf, target_buf = api.nvim_create_buf(true, false), api.nvim_create_buf(true, false)
  util.set_buffer_text(source_buf, '{{ "one\\ntwo\\nthree" }}\ntail\n')
  util.set_buffer_text(target_buf, "one\ntwo\nthree\ntail\n")
  vim.wo.cursorline = true
  require("vimoi.api").diff_buffers(source_buf, target_buf, { filetype = "text" })
  local session = assert(require("vimoi.gotmpl.view").by_window[api.nvim_get_current_win()])
  local function style(win, row, col)
    local pos = vim.fn.screenpos(win, row, col or 1)
    assert(pos.row > 0, "test row is off screen")
    return background(pos.row, pos.col)
  end
  local function move(row)
    api.nvim_set_current_win(session.source_win)
    api.nvim_win_set_cursor(session.source_win, { row, 0 })
    api.nvim_exec_autocmds("CursorMoved", { buffer = source_buf })
  end
  later(function()
    assert(session.map and not session.loading)
    vim.wo[session.source_win].foldenable = false
    vim.wo[session.target_win].foldenable = false
    move(1)
    later(function()
      assert(api.nvim_win_get_cursor(session.target_win)[1] == 2, "expanded action did not select its middle row")
      assert(
        style(session.source_win, 1, 3) == line_style,
        "native cursorline background: " .. style(session.source_win, 1, 3) .. " expected " .. line_style
      )
      for row = 1, 3 do
        assert(style(session.target_win, row) == line_style, "expanded target row lost cursorline: " .. row)
      end
      assert(style(session.target_win, 4) ~= line_style, "unrelated target row received cursorline")
      move(2)
      later(function()
        assert(api.nvim_win_get_cursor(session.target_win)[1] == 4)
        assert(style(session.source_win, 1, 3) == action, "native action background was lost")
        assert(style(session.target_win, 3) ~= line_style, "old visible target range was retained")
        assert(style(session.target_win, 4) == line_style)
        move(1)
        later(function()
          api.nvim_set_current_win(session.target_win)
          later(function()
            assert(
              style(session.target_win, 1) ~= line_style and style(session.target_win, 3) ~= line_style,
              "mapped cursorline leaked after focus change"
            )
            assert(style(session.target_win, 2) == line_style, "native target cursorline was lost")
            api.nvim_set_current_win(session.source_win)
            vim.wo.cursorline = false
            later(function()
              assert(style(session.target_win, 1) ~= line_style, "disabled cursorline retained mapped background")
              vim.wo.cursorline = true
              vim.wo.cursorlineopt = "number"
              later(function()
                assert(style(session.target_win, 3) ~= line_style, "number-only cursorline painted target text")
                finish()
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end)

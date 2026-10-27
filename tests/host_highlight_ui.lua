-- Exercise persistent projected highlights and pending-render retention in a TUI.
if not dofile("tests/helpers/tui.lua")("tests/host_highlight_ui.lua", 45000) then
  return
end

local syntax = vim.env.VIMOI_TEST_HOST_SYNTAX == "1"
local template_fallback = vim.env.VIMOI_TEST_TEMPLATE_FALLBACK == "1"
if syntax then
  local add_language = vim.treesitter.language.add
  ---@diagnostic disable-next-line: duplicate-set-field -- Run the same display checks without host parsers.
  vim.treesitter.language.add = function(language, ...)
    if language ~= "gotmpl" or template_fallback then
      return nil, "test: use Vim syntax on rendered output"
    end
    return add_language(language, ...)
  end
end

local function highlight_reference(buf, language)
  if syntax then
    vim.bo[buf].syntax = language
  else
    vim.bo[buf].filetype = language
    vim.treesitter.start(buf, language)
  end
end

local function finish(err)
  vim.fn.writefile({ err or "OK" }, vim.env.VIMOI_UI_RESULT)
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
require("vimoi.editor.highlight").configure_template_buffer(buf, "lua")

-- Lua identifiers and YAML plain scalars have generic and key-specific
-- captures at equal priority. Check actual screen colors throughout edits,
-- undo/redo and viewport replacement, against the native highlighter.
local check_mappings
local function check_keys(index)
  local case = ({
    { language = "lua", line = 'local t = { stable = "anchor" }', column = 13, generic = "@variable.lua" },
    { language = "yaml", line = 'stable: "anchor"', column = 1, generic = "@string.yaml" },
  })[index]
  if not case then
    check_mappings(1)
    return
  end
  vim.api.nvim_set_hl(0, case.generic, { fg = "#eeeeee" })
  vim.api.nvim_set_hl(0, "@property." .. case.language, { fg = "#11ff22" })
  local reference = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(reference)
  vim.api.nvim_buf_set_lines(reference, 0, -1, false, { case.line })
  highlight_reference(reference, case.language)
  later(function()
    local expected = vim.fn.screenattr(1, case.column)
    if not syntax then
      assert(expected ~= vim.fn.screenattr(2, 1), "native key has no color")
    end
    vim.api.nvim_set_current_buf(buf)
    local lines = {}
    for row = 1, 120 do
      lines[row] = case.line
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! zt")
    require("vimoi.editor.highlight").configure_template_buffer(buf, case.language)
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

-- Compare the displayed color with the same byte in a natively highlighted
-- rendered buffer, including repeated/unsorted mappings and injected languages.
check_mappings = function(index)
  local case = ({
    {
      "lua",
      '{{range list 1 2}}\n{{if eq . 2}}local second = "marker"{{end}}\n{{if eq . 1}}local first = 1{{end}}\n{{end}}',
    },
    { "lua", '{{range list 1 2}}\n{{if eq . 1}}--{{else}}local x="{{end}}marker{{if eq . 2}}"{{end}}\n{{end}}' },
    { "yaml", 'items:\n{{ range list 1 2 }}\n - name: "{{ . }} marker"\n{{ end }}' },
    { "html", '<script>\nconst value = "marker{{ "extra" }}";\n</script>' },
    { "markdown", '# heading\n```lua\nlocal value = "marker{{ "extra" }}"\n```' },
    { "bash", 'cat <<EOF\n{{ "dynamic" }}\nmarker\nEOF\necho "done"' },
  })[index]
  if not case then
    finish()
    return
  end
  local api, util = vim.api, require("vimoi.core.util")
  local await = dofile("tests/helpers/await.lua")
  local source_map = require("vimoi.render.source_map")
  api.nvim_set_current_buf(buf)
  util.set_buffer_text(buf, case[2])
  require("vimoi.editor.highlight").configure_template_buffer(buf, case[1])
  local trace = assert(await(source_map.trace, case[2], { buf = buf }))
  require("vimoi.render").update(buf, trace)
  local first = assert(case[2]:find("marker", 1, true)) - 1
  local output_byte
  for _, part in ipairs(trace.literal_parts) do
    if first >= part.source.start_byte and first < part.source.end_byte then
      output_byte = part.output_ranges[1].start_byte + first - part.source.start_byte
    end
  end
  local output_row, output_col = util.byte_to_position(trace.output, assert(output_byte))
  local reference = api.nvim_create_buf(true, false)
  api.nvim_set_current_buf(reference)
  util.set_buffer_text(reference, trace.output)
  highlight_reference(reference, case[1])
  api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! zt")
  later(function()
    local position = vim.fn.screenpos(0, output_row + 1, output_col + 1)
    assert(position.row > 0 and vim.fn.screenstring(position.row, position.col) == "m")
    local expected = vim.fn.screenattr(position.row, position.col)
    api.nvim_set_current_buf(buf)
    api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! zt")
    later(function()
      local row, col = util.byte_to_position(case[2], first)
      local projected = vim.fn.screenpos(0, row + 1, col + 1)
      assert(projected.row > 0 and vim.fn.screenstring(projected.row, projected.col) == "m")
      assert(
        vim.fn.screenattr(projected.row, projected.col) == expected,
        "native/projected color mismatch: " .. case[1] .. "/" .. index
      )
      api.nvim_buf_delete(reference, { force = true })
      check_mappings(index + 1)
    end, 350)
  end, 350)
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
  highlight_reference(target, "lua")
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

---@diagnostic disable: duplicate-set-field -- Intentional sentinel test mocks.
local root = vim.fn.getcwd()
local fixture = root .. "/tests/fixtures/environment"
local destination = vim.env.VIMOI_TEST_DESTINATION
local target = destination .. "/.complex_diff"
local source = fixture .. "/source/dot_complex_diff.tmpl"
local wrapper = fixture .. "/chezmoi-wrapper.sh"

vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.env.VIMOI_TEST_DESTINATION = destination
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = wrapper, diff = { validate = false } })

vim.cmd("edit " .. vim.fn.fnameescape(target))
local target_buf = vim.api.nvim_get_current_buf()
local lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
for index, line in ipairs(lines) do
  if line == "timeout = 30" and index > 20 then
    lines[index] = "timeout = 45"
    break
  end
end
for index, line in ipairs(lines) do
  if line == 'log_level = "info"' then
    lines[index] = 'log_level = "debug"'
    break
  end
end
for index, line in ipairs(lines) do
  if line == "retry = 3" then
    table.insert(lines, index + 1, "new_option = true")
    break
  end
end
for index, line in ipairs(lines) do
  if line == "feature_h = false" then
    table.remove(lines, index)
    break
  end
end
vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, lines)

require("vimoi.api").diff_files(source, target)
dofile("tests/helpers/diff.lua")()
local source_buf = vim.api.nvim_get_current_buf()
local source_win = vim.api.nvim_get_current_win()
local target_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_buf(win) == target_buf then
    target_win = win
  end
end
assert(target_win)
assert(vim.wo[source_win].diff and vim.wo[target_win].diff)
assert(not vim.wo[source_win].scrollbind and not vim.wo[target_win].scrollbind)
assert(vim.wo[source_win].foldmethod == "diff" and vim.wo[target_win].foldmethod == "diff")

local function has_closed_fold(win)
  return vim.api.nvim_win_call(win, function()
    for line = 1, vim.api.nvim_buf_line_count(0) do
      if vim.fn.foldclosed(line) > 0 then
        return true
      end
    end
    return false
  end)
end

assert(has_closed_fold(source_win))
assert(has_closed_fold(target_win))

vim.api.nvim_set_current_win(target_win)
require("vimoi.gotmpl").fold("zR")
assert(not has_closed_fold(source_win) and not has_closed_fold(target_win), "zR was not mirrored")
require("vimoi.gotmpl").fold("zM")
assert(has_closed_fold(source_win) and has_closed_fold(target_win), "zM was not mirrored")

local target_fold_line = vim.api.nvim_win_call(target_win, function()
  for line = 1, vim.api.nvim_buf_line_count(0) do
    if vim.fn.foldclosed(line) > 0 then
      return line
    end
  end
end)
assert(target_fold_line)
vim.api.nvim_win_set_cursor(target_win, { target_fold_line, 0 })
vim.cmd("doautocmd CursorMoved")
vim.wait(30)
local source_fold_line = vim.api.nvim_win_get_cursor(source_win)[1]
require("vimoi.gotmpl").fold("zo")
assert(vim.api.nvim_win_call(target_win, function()
  return vim.fn.foldclosed(target_fold_line)
end) == -1, "target fold did not open")
assert(vim.api.nvim_win_call(source_win, function()
  return vim.fn.foldclosed(source_fold_line)
end) == -1, "source fold did not open")
require("vimoi.gotmpl").fold("zM")

local source_has_filler = vim.api.nvim_win_call(source_win, function()
  for line = 1, vim.fn.line("$") + 1 do
    if vim.fn.diff_filler(line) > 0 then
      return true
    end
  end
  return false
end)
local target_has_filler = vim.api.nvim_win_call(target_win, function()
  for line = 1, vim.fn.line("$") + 1 do
    if vim.fn.diff_filler(line) > 0 then
      return true
    end
  end
  return false
end)
assert(source_has_filler, "source did not get native filler for target insertion")
assert(target_has_filler, "target did not get native filler for target deletion")

local function highlight_names(win)
  return vim.api.nvim_win_call(win, function()
    local names = {}
    for line = 1, vim.fn.line("$") do
      local name = vim.fn.synIDattr(vim.fn.diff_hlID(line, 1), "name")
      if name ~= "" then
        names[name] = true
      end
    end
    return names
  end)
end

local source_highlights = highlight_names(source_win)
local target_highlights = highlight_names(target_win)
assert(source_highlights.DiffChange, "source did not highlight replacements")
assert(target_highlights.DiffChange, "target did not highlight replacements")
assert(
  source_highlights.DiffAdd or source_highlights.DiffDelete,
  "source highlights: " .. vim.inspect(source_highlights)
)
assert(
  target_highlights.DiffAdd or target_highlights.DiffDelete,
  "target highlights: " .. vim.inspect(target_highlights)
)

for _, win in ipairs({ source_win, target_win }) do
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zR")
  end)
end
vim.api.nvim_set_current_win(target_win)
vim.api.nvim_win_set_cursor(target_win, { 50, 0 })
vim.cmd("doautocmd CursorMoved")
vim.wait(30)
local mapped_source_line = vim.api.nvim_win_get_cursor(source_win)[1]
assert(mapped_source_line >= 16 and mapped_source_line <= 22, "range occurrence mapped to " .. mapped_source_line)
local source_screen_row = vim.api.nvim_win_call(source_win, vim.fn.winline)
local target_screen_row = vim.api.nvim_win_call(target_win, vim.fn.winline)
assert(
  source_screen_row == target_screen_row,
  ("screen rows differ: %d != %d"):format(source_screen_row, target_screen_row)
)
assert(vim.b[source_buf].snacks_scroll == false and vim.b[target_buf].snacks_scroll == false)

vim.api.nvim_set_current_win(source_win)
vim.api.nvim_win_set_cursor(source_win, { 18, 0 })
vim.cmd("doautocmd CursorMoved")
vim.wait(30)
assert(math.abs(vim.api.nvim_win_get_cursor(target_win)[1] - 50) < 8, "source range did not keep nearest occurrence")

local function target_line(text, after)
  local current = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
  for index, line in ipairs(current) do
    if line == text and (not after or index > after) then
      return index
    end
  end
  error("target line not found: " .. text)
end

vim.api.nvim_set_current_win(target_win)

vim.api.nvim_win_set_cursor(target_win, { target_line('log_level = "debug"'), 0 })
assert(require("vimoi.api").put_hunk(), "static replacement was not merged")

vim.api.nvim_win_set_cursor(target_win, { target_line("new_option = true"), 0 })
assert(require("vimoi.api").put_hunk(), "static insertion was not merged")

vim.api.nvim_win_set_cursor(target_win, { target_line("# end"), 0 })
assert(require("vimoi.api").put_hunk(), "static deletion was not merged")

vim.cmd("redraw")
vim.wait(20)
local template_control_highlight = vim.api.nvim_win_call(source_win, function()
  return vim.fn.synIDattr(vim.fn.diff_hlID(5, 1), "name")
end)
assert(template_control_highlight == "", "refresh fell back to an ordinary source/target diff")

local merged_source = table.concat(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), "\n")
assert(merged_source:find('log_level = "debug"', 1, true), merged_source)
assert(merged_source:find("new_option = true", 1, true), merged_source)
assert(not merged_source:find("feature_h = false", 1, true), merged_source)

local source_map = require("vimoi.gotmpl.source_map")
local original_trace = source_map.trace
local original_trace_async = source_map.trace_async
local render_count = 0
source_map.trace = function(...)
  render_count = render_count + 1
  return original_trace(...)
end
source_map.trace_async = function(...)
  render_count = render_count + 1
  return original_trace_async(...)
end
local source_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
for index, line in ipairs(source_lines) do
  if line == "color = true" then
    source_lines[index] = "color = false"
    break
  end
end
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source_lines)
vim.cmd("redraw")
vim.wait(180)
source_map.trace = original_trace
source_map.trace_async = original_trace_async
assert(render_count == 0, "editing one static segment unexpectedly rerendered the template")
assert(vim.o.diffexpr == "v:lua.require'vimoi.gotmpl'._diffexpr()")
template_control_highlight = vim.api.nvim_win_call(source_win, function()
  return vim.fn.synIDattr(vim.fn.diff_hlID(5, 1), "name")
end)
assert(template_control_highlight == "", "manual template edit fell back to an ordinary diff")

render_count = 0
source_map.trace = function(...)
  render_count = render_count + 1
  return original_trace(...)
end
source_map.trace_async = function(...)
  render_count = render_count + 1
  return original_trace_async(...)
end
source_lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
for index, line in ipairs(source_lines) do
  if line == "package_manager = system" then
    source_lines[index] = "package_manager = apt"
    break
  end
end
vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source_lines)
vim.cmd("redraw")
vim.wait(180)
source_map.trace = original_trace
source_map.trace_async = original_trace_async
assert(render_count == 0, "editing static text inside an if unexpectedly rerendered the template")
assert(not vim.wo[source_win].scrollbind and not vim.wo[target_win].scrollbind)
assert(vim.wo[source_win].foldmethod == "diff" and vim.wo[target_win].foldmethod == "diff")
template_control_highlight = vim.api.nvim_win_call(source_win, function()
  return vim.fn.synIDattr(vim.fn.diff_hlID(5, 1), "name")
end)
assert(template_control_highlight == "", "editing inside an if corrupted the projected diff")

render_count = 0
source_map.trace = function(...)
  render_count = render_count + 1
  return original_trace(...)
end
source_map.trace_async = function(...)
  render_count = render_count + 1
  return original_trace_async(...)
end
local target_lines = vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)
for index, line in ipairs(target_lines) do
  if line == 'editor = "nvim"' then
    target_lines[index] = 'editor = "vim"'
    break
  end
end
vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, target_lines)
vim.cmd("redraw")
vim.wait(180)
source_map.trace = original_trace
source_map.trace_async = original_trace_async
assert(render_count == 0, "editing the target unexpectedly rerendered the template")

vim.api.nvim_win_set_cursor(target_win, { target_line("timeout = 45", 20), 0 })
assert(not require("vimoi.api").put_hunk(), "repeated template content must not be merged implicitly")

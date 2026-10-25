local job = require("vimoi.core.job")
local original_select = vim.ui.select
local editor_win = vim.api.nvim_get_current_win()
local items, picker_opts, choose
local selections = 0
---@diagnostic disable-next-line: duplicate-set-field -- Hold picker decisions to test process-completion races.
vim.ui.select = function(choices, opts, callback)
  selections = selections + 1
  items, picker_opts, choose = choices, opts, callback
end
---@param duration string
---@return VimoiCommand
local function start(duration)
  local command = job.run({ "sleep", duration }, {
    label = "chezmoi execute-template",
    mode = "notify",
    callback = function(result)
      assert(type(result.code) == "number")
    end,
  })
  ---@cast command VimoiCommand
  return command
end
local function wait_for(test)
  assert(vim.wait(2000, test, 5))
end

job.cancel()
assert(selections == 0, "no commands should not open a picker")
local first, second, short = start("30"), start("30"), start("30")
assert(vim.api.nvim_get_current_win() == editor_win)
job.cancel()
assert(selections == 1 and #items == 3)
assert(items[1] == first and items[2] == second and items[3] == short)
assert(picker_opts.format_item(first):find(first.label, 1, true))
assert(picker_opts.format_item(first) ~= picker_opts.format_item(second), "same-purpose jobs need distinct labels")
assert(not first.cancelled and not second.cancelled and not short.cancelled)
choose(second)
wait_for(function()
  return second.finished
end)
assert(second.cancelled and not first.cancelled and not short.cancelled)

job.cancel()
assert(selections == 2 and #items == 2)
choose(nil)
assert(not first.cancelled and not short.cancelled, "dismissing the picker must preserve jobs")
-- A command may finish while the picker is open; choosing it later is harmless.
assert(short.process):kill(15)
wait_for(function()
  return short.finished
end)
choose(short)
assert(not short.cancelled and not first.cancelled)
job.cancel()
assert(selections == 2 and first.cancelled, "a sole command should cancel without a picker")
wait_for(function()
  return first.finished
end)
job.cancel()
assert(selections == 2)
vim.ui.select = original_select
print("command picker: zero/one/multiple jobs, selection, dismissal and completion races verified")

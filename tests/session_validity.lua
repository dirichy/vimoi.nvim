local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({
  chezmoi_executable = fixture .. "/chezmoi-wrapper.sh",
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})

local api = require("vimoi.api")
local sessions = require("vimoi.gotmpl.view")
local util = require("vimoi.util")
local function await(predicate)
  assert(vim.wait(3000, predicate, 10), "session validity test timed out")
end
local function open(mode)
  vim.cmd("tabnew")
  local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
  vim.fn.writefile({ 'value={{ "A" }}' }, source)
  vim.fn.writefile({ "value=B" }, target)
  if mode == "preview" then
    api.preview({ source = source })
  else
    api.diff_files(source, target)
  end
  local session = assert(view_for_buffer(vim.fn.bufnr(source)))
  await(function()
    return session.map ~= nil
  end)
  assert(sessions.is_valid(session))
  return session
end

-- Like native diff, renaming a displayed buffer does not retire its view.
for _, mode in ipairs({ "diff", "preview" }) do
  for _, side in ipairs({ "source", "target" }) do
    local session = open(mode)
    local owner = session.session
    local buf = session[side .. "_buf"]
    vim.api.nvim_buf_set_name(buf, vim.api.nvim_buf_get_name(buf) .. ".renamed")
    util.set_buffer_text(session.source_buf, 'value={{ "C" }}\n')
    await(function()
      return session.map and session.map.tick == vim.api.nvim_buf_get_changedtick(session.source_buf)
    end)
    assert(sessions.is_valid(session) and session.session == owner)
    assert(owner.views[session], "source owner lost its renamed view")
    assert(util.buffer_text(session.target_buf) == (mode == "preview" and "value=C\n" or "value=B\n"))
    sessions.close(session)
    assert(not owner.views[session])
    assert(vim.api.nvim_win_is_valid(session.source_win) and vim.api.nvim_win_is_valid(session.target_win))
  end
end

-- A buffer replacement must invalidate the binding even when autocmds are suppressed.
for _, side in ipairs({ "source", "target" }) do
  local session = open("diff")
  local replacement = vim.api.nvim_create_buf(false, true)
  local win = session[side .. "_win"]
  vim.api.nvim_win_call(win, function()
    vim.cmd("noautocmd buffer " .. replacement)
  end)
  assert(not sessions.is_valid(session))
  sessions.schedule_refresh(session)
  await(function()
    return session.closed
  end)
  assert(vim.api.nvim_win_get_buf(win) == replacement, "cleanup restored an obsolete buffer")
end

local render_trace = dofile("tests/helpers/trace.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })

local renderer = require("vimoi.gotmpl.source_map")
local requests, hold = {}, false
package.loaded["vimoi.gotmpl.source_map"] = setmetatable({
  trace_async = function(source, opts, callback)
    if hold then
      requests[#requests + 1] = { source = source, opts = opts, callback = callback }
    else
      renderer.trace_async(source, opts, callback)
    end
  end,
}, { __index = renderer })
local api = require("vimoi.api")
local sessions = require("vimoi.gotmpl.session")
local util = require("vimoi.util")
local function await(predicate)
  assert(vim.wait(3000, predicate, 10), "session validity test timed out")
end
local function open(mode)
  hold = false
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
    return session.trace ~= nil
  end)
  assert(sessions.is_valid(session))
  return session
end

-- Both sides retain their opening identities throughout delayed/in-flight refreshes.
for _, mode in ipairs({ "diff", "preview" }) do
  for _, stage in ipairs({ "debounce", "rendering" }) do
    for _, side in ipairs({ "source", "target" }) do
      local session = open(mode)
      local trace = session.trace
      local before = #requests
      hold = true
      util.set_buffer_text(session.source_buf, 'value={{ "C" }}\n')
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = session.source_buf })
      if stage == "rendering" then
        await(function()
          return #requests == before + 1
        end)
      end
      local buf = session[side .. "_buf"]
      vim.api.nvim_buf_set_name(buf, vim.api.nvim_buf_get_name(buf) .. ".renamed")
      local source_text, target_text = util.buffer_text(session.source_buf), util.buffer_text(session.target_buf)
      assert(not sessions.is_valid(session))
      if stage == "rendering" then
        local request = requests[#requests]
        local rendered, err = render_trace(renderer, request.source, request.opts)
        assert(rendered, err)
        request.callback(rendered)
      end
      await(function()
        return session.closed
      end)
      assert(#requests == before + (stage == "rendering" and 1 or 0), "invalid session launched a render")
      assert(session.trace == trace, "renamed session accepted a late source map")
      assert(util.buffer_text(session.source_buf) == source_text)
      assert(util.buffer_text(session.target_buf) == target_text)
      assert(sessions.by_window[session.source_win] == nil and sessions.by_window[session.target_win] == nil)
      for _, win in ipairs({ session.source_win, session.target_win }) do
        assert(not vim.wo[win].diff, "invalid session kept native diff active")
      end
    end
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

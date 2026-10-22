local render_trace = dofile("tests/helpers/trace.lua")
local view_for_buffer = dofile("tests/helpers/view.lua")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG = fixture .. "/empty.toml"
vim.env.VIMOI_TEST_SOURCE = fixture .. "/source"
vim.opt.swapfile = false
require("vimoi").setup({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local renderer = require("vimoi.gotmpl.source_map")
local requests = {}
package.loaded["vimoi.gotmpl.source_map"] = setmetatable({
  trace_async = function(source, opts, callback)
    requests[#requests + 1] = { source = source, opts = opts, callback = callback }
  end,
}, { __index = renderer })
local api = require("vimoi.api")
local util = require("vimoi.util")
local sessions = require("vimoi.gotmpl.session")
local function deliver(request)
  request.callback(render_trace(renderer, request.source, request.opts))
end

for _, side in ipairs({ "source", "target" }) do
  for _, stage in ipairs({ "initial", "stale" }) do
    for _, change in ipairs({ "none", "cancel", "source", "target", "context", "rename", "close", "failure" }) do
      vim.cmd("tabnew")
      local source, target = vim.fn.tempname() .. ".tmpl", vim.fn.tempname()
      local source_text = 'first={{ "old" }}\nkeep\nlast=old\n'
      local target_text = "first=new\nkeep\nlast=new\n"
      vim.fn.writefile(util.text_lines(source_text), source)
      vim.fn.writefile(util.text_lines(target_text), target)
      local before = #requests
      api.diff_files(source, target)
      local session = assert(view_for_buffer(vim.fn.bufnr(source)))
      assert(vim.wait(1000, function()
        return #requests > before
      end))
      if stage == "stale" then
        deliver(requests[#requests])
        util.set_buffer_text(session.source_buf, source_text:gsub('"old"', '"fresh"'))
      end
      vim.api.nvim_set_current_win(session[side .. "_win"])
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      assert(api.apply_hunk() == nil and session.pending_merge)
      local request = requests[#requests]
      if change == "cancel" then
        vim.fn.maparg("q", "n", false, true).callback()
      elseif change == "source" then
        util.set_buffer_text(session.source_buf, source_text .. "manual\n")
      elseif change == "target" then
        util.set_buffer_text(session.target_buf, target_text .. "manual\n")
      elseif change == "context" then
        require("vimoi.cli").invalidate("templates")
      elseif change == "rename" then
        vim.api.nvim_buf_set_name(session.target_buf, target .. ".renamed")
      elseif change == "close" then
        sessions.close(session)
      end
      local expected_source = util.buffer_text(session.source_buf)
      local expected_target = util.buffer_text(session.target_buf)
      if change == "failure" then
        request.callback(nil, "test render failure")
      else
        local previous_requests = #requests
        deliver(request)
        -- Initial renders retry changed source/context before completing; the
        -- waiting operation must still reject its original text/context snapshot.
        if session.pending_merge then
          assert(
            vim.wait(1000, function()
              return #requests > previous_requests
            end),
            "initial rendering did not retry"
          )
          deliver(requests[#requests])
        end
      end
      assert(not session.pending_merge)
      assert(util.buffer_text(session.source_buf) == expected_source)
      if change == "none" then
        assert(util.buffer_text(session.target_buf) == "first=new\nkeep\nlast=old\n")
      else
        assert(
          util.buffer_text(session.target_buf) == expected_target,
          side .. "/" .. stage .. "/" .. change .. " wrote a stale result"
        )
      end
      sessions.close(session)
      vim.fn.delete(source)
      vim.fn.delete(target)
    end
  end
end

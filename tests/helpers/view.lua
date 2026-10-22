-- Locate a fixture's view for assertions that can run from another tab.
-- Prefer the current tab; ownership and multi-window tests use by_window directly.
---@param buf integer
---@return VimoiTemplateSession?
return function(buf)
  local sessions = require("vimoi.gotmpl.session").by_window
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local session = sessions[win]
    if session and (session.source_buf == buf or session.target_buf == buf) then
      return session
    end
  end
  for _, session in pairs(sessions) do
    if session.source_buf == buf or session.target_buf == buf then
      return session
    end
  end
end

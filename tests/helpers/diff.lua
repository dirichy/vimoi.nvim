return function()
  local win = vim.api.nvim_get_current_win()
  local session = require("vimoi.gotmpl.session").by_window[win]
  assert(
    vim.wait(5000, function()
      return not session or not session.loading
    end, 10),
    "initial template render did not complete"
  )
  assert(vim.api.nvim_win_is_valid(win) and vim.wo[win].diff, "initial template diff failed")
end

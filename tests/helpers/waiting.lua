-- A cancelled modal can remain visible until its scheduled window close.
return function()
  local buf = vim.api.nvim_get_current_buf()
  return vim.bo[buf].filetype == "vimoi-progress" and vim.fn.exists("#vimoi-progress-" .. buf .. "#WinClosed") == 1
end

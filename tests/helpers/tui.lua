-- Launch a minimal TUI and answer the terminal queries used by Neovim.
return function(script, timeout)
  if vim.env.VIMOI_UI_RESULT then
    return true
  end
  local result = vim.fn.tempname()
  local pending = ""
  local child = vim.fn.jobstart({
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--cmd",
    "set ttyfast background=dark",
    "-u",
    "tests/minimal_init.lua",
    "-c",
    ("lua dofile(%q)"):format(script),
  }, {
    pty = true,
    env = { VIMOI_UI_RESULT = result },
    on_stdout = function(channel, data)
      pending = pending .. table.concat(data, "\n")
      -- The test owns the pseudo-terminal, including background-color replies.
      if pending:find("\027]11;?", 1, true) then
        vim.fn.chansend(channel, "\027]11;rgb:1414/1616/1b1b\027\\")
      end
      if pending:find("\027[c", 1, true) then
        vim.fn.chansend(channel, "\027[?1;2c")
      end
      if pending:find("\027[5n", 1, true) then
        vim.fn.chansend(channel, "\027[0n")
      end
      pending = pending:sub(-4)
    end,
  })
  assert(child > 0)
  local status = vim.fn.jobwait({ child }, timeout or 30000)[1]
  if status == -1 then
    vim.fn.jobstop(child)
  end
  assert(vim.fn.filereadable(result) == 1, "TUI test did not finish: " .. status)
  local output = table.concat(vim.fn.readfile(result), "\n")
  vim.fn.delete(result)
  assert(status == 0 and output == "OK", output)
  return false
end

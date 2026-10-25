vim.opt.swapfile = false
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.env.VIMOI_BENCH_SESSION and vim.env.VIMOI_BENCH_SESSION ~= "" then
  package.preload["vimoi.gotmpl.session"] = function()
    return dofile(vim.env.VIMOI_BENCH_SESSION)
  end
end
require("vimoi").setup({
  chezmoi_config_path = vim.env.VIMOI_BENCH_CONFIG,
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})
local sessions, cli, util = require("vimoi.gotmpl.session"), require("vimoi.cli"), require("vimoi.util")
local results = {}
for i = 1, 18 do
  cli.invalidate("templates")
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(source, cli.source_root .. "/dot_benchmark.tmpl")
  util.set_buffer_text(source, assert(util.read_file(vim.api.nvim_buf_get_name(source))))
  local started = vim.uv.hrtime()
  local elapsed, failure
  sessions.register(source, function(_, err)
    elapsed = (vim.uv.hrtime() - started) / 1e6
    failure = err
  end, { once = true })
  assert(
    vim.wait(10000, function()
      return elapsed ~= nil
    end, 1),
    "benchmark did not settle"
  )
  assert(not failure, failure)
  if i > 3 then
    results[#results + 1] = elapsed
  end
  vim.api.nvim_buf_delete(source, { force = true })
end
vim.fn.writefile({ vim.json.encode(results) }, vim.env.VIMOI_BENCH_RESULT)

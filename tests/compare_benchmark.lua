-- Run with: NVIM_LOG_FILE=/tmp/vimoi-compare-benchmark.log nvim --headless -n -i NONE -u NONE -l tests/compare_benchmark.lua
-- Measures entry-to-ready wall time; setup, source loading and screen painting are excluded.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.opt.swapfile = false
vim.cmd("filetype plugin on")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/source", "p")
vim.fn.mkdir(root .. "/target", "p")
local executable = root .. "/chezmoi"
vim.fn.writefile({
  "#!/bin/sh",
  "exec " .. vim.fn.shellescape(vim.fn.exepath("chezmoi")) .. " --persistent-state " .. vim.fn.shellescape(
    root .. "/state.boltdb"
  ) .. ' "$@"',
}, executable)
vim.fn.setfperm(executable, "rwxr-xr-x")
local config = root .. "/config.toml"
vim.fn.writefile({
  "sourceDir = " .. vim.json.encode(root .. "/source"),
  "destDir = " .. vim.json.encode(root .. "/target"),
}, config)
require("vimoi").setup({
  chezmoi_executable = executable,
  chezmoi_config_path = config,
  diagnostics = { enabled = false },
  highlight = { mode = "disabled" },
})
local actions, views, sessions = require("vimoi.api"), require("vimoi.compare"), require("vimoi.render")
local util = require("vimoi.core.util")
local report = {}
for _, size in ipairs({ 1, 1000 }) do
  local source_lines, output_lines = {}, {}
  for line = 1, size do
    source_lines[line] = "key" .. line .. '={{ "hello" }}'
    output_lines[line] = "key" .. line .. "=hello"
  end
  local expected = table.concat(output_lines, "\n") .. "\n"
  for _, mode in ipairs({ "diff", "preview" }) do
    local samples = {}
    for iteration = 1, 7 do
      -- Each sample constructs a fresh source session, including default cat validation.
      local name = mode .. "_" .. size .. "_" .. iteration
      local source, target = root .. "/source/dot_" .. name .. ".tmpl", root .. "/target/." .. name
      vim.fn.writefile(source_lines, source)
      vim.fn.writefile({ "different" }, target)
      vim.cmd("tabnew " .. vim.fn.fnameescape(source))
      local source_buf = vim.api.nvim_get_current_buf()
      assert(vim.wait(1000, function()
        return vim.b[source_buf].vimoi_template_configured == true
      end, 1))
      local started = vim.uv.hrtime()
      if mode == "diff" then
        actions.diff()
      else
        actions.preview()
      end
      local view = assert(views.current())
      assert(
        vim.wait(10000, function()
          return not view.loading and views.is_valid(view) and sessions.is_current(source_buf, view.map)
        end, 1),
        "view did not become ready"
      )
      local elapsed = (vim.uv.hrtime() - started) / 1e6
      assert(util.buffer_text(sessions.get(source_buf).buf) == expected)
      if iteration > 2 then
        samples[#samples + 1] = elapsed
      end
      views.close(view)
      vim.cmd("tabclose")
      vim.api.nvim_buf_delete(source_buf, { force = true })
    end
    table.sort(samples)
    report[#report + 1] = { mode = mode, lines = size, median_ms = samples[3], samples_ms = samples }
  end
end
local output = vim.json.encode(report)
if vim.env.VIMOI_BENCH_RESULT then
  vim.fn.writefile({ output }, vim.env.VIMOI_BENCH_RESULT)
else
  print(output)
end
vim.fn.delete(root, "rf")

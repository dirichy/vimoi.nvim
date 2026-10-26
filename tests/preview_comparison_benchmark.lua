-- Run each plugin in a separate headless Neovim; see docs/preview-benchmark.md.
-- The checkout, isolated fixture and result filename are supplied by the runner.
vim.opt.swapfile = false
vim.cmd("filetype plugin on")
vim.cmd("syntax on")

local plugin = assert(vim.env.VIMOI_BENCH_PLUGIN)
local root = assert(vim.env.VIMOI_BENCH_ROOT)
local source_path = root .. "/source/dot_benchmark.yaml.tmpl"
local calls = {}
local original_system = vim.system
---@diagnostic disable-next-line: duplicate-set-field -- Observe spawns without changing execution.
vim.system = function(argv, ...)
  calls[#calls + 1] = { command = argv[2], started = vim.uv.hrtime() }
  return original_system(argv, ...)
end

-- Upstream supplies injection queries but leaves TS startup to user config.
-- Give both plugins the same source and preview highlighters.
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "gotmpl", "yaml" },
  callback = function(ev)
    vim.treesitter.start(ev.buf, ev.match)
  end,
})

if plugin == "vimoi" then
  require("vimoi").setup({
    chezmoi_executable = root .. "/bin/chezmoi",
    diagnostics = { enabled = false },
    highlight = { mode = "injection" }, -- Keep the source-highlighting baseline identical to upstream.
  })
else
  assert(plugin == "chezmoi-template")
  vim.opt.rtp:remove(vim.fn.getcwd())
  vim.opt.rtp:prepend(assert(vim.env.VIMOI_BENCH_CHECKOUT))
  vim.opt.rtp:append(vim.env.VIMOI_BENCH_CHECKOUT .. "/after")
  require("chezmoi-template").setup({
    diagnostics = { enabled = false },
    apply = { on_save = false },
    format = { enabled = false },
    icons = { enabled = false },
    preview = vim.env.VIMOI_BENCH_MATCH_DEBOUNCE == "1" and { debounce = 120 } or {},
  })
end
vim.cmd("edit " .. vim.fn.fnameescape(source_path))
local source_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[source_buf].filetype == "gotmpl")
-- Finish scheduled highlighting and the upstream's 100ms data-cache warmup.
vim.wait(200, function()
  return false
end, 5)
local parser = assert(vim.treesitter.get_parser(source_buf, "gotmpl"))
parser:parse(true)
assert(parser:children().yaml, "source host-language injection was not active")

local expected = table.concat(vim.fn.readfile(root .. "/expected"), "\n")
local output_buf, published
local function observe(buf)
  output_buf = buf
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      published = vim.uv.hrtime()
    end,
  })
end
-- Observe new scratch buffers before either plugin publishes its first render.
vim.api.nvim_create_autocmd("BufWinEnter", {
  callback = function(ev)
    if ev.buf ~= source_buf and not output_buf then
      observe(ev.buf)
    end
  end,
})

local heartbeat = assert(vim.uv.new_timer())
local last_beat = vim.uv.hrtime()
local max_stall_ms = 0
heartbeat:start(
  5,
  5,
  vim.schedule_wrap(function()
    local now = vim.uv.hrtime()
    max_stall_ms = math.max(max_stall_ms, (now - last_beat) / 1e6 - 5)
    last_beat = now
  end)
)

local samples = {}
local function measure(kind, edit)
  local before = #calls
  published = nil
  max_stall_ms = 0
  -- A real input event starts on a fresh loop clock. vim.wait() can return to
  -- this long Lua chunk with cached uv time from before the preceding callback.
  vim.uv.update_time()
  last_beat = vim.uv.hrtime()
  local started = last_beat
  edit()
  local verified_publication
  local ok = vim.wait(30000, function()
    if published and published ~= verified_publication then
      verified_publication = published
      return table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n") == expected
    end
    return false
  end, 1)
  assert(ok, plugin .. ": timeout or incorrect output in " .. kind)
  local sample = {
    kind = kind,
    latency_ms = (published - started) / 1e6,
    max_stall_ms = math.max(max_stall_ms, (vim.uv.hrtime() - last_beat) / 1e6 - 5, 0),
    commands = vim.empty_dict(),
  }
  for i = before + 1, #calls do
    local name = calls[i].command
    sample.commands[name] = (sample.commands[name] or 0) + 1
  end
  samples[#samples + 1] = sample
end

measure("initial", function()
  if plugin == "vimoi" then
    require("vimoi.api").preview()
  else
    vim.cmd("Chezmoi preview")
  end
  assert(output_buf, "preview scratch buffer was not observed")
end)

for _, kind in ipairs({ "static", "structural" }) do
  for iteration = 1, 6 do
    local row = kind == "static" and 0 or 1
    local old = vim.api.nvim_buf_get_lines(source_buf, row, row + 1, false)[1]
    local line = kind == "static" and ("bench_static: static_%d"):format(iteration)
      or ('bench_dynamic: {{ printf "dynamic_%d" }}'):format(iteration)
    if kind == "static" then
      expected = expected:gsub("bench_static: static_%d+", "bench_static: static_" .. iteration, 1)
    else
      expected = expected:gsub("bench_dynamic: dynamic_%d+", "bench_dynamic: dynamic_" .. iteration, 1)
    end
    measure(kind, function()
      -- Keep the edit local so both parsers can reuse their unchanged trees.
      local first = 1
      while old:sub(first, first) == line:sub(first, first) do
        first = first + 1
      end
      local old_end, new_end = #old, #line
      while old:sub(old_end, old_end) == line:sub(new_end, new_end) do
        old_end, new_end = old_end - 1, new_end - 1
      end
      vim.api.nvim_buf_set_text(source_buf, row, first - 1, row, old_end, { line:sub(first, new_end) })
      vim.api.nvim_exec_autocmds("TextChangedI", { buffer = source_buf })
    end)
  end
end

heartbeat:stop()
heartbeat:close()
vim.fn.writefile({ vim.json.encode({ plugin = plugin, samples = samples }) }, assert(vim.env.VIMOI_BENCH_RESULT))
print(plugin .. ": 13 preview outputs verified")

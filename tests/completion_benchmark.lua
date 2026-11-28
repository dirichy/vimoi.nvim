---@diagnostic disable: duplicate-set-field -- Isolated cached-data CPU benchmark and dependency counters.
local api = vim.api
local fixture = vim.fn.getcwd() .. "/tests/fixtures/environment"
vim.env.VIMOI_TEST_CONFIG, vim.env.VIMOI_TEST_SOURCE = fixture .. "/empty.toml", fixture .. "/source"
dofile("tests/helpers/setup.lua")({ chezmoi_executable = fixture .. "/chezmoi-wrapper.sh" })
local source, cli = require("vimoi.blink").new(), require("vimoi.core.cli")
local lines_read, copies, requests = 0, 0, 0
local get_lines, deepcopy = api.nvim_buf_get_lines, vim.deepcopy
api.nvim_buf_get_lines = function(buf, first, last, ...)
  if first == 0 and last == -1 then
    lines_read = lines_read + 1
  end
  return get_lines(buf, first, last, ...)
end
vim.deepcopy = function(value, ...)
  copies = copies + 1
  return deepcopy(value, ...)
end
local result = { nvim = vim.version(), queries_per_sample = 32, samples = 7, cases = {} }
for _, case in ipairs({ { "small", 1, 0 }, { "large_data", 1, 10000 }, { "large_buffer", 10000, 0 } }) do
  local data = { chezmoi = { sourceDir = cli.source_root }, name = "demo", payload = {} }
  for i = 1, case[3] do
    data.payload[i] = { value = i }
  end
  cli.data_async = function(done)
    requests = requests + 1
    done(data)
  end
  local buf = api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, case[2] - 1 do
    lines[i] = "ordinary text"
  end
  lines[case[2]] = "{{ .na"
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local context = { bufnr = buf, cursor = { #lines, #lines[#lines] } }
  local checksum = 0
  local function request()
    source:get_completions(context, function(response)
      assert(#response.items == 1 and response.items[1].label == "name")
      checksum = checksum + #response.items[1].label
    end)
  end
  for _ = 1, 8 do
    request()
  end
  copies, lines_read, requests = 0, 0, 0
  local samples = {}
  for sample = 1, 7 do
    collectgarbage("collect")
    local start = os.clock()
    for _ = 1, 32 do
      request()
    end
    samples[sample] = (os.clock() - start) * 1000
  end
  table.sort(samples)
  result.cases[case[1]] = {
    cpu_ms = samples[4],
    full_buffer_reads = lines_read,
    deepcopies = copies,
    data_requests = requests,
    checksum = checksum,
  }
  api.nvim_buf_delete(buf, { force = true })
end
vim.fn.writefile({ vim.json.encode(result) }, assert(vim.env.VIMOI_COMPLETION_RESULT))
